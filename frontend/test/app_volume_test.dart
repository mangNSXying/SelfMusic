import 'dart:async';
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
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/settings_screen.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_appvolume_');
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

  PlayerProvider makeProvider({
    int volume = 100,
    bool fade = false,
    int durationMs = 500,
  }) {
    final settings = AppSettings(index)
      ..appVolume = volume
      ..fadeEnabled = fade
      ..fadeDurationMs = durationMs;
    final p = PlayerProvider();
    p.attachAppSettings(settings);
    addTearDown(p.dispose);
    return p;
  }

  void startPlaying(PlayerProvider p) {
    try {
      unawaited(p.player.play());
    } catch (_) {}
  }

  test('appVolume 默认 100、越界钳制、持久化往返', () {
    final settings = AppSettings(index);
    expect(settings.appVolume, 100);

    settings.appVolume = 40;
    expect(settings.appVolume, 40);
    expect(AppSettings(index).appVolume, 40);

    settings.appVolume = 150;
    expect(settings.appVolume, 100);
    settings.appVolume = -5;
    expect(settings.appVolume, 0);
  });

  testWidgets('设置音量立即作用到播放器，静音恢复上次非零值', (tester) async {
    final p = makeProvider(volume: 100);
    expect(p.player.volume, 1.0);

    p.setAppVolume(40);
    expect(p.appVolume, 40);
    expect(p.player.volume, closeTo(0.4, 1e-9));
    expect(AppSettings(index).appVolume, 40);

    p.toggleAppVolumeMute();
    expect(p.appVolume, 0);
    expect(p.player.volume, 0);
    p.toggleAppVolumeMute();
    expect(p.appVolume, 40);
    expect(p.player.volume, closeTo(0.4, 1e-9));
  });

  testWidgets('快捷键步进按 5% 钳制', (tester) async {
    final p = makeProvider(volume: 98);
    p.nudgeAppVolume(5);
    expect(p.appVolume, 100);
    p.nudgeAppVolume(-5);
    expect(p.appVolume, 95);
    p.nudgeAppVolume(-100);
    expect(p.appVolume, 0);
  });

  testWidgets('暂停态重建播放器后保持应用音量', (tester) async {
    final p = makeProvider(volume: 30);
    expect(p.player.volume, closeTo(0.3, 1e-9));

    p.setAppVolume(60);
    await tester.runAsync(() => p.applyAudioConfig());
    expect(p.player.volume, closeTo(0.6, 1e-9));
  });

  testWidgets('淡出完成复位到应用音量', (tester) async {
    final p = makeProvider(volume: 40, fade: true, durationMs: 500);
    startPlaying(p);
    expect(p.player.volume, closeTo(0.4, 1e-9));

    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.player.playing, isFalse);
    expect(p.player.volume, closeTo(0.4, 1e-9));
  });

  testWidgets('淡出中反向回播：音量回到应用音量', (tester) async {
    final p = makeProvider(volume: 40, fade: true, durationMs: 500);
    startPlaying(p);
    unawaited(p.toggle());
    await tester.pump(const Duration(milliseconds: 250));
    expect(p.player.volume, lessThan(0.4));

    unawaited(p.toggle());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.player.playing, isTrue);
    expect(p.player.volume, closeTo(0.4, 1e-9));
  });

  testWidgets('淡出中调音量不打断暂停，完成后按新值复位', (tester) async {
    final p = makeProvider(volume: 40, fade: true, durationMs: 500);
    startPlaying(p);
    unawaited(p.toggle());
    await tester.pump(const Duration(milliseconds: 250));

    p.setAppVolume(80);
    expect(p.player.playing, isTrue, reason: '调音量不应取消暂停');
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.player.playing, isFalse);
    expect(p.player.volume, closeTo(0.8, 1e-9));
  });

  testWidgets('设置页音量滑条：0~100、1% 步进，拖动立即写入', (tester) async {
    final settings = AppSettings(index)..appVolume = 70;
    final player = PlayerProvider();
    player.attachAppSettings(settings);
    addTearDown(player.dispose);
    final nav = NavigationProvider()..openSettings(SettingsItem.playback);
    final direct = DirectSourceManager()..settings = settings;

    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MultiProvider(
          providers: [
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: const SettingsScreen(),
        ),
      ),
    ));

    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('app-volume-slider')));
    expect(slider.min, 0);
    expect(slider.max, 100);
    expect(slider.divisions, 100);
    expect(slider.value, 70);

    slider.onChanged!(35);
    await tester.pump();
    expect(settings.appVolume, 35);
    expect(player.appVolume, 35);
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('app-volume-slider')))
          .value,
      35,
    );
  });
}
