import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/player/player_layouts.dart';
import 'package:selfmusic/screens/player/player_now_playing.dart';
import 'package:selfmusic/screens/player/player_screen.dart';
import 'package:selfmusic/theme/app_metrics.dart';
import 'package:selfmusic/widgets/app_volume_control.dart';
import 'package:selfmusic/widgets/player_controls.dart';
import 'package:selfmusic/widgets/pressable.dart';
import 'package:sqlite3/open.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 播放页工具栏/控制行尺寸回归。
///
/// 旧实现里工具行四枚按钮用隐式 `IconButton`（命中区 = 图标 + 内边距），
/// 音量/模式/定时则写死 48：4K 下同一行出现 48/60 两种命中区（图标 44
/// 几乎顶满 48 的框），1440p 下又全部塌回 48。工具行还走
/// `mainAxisSize.min` + `FittedBox`，在大列里挤成一小团、不随列宽铺开。
/// 这些断言锁住「同组按钮同一尺寸」与「工具行随宽铺开」两条不变量。

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

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:size';
  @override
  String get name => 'size';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:size',
      title: '尺寸回归曲目',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

Future<({DirectSourceManager direct, PlayerProvider player})> _open() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_size_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  final player = PlayerProvider();
  player.loadOverride = (s, src) async {};
  await player.playQueue([_song()], source: _FakeSource());
  return (direct: direct, player: player);
}

Widget _landscape(PlayerProvider player, DirectSourceManager direct) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ],
      child: Scaffold(
        body: DesktopLandscapePlayer(
          player: player,
          direct: direct,
          cs: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
      ),
    ),
  );
}

Widget _portrait(PlayerProvider player, DirectSourceManager direct) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<NavigationProvider>(
            create: (_) => NavigationProvider()),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<PlaylistsProvider>(
            create: (_) => PlaylistsProvider(direct.playlists)),
      ],
      child: const PlayerScreen(desktopPlatformOverride: false),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedWakelock = WakelockPlusPlatformInterface.instance;
  setUp(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());
  tearDown(() => WakelockPlusPlatformInterface.instance = savedWakelock);

  for (final entry in [
    (const Size(1280, 800), 1.0),
    (const Size(1920, 1080), 1.0),
    (const Size(2560, 1440), 4 / 3),
    (const Size(3840, 2160), 2.0),
  ]) {
    final size = entry.$1;
    final scale = entry.$2;

    testWidgets('桌面 $size：工具行 5 枚按钮同尺寸（${48 * scale}）', (tester) async {
      late final DirectSourceManager direct;
      late final PlayerProvider player;
      await tester.runAsync(() async {
        final r = await _open();
        direct = r.direct;
        player = r.player;
      });
      addTearDown(() {
        player.dispose();
        direct.dispose();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_landscape(player, direct));
      await tester.pump();

      final expected = kPlayerSecondaryButtonSize * scale;
      // 工具行 5 枚（喜欢/不喜欢/编辑/缓存/音量）命中区必须一致——
      // 修复前这里会是 48/48/48/48/48 与 60 混排（4K）。
      final row = find.byType(ToolRow);
      final boxes = <Size>[];
      for (final w in tester.widgetList<IconButton>(
          find.descendant(of: row, matching: find.byType(IconButton)))) {
        boxes.add(tester.getRect(find.byWidget(w)).size);
      }
      expect(boxes, hasLength(5));
      for (final box in boxes) {
        expect(box.width, closeTo(expected, 0.01),
            reason: '工具行按钮命中区应统一为 $expected');
        expect(box.height, closeTo(expected, 0.01),
            reason: '工具行按钮命中区应统一为 $expected');
      }

      // 图标也要同尺寸（音量是自绘 CustomPaint，一并纳入）。
      final iconSize = kPlayerSecondaryIconSize * scale;
      expect(tester.getSize(find.byIcon(Icons.favorite_border)).width,
          closeTo(iconSize, 0.01));
      expect(tester.getSize(find.byType(AppVolumeIcon)).width,
          closeTo(iconSize, 0.01));

      // 图标与命中区保持固定比例，不出现「图标顶满按钮」。
      expect(iconSize / expected, closeTo(22 / 48, 0.001));

      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面 $size：工具行比播控行窄、且不随列宽外扩', (tester) async {
      late final DirectSourceManager direct;
      late final PlayerProvider player;
      await tester.runAsync(() async {
        final r = await _open();
        direct = r.direct;
        player = r.player;
      });
      addTearDown(() {
        player.dispose();
        direct.dispose();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_landscape(player, direct));
      await tester.pump();

      // 两行同构：都由内容定宽。工具行 = 5×48 + 4×12 = 288×scale，
      // 主控制行 = 314×scale，因此工具栏恒比播控行窄（次级入口不抢重心）。
      final toolRow = tester.getSize(find
          .descendant(of: find.byType(ToolRow), matching: find.byType(Row))
          .first);
      final controlRow = tester.getSize(find
          .descendant(of: find.byType(ControlRow), matching: find.byType(Row))
          .first);

      expect(toolRow.width, closeTo(kPlayerToolRowWidth * scale, 0.01),
          reason: '工具行宽度应为内容宽度，不铺满容器');
      expect(controlRow.width, closeTo(kPlayerControlsRowWidth * scale, 0.01));
      expect(toolRow.width, lessThan(controlRow.width),
          reason: '工具栏比播控栏更窄好过更宽');

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('桌面各档：主控制行同组控件尺寸按同一口径', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      final r = await _open();
      direct = r.direct;
      player = r.player;
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    const scale = 2.0;
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_landscape(player, direct));
    await tester.pump();

    // 次级键（定时/模式）同尺寸——修复前定时与模式都是固定 48，
    // 而切歌键是「图标 + 内边距」推出来的 60。
    const secondary = kPlayerSecondaryButtonSize * scale;
    final sleep = tester.getRect(find.descendant(
        of: find.byType(SleepButton), matching: find.byType(IconButton)));
    final mode = tester.getRect(find.descendant(
        of: find.byType(ModeButton), matching: find.byType(IconButton)));
    expect(sleep.width, closeTo(secondary, 0.01));
    expect(sleep.height, closeTo(secondary, 0.01));
    expect(mode.width, closeTo(secondary, 0.01));
    expect(mode.height, closeTo(secondary, 0.01));

    // 切歌键：命中区统一为 56×scale，图标 34×scale。
    const skipIcon = kPlayerSkipIconSize * scale;
    expect(tester.getSize(find.byIcon(Icons.skip_previous)).width,
        closeTo(skipIcon, 0.01));
    expect(tester.getSize(find.byIcon(Icons.skip_next)).width,
        closeTo(skipIcon, 0.01));
    // 切歌键所在的 Pressable 命中区（图标居中于 56×scale 的 SizedBox）。
    final prevHit = tester.getRect(find
        .ancestor(
            of: find.byIcon(Icons.skip_previous),
            matching: find.byType(Pressable))
        .first);
    expect(prevHit.width, closeTo(kPlayerSkipButtonSize * scale, 0.01));
    expect(prevHit.height, closeTo(kPlayerSkipButtonSize * scale, 0.01));

    // 播放键图标按 74×scale。
    const primary = kPlayerPrimaryButtonSize * scale;
    final playIcon = tester.getSize(find.descendant(
        of: find.byType(PlayPauseButton), matching: find.byType(Icon)));
    expect(playIcon.width, closeTo(primary, 0.01));
    expect(playIcon.height, closeTo(primary, 0.01));

    expect(tester.takeException(), isNull);
  });

  testWidgets('竖屏 360：工具行与控制行不溢出（旧实现溢出 2px）', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      final r = await _open();
      direct = r.direct;
      player = r.player;
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_portrait(player, direct));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '极窄竖屏下工具行/控制行不得 RenderFlex overflow');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('竖屏平板：工具行随内容宽放大（图标不顶满命中区）', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      final r = await _open();
      direct = r.direct;
      player = r.player;
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_portrait(player, direct));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 竖屏 scale = 1.6：命中区 76.8、图标 35.2，两者按固定比例同步放大。
    final heart = tester.getSize(find.byIcon(Icons.favorite_border));
    expect(heart.width, closeTo(kPlayerSecondaryIconSize * 1.6, 0.01));
    expect(heart.width / (kPlayerSecondaryButtonSize * 1.6),
        closeTo(22 / 48, 0.001));

    await tester.pumpWidget(const SizedBox());
  });
}
