import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/settings_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:sqlite3/open.dart';

/// 淡入淡出时长范围 0.5~2s（US3）：
/// - `AppSettings.fadeDurationMs` 读取钳制 [500, 2000]（越界历史值收敛到
///   最近边界，不迁移存储）；
/// - 设置页滑条 min 0.5 / max 2.0 / divisions 15（0.1s 步进，16 档）、
///   一位小数标签、写入 `(v*1000).round()`。
///
/// 沿用仓库「真实实例」模式（见 player_audio_config_test.dart）：真实
/// LocalIndex（sqlite3 open.overrideFor）+ FakePathProvider。

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
    dir = await Directory.systemTemp.createTemp('selfmusic_faderange_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    // 保持同步（FakeAsync 下真实 await 不会被推进）；Windows 上写隔离
    // isolate 句柄释放滞后导致的删除失败静默留给系统临时目录清理。
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('fadeDurationMs 读取钳制 [500, 2000]', () {
    test('写 3000（旧版越界值）读 2000：收敛到上界，不崩溃', () {
      final settings = AppSettings(index);
      settings.fadeDurationMs = 3000;
      expect(settings.fadeDurationMs, 2000);
    });

    test('写 500 读 500：下界保留', () {
      final settings = AppSettings(index);
      settings.fadeDurationMs = 500;
      expect(settings.fadeDurationMs, 500);
    });

    test('未写时默认 2000；写后重读一致（持久化往返）', () {
      final settings = AppSettings(index);
      expect(settings.fadeDurationMs, 2000, reason: '默认 2000ms');
      settings.fadeDurationMs = 1200;
      expect(settings.fadeDurationMs, 1200);
      // 新实例重读同一 LocalIndex：持久化往返一致。
      final again = AppSettings(index);
      expect(again.fadeDurationMs, 1200);
    });
  });

  testWidgets('设置页淡入淡出滑条：min 0.5 / max 2.0 / divisions 15 / 一位小数标签',
      (tester) async {
    // 预写越界旧值（3000ms）：构建页面时显示端 clamp 到上界 2.0。
    final settings = AppSettings(index)..fadeDurationMs = 3000;
    final nav = NavigationProvider()..openSettings(SettingsItem.playback);
    final direct = DirectSourceManager()..settings = settings;

    // 超大视口：分区是懒构建的 ListView，默认 800x600 视口放不下滑条。
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MultiProvider(providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ], child: const SettingsScreen()),
      ),
    ));

    // 均衡器默认关：按 key 精确定位淡入淡出滑条（页面另有应用内音量滑条）。
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')));
    expect(slider.min, 0.5, reason: '范围下界 0.5s');
    expect(slider.max, 2.0, reason: '范围上界 2.0s');
    expect(slider.divisions, 15, reason: '0.1s 步进（16 档）');
    expect(slider.value, 2.0, reason: '越界旧值 3000ms 显示端钳制到 2.0');
    expect(slider.label, '2.0 秒', reason: '标签一位小数');

    // 拖到下界：写入 500ms，标签跟随。
    tester
        .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')))
        .onChanged!(0.5);
    await tester.pump();
    expect(settings.fadeDurationMs, 500, reason: '写入 (v*1000).round()');
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')))
            .value,
        0.5);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')))
            .label,
        '0.5 秒');

    // 0.1s 步进中段档位：1.2 → 1200ms。
    tester
        .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')))
        .onChanged!(1.2);
    await tester.pump();
    expect(settings.fadeDurationMs, 1200);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('fade-duration-slider')))
            .label,
        '1.2 秒');
  });
}
