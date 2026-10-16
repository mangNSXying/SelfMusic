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
import 'package:selfmusic/screens/player_screen.dart';
import 'package:selfmusic/screens/queue_page.dart';
import 'package:selfmusic/widgets/row_list.dart';
import 'package:selfmusic/widgets/song_list.dart';
import 'package:sqlite3/open.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 播放器带「歌单页」（竖屏 PageView 第 0 页）进入即追焦当前播放歌曲：
/// - 首挂载：列表同步算出当前曲的展示行位置，用 initialScrollOffset 首帧落定
///   （队列兜底 [QueuePage] 与绑定歌单 [SongList] 同一口径）；
/// - 重进：邻页被 allowImplicitScrolling 保活，重进不重挂载——[PlayerScreen]
///   在 onPageChanged(0) 递增 focusTick，页内列表据此重新定位到当前曲。
///
/// 修复前：[QueuePage] 无任何追焦逻辑，进入歌单页恒停在队首；[SongList] 只有
/// 挂载追焦，保活后换歌重进不重新定位。
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
  String get key => 'webdav:band';
  @override
  String get name => 'band';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

Song _song(int i) => Song(
      id: 0,
      sourceKey: 'webdav:band',
      title: '队列歌曲 $i',
      source: 'webdav',
      sourceRef: 's$i.mp3',
      fileSize: 0,
    );

class _Env {
  _Env(this.direct, this.player, this.playlists, this.nav);
  final DirectSourceManager direct;
  final PlayerProvider player;
  final PlaylistsProvider playlists;
  final NavigationProvider nav;

  Widget app() => MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>.value(value: playlists),
          ],
          child: const PlayerScreen(),
        ),
      );

  void dispose() {
    player.dispose();
    playlists.dispose();
    nav.dispose();
    direct.dispose();
  }
}

/// 60 首队列，当前停在 [current]（0 基）；[playlistName] 非空时另建绑定歌单
/// （歌单条目的 sourceKey/songRef 与播放队列一致，[SongList] 才能认到当前曲）。
Future<_Env> _env(
    {int count = 60, int current = 25, String? playlistName}) async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_bandfocus_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  final songs = [for (var i = 1; i <= count; i++) _song(i)];
  String? uuid;
  if (playlistName != null) {
    final pid = await direct.index.createPlaylist(playlistName);
    uuid = direct.index.playlistUuidOf(pid);
    for (final s in songs) {
      await direct.index.addPlaylistItem(pid,
          sourceKey: s.sourceKey,
          songRef: s.sourceRef,
          title: s.title,
          source: s.source);
    }
  }
  final player = PlayerProvider();
  player.loadOverride = (s, src) async {};
  await player.playQueue(songs,
      index: current,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: uuid == null ? null : PlayerProvider.anchorForPlaylist(uuid));
  final playlists = PlaylistsProvider(direct.playlists)..refresh();
  return _Env(direct, player, playlists, NavigationProvider());
}

/// 竖屏窄屏（400×800）：player_screen 走竖屏三分页分支。
void _portrait(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 60);
  addTearDown(tester.view.reset);
}

/// 打开播放页并等邻页预热（350ms/800ms 计时）。
Future<void> _openPlayer(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(env.app());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _enterBandPage(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(400, 0), 2000);
  await tester.pumpAndSettle();
}

Future<void> _leaveBandPage(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(-400, 0), 2000);
  await tester.pumpAndSettle();
}

/// [scope]（QueuePage/SongList）内标题为 [title] 的行。
Finder _songRow(Finder scope, String title) => find.ancestor(
      of: find.descendant(of: scope, matching: find.text(title)),
      matching: find.byType(SongTile),
    );

/// 行顶距列表视口顶的像素偏移（追焦口径 = 目标行置于顶下 96px）。
double _offsetFromListTop(WidgetTester tester, Finder scope, Finder row) {
  final list = find.descendant(of: scope, matching: find.byType(RowList));
  return tester.getTopLeft(row).dy - tester.getTopLeft(list).dy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedWakelock = WakelockPlusPlatformInterface.instance;
  setUp(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());
  tearDown(() => WakelockPlusPlatformInterface.instance = savedWakelock);

  testWidgets('竖屏兜底队列歌单页：进入即追焦当前播放歌曲', (tester) async {
    late final _Env env;
    await tester.runAsync(() async {
      env = await _env(current: 25);
    });
    addTearDown(env.dispose);
    _portrait(tester);

    await _openPlayer(tester, env);
    await _enterBandPage(tester);

    final queue = find.byType(QueuePage);
    expect(queue, findsOneWidget);
    // 修复前：无追焦逻辑，列表停在队首，「队列歌曲 26」不在构建范围内。
    final cur = _songRow(queue, '队列歌曲 26');
    expect(cur, findsOneWidget);
    expect(_offsetFromListTop(tester, queue, cur), closeTo(96, 2));
    // 队首已滚出可视区（证明是定位，不是碰巧停在顶部）。
    expect(find.descendant(of: queue, matching: find.text('队列歌曲 1')),
        findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('竖屏兜底队列歌单页：回播放页切歌再进，重新追焦新当前曲', (tester) async {
    late final _Env env;
    await tester.runAsync(() async {
      env = await _env(current: 25);
    });
    addTearDown(env.dispose);
    _portrait(tester);

    await _openPlayer(tester, env);
    await _enterBandPage(tester);
    expect(_songRow(find.byType(QueuePage), '队列歌曲 26'), findsOneWidget);

    // 回播放页切到第 51 首，再进歌单页：邻页保活不重挂载，靠 focusTick 重追焦。
    await _leaveBandPage(tester);
    await tester.runAsync(() => env.player.playAt(50));
    await tester.pump();
    await _enterBandPage(tester);

    final queue = find.byType(QueuePage);
    final cur = _songRow(queue, '队列歌曲 51');
    expect(cur, findsOneWidget);
    expect(_offsetFromListTop(tester, queue, cur), closeTo(96, 2));
    expect(find.descendant(of: queue, matching: find.text('队列歌曲 26')),
        findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('竖屏绑定歌单页：进入即追焦、切歌重进再追焦', (tester) async {
    late final _Env env;
    await tester.runAsync(() async {
      env = await _env(current: 25, playlistName: '追焦测试歌单');
    });
    addTearDown(env.dispose);
    _portrait(tester);

    await _openPlayer(tester, env);
    await _enterBandPage(tester);

    final list = find.byType(SongList);
    expect(list, findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('追焦测试歌单')),
        findsOneWidget);
    final cur = _songRow(list, '队列歌曲 26');
    expect(cur, findsOneWidget);
    expect(_offsetFromListTop(tester, list, cur), closeTo(96, 2));

    // 回播放页切歌再进：tick 重定位到新的当前曲。
    await _leaveBandPage(tester);
    await tester.runAsync(() => env.player.playAt(50));
    await tester.pump();
    await _enterBandPage(tester);

    final list2 = find.byType(SongList);
    final cur2 = _songRow(list2, '队列歌曲 51');
    expect(cur2, findsOneWidget);
    expect(_offsetFromListTop(tester, list2, cur2), closeTo(96, 2));
    expect(find.descendant(of: list2, matching: find.text('队列歌曲 26')),
        findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('横屏分栏歌单页：左栏队列进入即追焦当前播放歌曲', (tester) async {
    late final _Env env;
    await tester.runAsync(() async {
      env = await _env(current: 25);
    });
    addTearDown(env.dispose);
    // 桌面测试宿主恒走「左歌单右播放」双栏分栏：左栏为嵌入式 QueuePage。
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    await _openPlayer(tester, env);
    await _enterBandPage(tester);

    expect(find.byType(DesktopPlaylistSplit), findsOneWidget);
    final queue = find.byType(QueuePage);
    expect(queue, findsOneWidget);
    final cur = _songRow(queue, '队列歌曲 26');
    expect(cur, findsOneWidget);
    expect(_offsetFromListTop(tester, queue, cur), closeTo(96, 2));

    await tester.pumpWidget(const SizedBox());
  });
}
