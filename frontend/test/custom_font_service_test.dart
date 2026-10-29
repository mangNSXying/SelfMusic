import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/custom_font_service.dart';
import 'package:sqlite3/open.dart';

import 'ttc_test_util.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

Matcher _fontError(String message) => throwsA(
    isA<CustomFontException>().having((e) => e.message, 'message', message));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;
  late AppSettings settings;
  late CustomFontService service;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_font_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
    settings = AppSettings(index);
    service = CustomFontService(settings);
  });

  tearDown(() {
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  group('导入校验', () {
    test('拒绝非 TTF / OTF / TTC 扩展名', () async {
      final f = await writeFile('bad.txt', [0, 1, 0, 0]);
      await expectLater(
        service.importFont(sourcePath: f.path, sourceName: 'bad.txt'),
        _fontError('仅支持 TTF / OTF / TTC 字体文件'),
      );
      expect(settings.customFontFamily, isEmpty);
    });

    test('TTC 头但文件过短时拒绝', () async {
      final f =
          await writeFile('bad.ttf', [0x74, 0x74, 0x63, 0x66, 0, 0, 0, 0]);
      await expectLater(
        service.importFont(sourcePath: f.path, sourceName: 'bad.ttf'),
        _fontError('TTC 文件过短'),
      );
      expect(settings.customFontFamily, isEmpty);
    });

    test('拒绝无法识别的字体内容', () async {
      final f = await writeFile('bad.ttf', 'nope'.codeUnits);
      await expectLater(
        service.importFont(sourcePath: f.path, sourceName: 'bad.ttf'),
        _fontError('无法识别的字体文件'),
      );
      expect(settings.customFontFamily, isEmpty);
    });
  });

  group('持久化恢复', () {
    test('字体文件缺失时回退系统字体并清空设置', () async {
      settings
        ..customFontFamily = 'SelfMusicCustomFont_missing'
        ..customFontFile = 'missing.otf'
        ..customFontLabel = '缺失字体';

      expect(await service.loadSaved(), isNull);
      expect(settings.customFontFamily, isEmpty);
      expect(settings.customFontFile, isEmpty);
      expect(settings.customFontLabel, isEmpty);
    });

    test('无记录时 loadSaved 直接返回 null', () async {
      expect(await service.loadSaved(), isNull);
    });

    test('clear 清空字体设置', () async {
      settings
        ..customFontFamily = 'SelfMusicCustomFont_x'
        ..customFontLabel = '测试字体';

      await service.clear();
      expect(settings.customFontFamily, isEmpty);
      expect(settings.customFontLabel, isEmpty);
    });
  });

  group('TTC 集合导入', () {
    test('列出字面后提取为单字体并持久化', () async {
      final sfnt = await loadMaterialIconsOtf();
      final ttc = buildTtcFromSfnt(sfnt, faceCount: 2);
      final source = await writeFile('icons.ttc', ttc);

      expect(await service.isTtcFile(source.path), isTrue);
      final faces = await service.listTtcFaces(sourcePath: source.path);
      expect(faces, hasLength(2));
      expect(faces.first.label.toLowerCase(), contains('material'));

      final label = await service.importFont(
        sourcePath: source.path,
        sourceName: 'icons.ttc',
        faceIndex: 1,
      );
      expect(label.toLowerCase(), contains('material'));
      expect(settings.customFontFile, endsWith('.otf'));
      expect(settings.customFontFile, isNot(endsWith('.ttc')));

      final stored =
          File(p.join(dir.path, 'selfmusic', 'fonts', settings.customFontFile));
      expect(await stored.exists(), isTrue);
      final header = await stored.openRead(0, 4).first;
      expect(String.fromCharCodes(header), 'OTTO');
      expect(await CustomFontService(settings).loadSaved(), service.family);
    });

    test('伪 TTC 与越界字面索引被拒绝', () async {
      final sfnt = await loadMaterialIconsOtf();
      final plain = await writeFile('plain.ttc', sfnt);
      expect(await service.isTtcFile(plain.path), isFalse);
      await expectLater(
        service.importFont(sourcePath: plain.path, sourceName: 'plain.ttc'),
        throwsA(isA<CustomFontException>()),
      );

      final ttc = buildTtcFromSfnt(sfnt);
      final source = await writeFile('icons.ttc', ttc);
      await service.listTtcFaces(sourcePath: source.path);
      await expectLater(
        service.importFont(
            sourcePath: source.path, sourceName: 'icons.ttc', faceIndex: 9),
        throwsA(isA<CustomFontException>()),
      );
    });
  });

  group('真实字体导入', () {
    test('复制、注册、持久化，重启后可恢复，clear 删除文件', () async {
      // 用 Flutter 自带的 MaterialIcons 字体作为真实 OTF 字节，避免测试依赖
      // 系统字体或额外二进制 fixture；只验证加载链路，不校验字形。
      final data = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final source = await writeFile('MaterialIcons-Regular.otf', bytes);

      final label = await service.importFont(
          sourcePath: source.path, sourceName: 'MaterialIcons-Regular.otf');
      expect(label, 'MaterialIcons-Regular');
      expect(service.family, isNotNull);
      expect(service.family, startsWith('SelfMusicCustomFont_'));
      expect(settings.customFontFile, endsWith('.otf'));

      final stored =
          File(p.join(dir.path, 'selfmusic', 'fonts', settings.customFontFile));
      expect(await stored.exists(), isTrue, reason: '字体应复制到应用字体目录');

      // 新实例模拟下次冷启动：从设置与文件恢复注册。
      final restored = await CustomFontService(settings).loadSaved();
      expect(restored, service.family);

      await service.clear();
      expect(settings.customFontFamily, isEmpty);
      expect(await stored.exists(), isFalse, reason: '恢复系统字体应删除文件');
      expect(await CustomFontService(settings).loadSaved(), isNull);
    });
  });
}
