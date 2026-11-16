import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/screens/settings/settings_search_index.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:sqlite3/open.dart';

ffi.DynamicLibrary _openOnLinux() {
  try {
    return ffi.DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return ffi.DynamicLibrary.open('libsqlite3.so.0');
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
  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_haptic_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('默认开启；关闭后持久化；设备本地键不进 knownKeys', () {
    final settings = AppSettings(index);
    expect(settings.hapticFeedback, isTrue, reason: '默认开');

    settings.hapticFeedback = false;
    expect(settings.hapticFeedback, isFalse);

    final again = AppSettings(index);
    expect(again.hapticFeedback, isFalse, reason: '持久化往返');

    expect(
      AppSettings.knownKeys,
      isNot(contains(AppSettings.kHapticFeedback)),
      reason: '依赖设备马达，不随设置导出/同步',
    );
  });

  test('搜索索引含交互分组条目', () {
    final entry = settingsSearchEntries.firstWhere((e) => e.label == '震动反馈');
    expect(entry.section, SettingsItem.appearance);
    expect(entry.group, '交互');
    expect(entry.aliases, contains('触感'));
    expect(entry.id, '${SettingsItem.appearance.name}/震动反馈');
  });
}
