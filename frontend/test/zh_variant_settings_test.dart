import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/utils/zh_variant.dart';
import 'package:sqlite3/open.dart';

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

void main() {
  test('简繁显示：默认原文、持久化并随设置导出', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_zh_settings_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final s = AppSettings(index);
    expect(s.zhVariant, ZhVariant.original);
    expect(ZhVariant.parse(null), ZhVariant.original);
    expect(ZhVariant.parse('unknown'), ZhVariant.original);

    s.zhVariant = ZhVariant.simplified;
    expect(AppSettings(index).zhVariant, ZhVariant.simplified);

    s.zhVariant = ZhVariant.traditional;
    expect(AppSettings(index).zhVariant, ZhVariant.traditional);

    expect(AppSettings.knownKeys, contains(AppSettings.kZhVariant));

    index.close();
    dir.deleteSync(recursive: true);
  });
}
