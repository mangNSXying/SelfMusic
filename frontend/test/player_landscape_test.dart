import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/player_screen.dart';
import 'package:sqlite3/open.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 横屏播放页布局回归：
/// - 手机三列左栏封面按剩余高度自适应收缩，矮屏不再 RenderFlex overflow
///   （旧实现把封面以外的高度写死为 150，低估实际固定内容 → 必溢 4px+）；
/// - 横屏铺满到屏幕底，底部系统手势条安全区不留占位空白（竖屏仍保留）。
///
/// 桌面测试宿主上 `Platform.isLinux` 为真，经 [PlayerScreen] 恒走桌面双栏
/// 分支，故三列布局直接挂载 [LandscapePlayer] 覆盖。

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
  String get key => 'webdav:land';
  @override
  String get name => 'land';
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
      sourceKey: 'webdav:land',
      title: '横屏测试曲目',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_land_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

/// 置入「正在播放」现场：不触真实装载（loadOverride），只为让
/// [PlayerProvider.hasCurrent] 成立，渲染三列播放布局。
Future<PlayerProvider> _playerWithCurrent() async {
  final p = PlayerProvider();
  p.loadOverride = (s, src) async {};
  await p.playQueue([_song()], source: _FakeSource());
  return p;
}

/// 当前焦点是否落在输入框内（与 player_screen 判定口径一致：TextField 的焦点
/// 挂在内部外层 Focus 上，沿祖先链找输入框）。
bool _focusIsTextInput() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  return ctx.findAncestorWidgetOfExactType<TextField>() != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedWakelock = WakelockPlusPlatformInterface.instance;
  setUp(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());
  tearDown(() => WakelockPlusPlatformInterface.instance = savedWakelock);

  test('横屏布局分流：桌面平台恒双栏；手机窄横屏三列；超宽屏双栏', () {
    // 手机横屏（窄屏）：三列紧凑。
    expect(useDesktopLandscape(const Size(800, 480),
        isDesktopPlatform: false), isFalse);
    // 桌面平台即使窗口不长：双栏居中。
    expect(useDesktopLandscape(const Size(800, 480),
        isDesktopPlatform: true), isTrue);
    // 超宽屏（大平板横屏，Android）：双栏。
    expect(useDesktopLandscape(const Size(1440, 900),
        isDesktopPlatform: false), isTrue);
    // 临界值 1000。
    expect(useDesktopLandscape(const Size(999, 600),
        isDesktopPlatform: false), isFalse);
    expect(useDesktopLandscape(const Size(1000, 600),
        isDesktopPlatform: false), isTrue);
  });

  testWidgets('手机横屏三列：封面自适应收缩，底部不溢出', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: Scaffold(
            body: LandscapePlayer(
              player: player,
              direct: direct,
              cs: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 修复前：写死的固定高度预算（150 < 实际 ~154）让左栏必溢 4px+。
    expect(tester.takeException(), isNull, reason: '手机横屏左栏不得 RenderFlex overflow');

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    // 进度条贴着左栏底边（padding 10），说明固定行之外的空间全给了封面，
    // 三列恰好放满一屏而不是溢出/滚动。
    final bottom = tester.getBottomLeft(slider).dy;
    expect(bottom, closeTo(350, 1));
    expect(bottom, lessThanOrEqualTo(360));
  });

  testWidgets('横屏播放页铺满到屏幕底：底部系统安全区不占位', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    // 桌面测试宿主走双栏分支。宽度取 800：既考察底部安全区口径，也覆盖
    // 左栏被 clamp 到最小宽 320 时控制行（~302 > 280）的横向溢出回归。
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    // 模拟状态栏 24 / 手势条 24：横屏只让出顶部，底边不再留白。
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>(
                create: (_) => NavigationProvider()),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 修复前：SafeArea 连底边一起让出 → 高 312（360-24-24），底部一条空白；
    // 修复后仅顶部 24 让位 → 336。
    expect(tester.getSize(find.byType(PageView)).height, closeTo(336, 0.5));

    // 卸载以取消播放页控件自动隐藏 Timer。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机横屏分栏：左歌单右播放同显，不溢出', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: Scaffold(
            body: LandscapePlaylistSplit(
              player: player,
              direct: direct,
              cs: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '手机横屏分栏不得溢出');
    // 左栏歌单（无绑定歌单时兜底队列，完整搜索框保留）与右窗播放同显。
    expect(find.textContaining('播放队列'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // 右窗进度条贴着底边，说明分栏恰好放满一屏。
    expect(tester.getBottomLeft(find.byType(Slider)).dy,
        lessThanOrEqualTo(360));
  });

  testWidgets('桌面横屏分栏：左歌单右播放同显，不溢出', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: Scaffold(
            body: DesktopPlaylistSplit(
              player: player,
              direct: direct,
              cs: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '桌面横屏分栏不得溢出');
    expect(find.textContaining('播放队列'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('横屏滑到歌单页后：左歌单右播放分栏 settle', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>(
                create: (_) => NavigationProvider()),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();
    // 等邻页预热（350ms/800ms 计时）使 page0 装配。
    await tester.pump(const Duration(milliseconds: 900));

    // 桌面测试宿主走桌面分支：初始在播放页，右滑进入分栏歌单页。
    await tester.fling(find.byType(PageView), const Offset(400, 0), 2000);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(DesktopPlaylistSplit), findsOneWidget);
    expect(find.textContaining('播放队列'), findsOneWidget);
    expect(find.byType(Slider), findsWidgets);

    // 卸载以取消播放页控件自动隐藏 Timer。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ESC 关闭播放页（停在播放页时）', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    final nav = NavigationProvider();
    addTearDown(() {
      player.dispose();
      direct.dispose();
      nav.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(nav.playerView, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(nav.playerView, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ESC 在歌单页不拦截（仅播放页）', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    final nav = NavigationProvider();
    addTearDown(() {
      player.dispose();
      direct.dispose();
      nav.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // 右滑进入分栏歌单页（page0）。
    await tester.fling(find.byType(PageView), const Offset(400, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopPlaylistSplit), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(nav.playerView, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索框聚焦时 ESC 先失焦、再按关闭', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    final nav = NavigationProvider();
    addTearDown(() {
      player.dispose();
      direct.dispose();
      nav.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // 右滑进入分栏歌单页，点搜索框聚焦（无绑定歌单时兜底嵌入式队列）。
    await tester.fling(find.byType(PageView), const Offset(400, 0), 2000);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(_focusIsTextInput(), isTrue);

    // 左滑回到播放页（搜索框焦点仍在后台 page0），第一次 ESC 只失焦。
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 2000);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(nav.playerView, isTrue);
    expect(_focusIsTextInput(), isFalse);

    // 第二次 ESC 关闭播放页。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(nav.playerView, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机三列下滑：播放列触发、歌词区不触发', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var dragged = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: Scaffold(
            body: LandscapePlayer(
              player: player,
              direct: direct,
              cs: ColorScheme.fromSeed(seedColor: Colors.teal),
              onVerticalDragStart: (_) => dragged = true,
              onVerticalDragUpdate: (_) {},
              onVerticalDragEnd: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 封面区（左播放列，宽 336）下滑：触发跟手。
    await tester.dragFrom(const Offset(168, 120), const Offset(0, 150));
    await tester.pump();
    expect(dragged, isTrue);

    // 歌词区（中列）下滑：detector 未覆盖，不触发（歌词纵滚接管）。
    dragged = false;
    await tester.dragFrom(const Offset(532, 180), const Offset(0, 150));
    await tester.pump();
    expect(dragged, isFalse);
    expect(tester.takeException(), isNull);
  });
}
