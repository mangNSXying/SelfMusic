import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/shortcuts/shortcut_models.dart';
import 'package:selfmusic/shortcuts/shortcut_settings.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String> getApplicationSupportPath() async => dir;

  @override
  Future<String> getApplicationCachePath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;
  late AppSettings appSettings;
  late ShortcutSettings shortcuts;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_shortcut_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
    appSettings = AppSettings(index);
    shortcuts = ShortcutSettings(
      appSettings,
      primaryIsMeta: false,
      metaSupported: true,
      standaloneGlobalKeys: true,
    );
  });

  tearDown(() {
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('录制状态可嵌套且关闭后恢复', () {
    expect(shortcuts.isRecording, isFalse);
    shortcuts.beginRecording();
    shortcuts.beginRecording();
    expect(shortcuts.isRecording, isTrue);
    shortcuts.endRecording();
    expect(shortcuts.isRecording, isTrue);
    shortcuts.endRecording();
    expect(shortcuts.isRecording, isFalse);
    // 多余的 end 不应变成负数。
    shortcuts.endRecording();
    expect(shortcuts.isRecording, isFalse);
  });

  test('无覆盖参数时仍返回冲突，不会静默改绑', () {
    final binding = shortcuts.windowBindings[ShortcutAction.next]!;
    final error = shortcuts.setBinding(
      ShortcutAction.sectionSongs,
      ShortcutScope.window,
      binding,
    );
    expect(error, contains('下一首'));
    expect(
      shortcuts.bindingFor(ShortcutAction.sectionSongs, ShortcutScope.window),
      isNot(binding),
    );
    expect(
      shortcuts.bindingFor(ShortcutAction.next, ShortcutScope.window),
      binding,
    );
  });

  test('覆盖同 scope 冲突会清除旧绑定并持久化', () {
    final binding = shortcuts.windowBindings[ShortcutAction.next]!;
    final error = shortcuts.setBinding(
      ShortcutAction.sectionSongs,
      ShortcutScope.window,
      binding,
      replaceConflicts: true,
    );
    expect(error, isNull);
    expect(
      shortcuts.bindingFor(ShortcutAction.sectionSongs, ShortcutScope.window),
      binding,
    );
    expect(shortcuts.bindingFor(ShortcutAction.next, ShortcutScope.window),
        isNull);

    final reloaded = ShortcutSettings(
      appSettings,
      primaryIsMeta: false,
      metaSupported: true,
      standaloneGlobalKeys: true,
    );
    expect(
      reloaded.bindingFor(ShortcutAction.sectionSongs, ShortcutScope.window),
      binding,
    );
    expect(
        reloaded.bindingFor(ShortcutAction.next, ShortcutScope.window), isNull);
  });

  test('覆盖跨 scope 冲突会清除全局旧绑定', () {
    final binding = shortcuts.globalBindings[ShortcutAction.playPause]!;
    final error = shortcuts.setBinding(
      ShortcutAction.sectionArtists,
      ShortcutScope.window,
      binding,
      replaceConflicts: true,
    );
    expect(error, isNull);
    expect(shortcuts.bindingFor(ShortcutAction.playPause, ShortcutScope.global),
        isNull);
    expect(
      shortcuts.bindingFor(ShortcutAction.sectionArtists, ShortcutScope.window),
      binding,
    );
  });

  test('F8 可单独保存为桌面端全局快捷键', () {
    final binding = ShortcutBinding(keyId: LogicalKeyboardKey.f8.keyId);
    final error = shortcuts.setBinding(
      ShortcutAction.playPause,
      ShortcutScope.global,
      binding,
    );
    expect(error, isNull);
    expect(
      shortcuts.bindingFor(ShortcutAction.playPause, ShortcutScope.global),
      binding,
    );
  });

  test('鸿蒙配置下 F8 单独全局键被拒绝', () {
    final ohos = ShortcutSettings(
      appSettings,
      primaryIsMeta: false,
      metaSupported: false,
      standaloneGlobalKeys: false,
    );
    final error = ohos.setBinding(
      ShortcutAction.playPause,
      ShortcutScope.global,
      ShortcutBinding(keyId: LogicalKeyboardKey.f8.keyId),
    );
    expect(error, contains('修饰键'));
  });
}
