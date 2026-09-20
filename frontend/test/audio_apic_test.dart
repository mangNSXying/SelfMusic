import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

Uint8List syncsafe(int v) => Uint8List.fromList([
      (v >> 21) & 0x7F,
      (v >> 14) & 0x7F,
      (v >> 7) & 0x7F,
      v & 0x7F,
    ]);

/// 最小 JPEG 字节（签名 + 结束标记 + 填充，足够签名校验）。
final jpeg = Uint8List.fromList(
    [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 0xFF, 0xD9]);

/// 大体积伪 JPEG（0xE0 段后全是填充），用于验证超采样长度的封面读取。
Uint8List bigJpeg(int bodyBytes) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8, 0xFF, 0xE0]);
  b.add(Uint8List(bodyBytes));
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

/// 构造带 APIC 的 ID3v2.3 头部（encoding=1 UTF-16 描述，BOM 前缀）。
Uint8List id3WithApic({required int enc, required List<int> descBytes}) {
  final body = <int>[
    enc,
    ...'image/jpeg'.codeUnits,
    0, // mime 终止
    3, // 图片类型
    ...descBytes,
    ...jpeg,
  ];
  final frame = <int>[
    ...'APIC'.codeUnits,
    ...syncsafe(body.length),
    0,
    0,
    ...body,
  ];
  final tagSize = frame.length;
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0, // v2.3
    0, // flags
    ...syncsafe(tagSize),
    ...frame,
  ]);
}

/// 构造带超大 APIC 的 ID3v2.3 头（enc=0），用于截断/两段读测试。
Uint8List id3WithLargeApic({required int imgBytes}) {
  final img = bigJpeg(imgBytes);
  final body = <int>[
    0,
    ...'image/jpeg'.codeUnits,
    0,
    3,
    0,
    ...img,
  ];
  final frame = <int>[
    ...'APIC'.codeUnits,
    ...syncsafe(body.length),
    0,
    0,
    ...body,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0,
    0,
    ...syncsafe(frame.length),
    ...frame,
    // 一个 MPEG 帧头 + 载荷占位（模拟音频数据）
    0xFF, 0xFB, 0x90, 0x00,
  ]);
}

void main() {
  test('APIC：UTF-16 描述（BOM + 00 00 终止）不应把描述字节当成封面', () {
    // BOM FF FE + "cover" UTF-16LE + 00 00 终止
    final desc = <int>[
      0xFF, 0xFE,
      ...'cover'.codeUnits.expand((c) => [c, 0]),
      0, 0,
    ];
    final head = id3WithApic(enc: 1, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta, isNotNull);
    expect(meta!.cover, isNotNull);
    // 封面必须以 JPEG 签名开头（此前 bug 会以描述残留 0x6F 开头）。
    expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：UTF-16BE 描述（enc=2）同样正确跳过', () {
    final desc = <int>[
      ...'c'.codeUnits.expand((c) => [0, c]),
      ...'over'.codeUnits.expand((c) => [0, c]),
      0, 0,
    ];
    final head = id3WithApic(enc: 2, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover?.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：latin1 描述（enc=0）保持原行为', () {
    final desc = <int>[...'cover'.codeUnits, 0];
    final head = id3WithApic(enc: 0, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover?.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：mime 为 --> 的 URL 链接不当作封面字节', () {
    final body = <int>[
      0,
      ...'-->'.codeUnits,
      0,
      3,
      0, // 空描述
      ...'https://example.com/cover.jpg'.codeUnits,
    ];
    final frame = <int>[...'APIC'.codeUnits, ...syncsafe(body.length), 0, 0, ...body];
    final head = Uint8List.fromList([
      ...'ID3'.codeUnits,
      3, 0,
      0,
      ...syncsafe(frame.length),
      ...frame,
    ]);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover, isNull);
  });

  group('coverReadHint - 大内嵌封面两段读', () {
    test('mp3：标签被采样截断时提示补读长度；完整标签返回 null', () {
      final full = id3WithLargeApic(imgBytes: 400 * 1024);
      final declared = 10 + syncsafeInt(full, 6);
      final truncated = Uint8List.sublistView(full, 0, 256 * 1024);
      expect(coverReadHint(truncated, 'mp3'), declared);
      expect(coverReadHint(full, 'mp3'), isNull);
    });

    test('mp3：400KB 封面经两段读可完整解析', () {
      final full = id3WithLargeApic(imgBytes: 400 * 1024);
      final truncated = Uint8List.sublistView(full, 0, 256 * 1024);
      // 一段读：封面丢失
      expect(parseAudioHead(truncated, 'mp3', full.length)?.cover, isNull);
      // 二段读（按提示读取完整标签）：封面恢复
      final hint = coverReadHint(truncated, 'mp3')!;
      expect(hint, greaterThan(256 * 1024));
      expect(hint, lessThanOrEqualTo(kCoverReadCapBytes));
      final deeper = Uint8List.sublistView(full, 0, hint);
      final meta = parseAudioHead(deeper, 'mp3', full.length);
      expect(meta?.cover, isNotNull);
      expect(meta!.cover!.sublist(0, 2), [0xFF, 0xD8]);
      expect(meta.cover!.length, greaterThan(400 * 1024));
    });

    test('flac：PICTURE 块被截断时提示块尾；完整后返回 null', () {
      final img = bigJpeg(300 * 1024);
      final picBody = <int>[
        0, 0, 0, 3, // 大端图片类型
        0, 0, 0, 0, // mime 长度 0
        0, 0, 0, 0, // 描述长度 0
        ...List.filled(16, 0), // 宽/高/色深/色数占位
        (img.length >> 24) & 0xFF,
        (img.length >> 16) & 0xFF,
        (img.length >> 8) & 0xFF,
        img.length & 0xFF,
        ...img,
      ];
      final picHeader = <int>[
        6, // PICTURE，非最后块
        (picBody.length >> 16) & 0xFF,
        (picBody.length >> 8) & 0xFF,
        picBody.length & 0xFF,
      ];
      final streamInfo = <int>[
        0, // STREAMINFO，非最后块
        0, 0, 34,
        ...List.filled(34, 0),
      ];
      final flac = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...streamInfo,
        ...picHeader,
        ...picBody,
      ]);
      final picEnd = 4 + streamInfo.length + 4 + picBody.length;
      final truncated = Uint8List.sublistView(flac, 0, 256 * 1024);
      expect(coverReadHint(truncated, 'flac'), picEnd);
      final deeper = Uint8List.sublistView(flac, 0, picEnd);
      expect(coverReadHint(deeper, 'flac'), isNull);
      final meta = parseAudioHead(deeper, 'flac', flac.length);
      expect(meta?.cover, isNotNull);
    });

    test('无 ID3/fLaC 魔数时返回 null（不误报补读）', () {
      final junk = Uint8List.fromList(List.filled(100, 0x55));
      expect(coverReadHint(junk, 'mp3'), isNull);
      expect(coverReadHint(junk, 'flac'), isNull);
    });
  });
}

/// 从 ID3 头读取 syncsafe 标签长度（测试断言用）。
int syncsafeInt(Uint8List b, int o) =>
    ((b[o] & 0x7F) << 21) |
    ((b[o + 1] & 0x7F) << 14) |
    ((b[o + 2] & 0x7F) << 7) |
    (b[o + 3] & 0x7F);
