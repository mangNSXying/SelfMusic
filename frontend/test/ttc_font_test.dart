import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/ttc_font.dart';

import 'ttc_test_util.dart';

int _wholeFileChecksum(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  var sum = 0;
  for (var i = 0; i < bytes.length; i += 4) {
    sum = (sum + bd.getUint32(i)) & 0xFFFFFFFF;
  }
  return sum;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List sfnt;

  setUpAll(() async {
    sfnt = await loadMaterialIconsOtf();
  });

  test('isTtcBytes 识别集合头', () {
    final ttc = buildTtcFromSfnt(sfnt);
    expect(isTtcBytes(ttc), isTrue);
    expect(isTtcBytes(sfnt), isFalse);
    expect(isTtcBytes(Uint8List.fromList([0x74, 0x74])), isFalse);
  });

  test('读取 TTC 字面列表、显示名与目标扩展名', () {
    final ttc = buildTtcFromSfnt(sfnt, faceCount: 2);
    final faces = readTtcFaces(ttc);

    expect(faces, hasLength(2));
    expect(faces.first.index, 0);
    expect(faces.last.index, 1);
    expect(faces.first.label, isNotEmpty);
    expect(faces.first.label.toLowerCase(), contains('material'));
    expect(faces.first.extension, '.otf');
  });

  test('提取单字面：校验和正确且可被 FontLoader 注册', () async {
    final ttc = buildTtcFromSfnt(sfnt);
    final extracted = extractTtcFace(ttc, 0);

    expect(extracted.extension, '.otf');
    expect(String.fromCharCodes(extracted.bytes.sublist(0, 4)), 'OTTO');
    expect(extracted.bytes.length % 4, 0);
    expect(_wholeFileChecksum(extracted.bytes), 0xB1B0AFBA,
        reason: '重建后全局校验和应为标准魔数');

    final loader = FontLoader('SelfMusicTtcUnitTest');
    loader.addFont(Future.value(ByteData.sublistView(extracted.bytes)));
    await loader.load();
  });

  test('字面索引越界抛出 TtcFormatException', () {
    final ttc = buildTtcFromSfnt(sfnt);
    expect(() => extractTtcFace(ttc, 1), throwsA(isA<TtcFormatException>()));
    expect(() => extractTtcFace(ttc, -1), throwsA(isA<TtcFormatException>()));
  });

  test('非 TTC / 空集合 / 越界偏移均拒绝', () {
    expect(() => readTtcFaces(sfnt), throwsA(isA<TtcFormatException>()));

    final empty = Uint8List(12);
    ByteData.sublistView(empty)
      ..setUint32(0, 0x74746366)
      ..setUint32(4, 0x00010000)
      ..setUint32(8, 0);
    expect(() => readTtcFaces(empty), throwsA(isA<TtcFormatException>()));

    final badOffset = Uint8List(16);
    ByteData.sublistView(badOffset)
      ..setUint32(0, 0x74746366)
      ..setUint32(4, 0x00010000)
      ..setUint32(8, 1)
      ..setUint32(12, 9999);
    expect(() => readTtcFaces(badOffset), throwsA(isA<TtcFormatException>()));
  });
}
