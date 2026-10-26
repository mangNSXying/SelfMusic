import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:sqlite3/open.dart';

// ─────────────────────────────────────────────────────────────────────────────
// T001：重建计数测试辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 测试期「重建计数」登记表（T001 / R-8）。
///
/// 累计各"目标 Widget"（由 [NavRebuildProbe] 代表）的 build 次数，供
/// SC-002（非必要订阅者重建次数 = 0）与 SC-003（排序/过滤重算 = 0）断言。
class NavRebuildCounter {
  final Map<String, int> _counts = <String, int>{};

  void record(String label) => _counts[label] = (_counts[label] ?? 0) + 1;

  int of(String label) => _counts[label] ?? 0;

  void reset() => _counts.clear();
}

/// 目标 Widget 的 build 次数探针（T001）。
///
/// 以与生产消费方**完全一致的订阅表达式**（`context.select<NavigationProvider, T>`
/// 或 `NavRouteKey` record）订阅导航状态，并在每次 build 时登记一次。
///
/// `context.select` 仅在所选值按 `==` 变化时触发重建（record 为结构相等），
/// 因此探针自身的 build 次数即"该订阅契约下的重建次数"：用于断言
/// 「区段变更时壳层/侧栏/迷你条/分组视图重建次数 = 0」——分组视图不重建，
/// 其 build 内的排序/过滤自然也不会重算（SC-003）。
///
/// 说明：探针本身即"目标 Widget"（被计数的对象）。真机逐帧掉帧测量
/// （SC-001 / FR-006）不在单测范围，见 spec/content-switch-jank/baseline.md。
class NavRebuildProbe<T> extends StatelessWidget {
  final NavRebuildCounter counter;
  final String label;
  final T Function(NavigationProvider nav) selector;

  const NavRebuildProbe({
    super.key,
    required this.counter,
    required this.label,
    required this.selector,
  });

  @override
  Widget build(BuildContext context) {
    // 只订阅最小关注字段：所选值不变则不重建。
    context.select<NavigationProvider, T>(selector);
    counter.record(label);
    return const SizedBox.shrink();
  }
}

/// 构造与各生产消费方订阅表达式一一对应的探针集合（labels 即生产消费方命名）。
List<Widget> _probes(NavRebuildCounter c) => [
      // 布局壳（AppShell）→ queueOpen
      NavRebuildProbe<bool>(
          counter: c, label: 'shell', selector: (n) => n.queueOpen),
      // 侧栏（Sidebar）→ settings
      NavRebuildProbe<SettingsItem?>(
          counter: c, label: 'sidebar', selector: (n) => n.settings),
      // 迷你播放条（MiniPlayerBar）→ queueOpen
      NavRebuildProbe<bool>(
          counter: c, label: 'miniBar', selector: (n) => n.queueOpen),
      // 分组视图（_SongsView/_LikedView/_AlbumsView/_ArtistsView）→ search
      NavRebuildProbe<String>(
          counter: c, label: 'songsView', selector: (n) => n.search),
      NavRebuildProbe<String>(
          counter: c, label: 'likedView', selector: (n) => n.search),
      NavRebuildProbe<String>(
          counter: c, label: 'albumsView', selector: (n) => n.search),
      NavRebuildProbe<String>(
          counter: c, label: 'artistsView', selector: (n) => n.search),
      // 歌单列表 / 歌单详情（globalSearch）→ search
      NavRebuildProbe<String>(
          counter: c, label: 'playlistsView', selector: (n) => n.search),
      NavRebuildProbe<String>(
          counter: c, label: 'songList', selector: (n) => n.search),
      // 顶栏高亮（_NavBar）→ section
      NavRebuildProbe<NavSection>(
          counter: c, label: 'navBar', selector: (n) => n.section),
      // 内容路由（AppContent）→ routeKey（section + settings + browsing*）
      NavRebuildProbe<NavRouteKey>(
          counter: c, label: 'router', selector: (n) => n.routeKey),
      // 播放页可见性（Root / player_screen）→ playerView
      NavRebuildProbe<bool>(
          counter: c, label: 'root', selector: (n) => n.playerView),
      // 设置页（settings_screen）→ settings
      NavRebuildProbe<SettingsItem?>(
          counter: c, label: 'settingsScreen', selector: (n) => n.settings),
    ];

Widget _probeApp(NavRebuildCounter c) => MaterialApp(
      home: Scaffold(
        body: Column(children: _probes(c)),
      ),
    );

/// 最小内容壳：设置页与分组页互斥，模拟设置关闭时 TopBar 与 SectionPager
/// 在同一帧重建的路径。
class _NavSettingsHarness extends StatelessWidget {
  const _NavSettingsHarness();

  @override
  Widget build(BuildContext context) {
    final inSettings =
        context.select<NavigationProvider, bool>((n) => n.inSettings);
    return Column(
      children: [
        TopBar(onSidebarToggle: () {}),
        Expanded(
          child: inSettings ? const SizedBox.shrink() : const SectionPager(),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 真机/DB 依赖工具（过渡档回归用；本机 sqlite 不可用时优雅跳过）
// ─────────────────────────────────────────────────────────────────────────────

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

/// 尝试创建并初始化一个真实 [DirectSourceManager]；
/// 本机 sqlite 原生库不可用（如 CI/Windows 无 dll）时返回 null → 用例跳过。
Future<DirectSourceManager?> _tryOpenDirect(WidgetTester tester) async {
  DirectSourceManager? direct;
  await tester.runAsync(() async {
    try {
      if (Platform.isLinux) {
        open.overrideFor(OperatingSystem.linux, _openOnLinux);
      }
      final dir = await Directory.systemTemp.createTemp('selfmusic_navsub_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final d = DirectSourceManager();
      await d.init();
      direct = d;
    } catch (e) {
      debugPrint('[nav_subscription_test] sqlite 不可用，跳过过渡档用例：$e');
    }
  });
  return direct;
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // 基线：探针机制自检
  // ───────────────────────────────────────────────────────────────────────────
  testWidgets('重建计数探针基线：所列值不变时不重建、变化时重建', (tester) async {
    final nav = NavigationProvider();
    final counter = NavRebuildCounter();
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: _probeApp(counter),
      ),
    );
    await tester.pump();

    counter.reset();

    // 区段变更：shell/miniBar（queueOpen）、分组视图（search）、root（playerView）
    // 订阅字段未变 → 0；navBar（section）/router（routeKey）→ 1。
    // 注意初始 playerView=true，select 会置 false，故 root 单独看：此处先隔离。
    nav.select(NavSection.songs); // 先入内容态
    await tester.pump();
    counter.reset();

    nav.select(NavSection.albums);
    await tester.pump();
    expect(counter.of('shell'), 0);
    expect(counter.of('miniBar'), 0);
    expect(counter.of('songsView'), 0);
    expect(counter.of('root'), 0);
    expect(counter.of('navBar'), 1);
    expect(counter.of('router'), 1);

    // 搜索变更：分组视图/歌单/歌单详情重建；壳/侧栏/迷你条/高亮/路由不重建。
    counter.reset();
    nav.setSearch('周');
    await tester.pump();
    for (final l in [
      'songsView',
      'likedView',
      'albumsView',
      'artistsView',
      'playlistsView',
      'songList'
    ]) {
      expect(counter.of(l), 1, reason: '$l 应随搜索词重建');
    }
    for (final l in [
      'shell',
      'sidebar',
      'miniBar',
      'navBar',
      'router',
      'root',
      'settingsScreen'
    ]) {
      expect(counter.of(l), 0, reason: '$l 不应随搜索词重建');
    }

    // 同值 setSearch 提前返回（不通知）→ 0 次。
    counter.reset();
    nav.setSearch('周');
    await tester.pump();
    expect(counter.of('songsView'), 0);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // T013 / SC-002 / SC-003：区段变更只重建"顶栏高亮 + 内容路由"
  // ───────────────────────────────────────────────────────────────────────────
  group('SC-002/SC-003 区段变更重建与重算', () {
    testWidgets('区段切换：壳/侧栏/迷你条/分组视图重建次数 = 0', (tester) async {
      final nav = NavigationProvider();
      final counter = NavRebuildCounter();
      await tester.pumpWidget(
        ChangeNotifierProvider<NavigationProvider>.value(
          value: nav,
          child: _probeApp(counter),
        ),
      );
      await tester.pump();

      // 进入内容态（playerView: true→false），再复位计数以隔离"纯区段变更"。
      nav.select(NavSection.songs);
      await tester.pump();
      counter.reset();

      nav.select(NavSection.albums);
      await tester.pump();

      // 非必要订阅者：0 次重建（SC-002）。
      for (final l in [
        'shell',
        'sidebar',
        'miniBar',
        'root',
        'songsView',
        'likedView',
        'albumsView',
        'artistsView',
        'playlistsView',
        'songList',
        'settingsScreen',
      ]) {
        expect(counter.of(l), 0, reason: '$l 不应因区段变更重建');
      }

      // 必要订阅者：顶栏高亮 + 内容路由，各 1 次。
      expect(counter.of('navBar'), 1);
      expect(counter.of('router'), 1);
    });

    testWidgets('搜索词不变时分组视图重建次数 = 0（排序/过滤重算 0）', (tester) async {
      final nav = NavigationProvider();
      final counter = NavRebuildCounter();
      await tester.pumpWidget(
        ChangeNotifierProvider<NavigationProvider>.value(
          value: nav,
          child: _probeApp(counter),
        ),
      );
      await tester.pump();
      nav.select(NavSection.albums);
      await tester.pump();

      // 连续切换区段多次，分组视图始终不重建 → build 内的排序/过滤不会重算。
      counter.reset();
      for (final s in [
        NavSection.liked,
        NavSection.albums,
        NavSection.artists,
        NavSection.songs,
      ]) {
        nav.select(s);
        await tester.pump();
      }
      for (final l in [
        'songsView',
        'likedView',
        'albumsView',
        'artistsView',
        'playlistsView',
        'songList'
      ]) {
        expect(counter.of(l), 0, reason: '$l 在搜索词未变时不应重算');
      }
      // 路由随区段变化重建（4 次切换）。
      expect(counter.of('router'), 4);
      expect(counter.of('navBar'), 4);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // T014：导航语义回归（公共 API / 字段语义零变化，FR-004）
  // ───────────────────────────────────────────────────────────────────────────
  group('T014 导航语义回归', () {
    test('公共 API 与字段语义不变', () {
      final nav = NavigationProvider();
      var notified = 0;
      nav.addListener(() => notified++);

      // 初值
      expect(nav.section, NavSection.songs);
      expect(nav.search, '');
      expect(nav.playerView, isTrue);
      expect(nav.queueOpen, isFalse);
      expect(nav.settings, isNull);
      expect(nav.browsingSourceKey, isNull);
      expect(nav.browsingPlaylistId, isNull);
      expect(nav.routeKey, (
        section: NavSection.songs,
        settings: null,
        sourceKey: null,
        playlistId: null,
      ));

      // select：切区段、退出播放页、清空设置/源/歌单详情
      nav.select(NavSection.albums, slideOffset: const Offset(-1, 0));
      expect(nav.section, NavSection.albums);
      expect(nav.playerView, isFalse);
      expect(nav.slideOffset, const Offset(-1, 0));
      expect(notified, 1);

      // 搜索：同值提前返回不通知；不同值通知；清空
      nav.setSearch('abc');
      expect(nav.search, 'abc');
      expect(notified, 2);
      nav.setSearch('abc');
      expect(notified, 2, reason: '同值 setSearch 不应通知');
      nav.clearSearch();
      expect(nav.search, '');
      expect(notified, 3);

      // 覆盖区域层级键：source / playlist / settings
      nav.enterSource('local:1');
      expect(nav.browsingSourceKey, 'local:1');
      expect(nav.areaKey, 'src:local:1');
      expect(nav.areaLevel, 2);
      nav.exitSource();
      expect(nav.browsingSourceKey, isNull);
      expect(nav.slideOffset, const Offset(-1, 0));

      nav.enterPlaylist(7);
      expect(nav.browsingPlaylistId, 7);
      expect(nav.areaKey, 'pl:7');
      nav.exitPlaylist();
      expect(nav.browsingPlaylistId, isNull);

      nav.openSettings(SettingsItem.appearance);
      expect(nav.settings, SettingsItem.appearance);
      expect(nav.inSettings, isTrue);
      expect(nav.playerView, isFalse);
      expect(nav.areaKey, 'settings:appearance');
      expect(nav.areaLevel, 3);
      nav.closeSettings();
      expect(nav.settings, isNull);

      // 队列开合：幂等关闭不重复通知
      final before = notified;
      nav.openQueue();
      expect(nav.queueOpen, isTrue);
      nav.closeQueue();
      expect(nav.queueOpen, isFalse);
      nav.closeQueue();
      expect(notified, before + 2, reason: '已关闭时 closeQueue 不应通知');
      nav.toggleQueue();
      expect(nav.queueOpen, isTrue);

      // 播放页意图
      nav.openPlayer();
      expect(nav.playerView, isTrue);
      expect(nav.settings, isNull);
      expect(nav.slideOffset, const Offset(0, 1));
      nav.closePlayer();
      expect(nav.playerView, isFalse);
      expect(nav.slideOffset, const Offset(0, -1));

      // backToPrevious 层级（底 → 顶）：播放页 < 内容页 < 源内/歌单详情 < 队列 < 设置
      nav.openSettings(SettingsItem.general);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.settings, isNull);
      nav.openQueue();
      expect(nav.backToPrevious(), isTrue);
      expect(nav.queueOpen, isFalse);
      nav.enterPlaylist(3);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.browsingPlaylistId, isNull);
      nav.enterSource('s');
      expect(nav.backToPrevious(), isTrue);
      expect(nav.browsingSourceKey, isNull);
      // 内容页 → 返回播放页（首页）
      nav.closePlayer();
      expect(nav.playerView, isFalse);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.playerView, isTrue);
      // 已在最底层（播放页）：无更下一级
      expect(nav.backToPrevious(), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // T014：各过渡档回归（关闭/淡入/缩放/滑动）——真机/DB 依赖，本机 sqlite
  // 不可用时优雅跳过。
  // ───────────────────────────────────────────────────────────────────────────
  testWidgets('各过渡档：切区段行为一致（关闭/淡入/缩放/滑动）', (tester) async {
    final direct = await _tryOpenDirect(tester);
    if (direct == null) return; // 本机 sqlite 不可用 → 跳过（非回归）

    addTearDown(() => direct.dispose());
    final lib = LibraryProvider()..attachDirectManager(direct);
    final nav = NavigationProvider();

    for (final mode in PlayerTransition.values) {
      direct.settings.playerTransition = mode;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<LibraryProvider>.value(value: lib),
            ChangeNotifierProvider<PlaylistsProvider>.value(
                value: PlaylistsProvider(direct.playlists)),
            ChangeNotifierProvider<PlayerProvider>(
                create: (_) => PlayerProvider()),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ],
          child: const MaterialApp(home: Scaffold(body: SectionPager())),
        ),
      );
      await tester.pumpAndSettle();

      // 程序驱动切到"喜欢"分组：各过渡档都应显示喜欢页空态、无异常。
      nav.select(NavSection.liked);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '过渡档 ${mode.label} 不应抛异常');
      expect(find.textContaining('暂无喜欢的歌曲'), findsOneWidget,
          reason: '过渡档 ${mode.label} 应正确路由到喜欢页');
      expect(nav.section, NavSection.liked);
    }
  });

  testWidgets('设置页按 Ctrl+1 回内容页：目标分组高亮立即同步', (tester) async {
    final direct = await _tryOpenDirect(tester);
    if (direct == null) return;

    addTearDown(() => direct.dispose());
    final lib = LibraryProvider()..attachDirectManager(direct);
    final nav = NavigationProvider()..select(NavSection.liked);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<LibraryProvider>.value(value: lib),
          ChangeNotifierProvider<PlaylistsProvider>.value(
              value: PlaylistsProvider(direct.playlists)),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: _NavSettingsHarness()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(nav.pageOffset.value, NavSection.values.indexOf(NavSection.liked));

    nav.openSettings(SettingsItem.general);
    await tester.pumpAndSettle();

    // 设置页内按 Ctrl+1：关闭设置并切到歌单。SectionPager 与 TopBar 会在
    // 同一帧重建，pageOffset 必须等帧后再写，不能触发 build 期 setState。
    nav.select(NavSection.playlists);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(nav.section, NavSection.playlists);
    expect(nav.pageOffset.value,
        NavSection.values.indexOf(NavSection.playlists).toDouble());
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 搜索作用域：顶级分区保留搜索词；进出源/歌单/宽屏详情页清空。
  // ───────────────────────────────────────────────────────────────────────────
  test('搜索词生命周期：顶级分区保留，详情页进出清空', () {
    final nav = NavigationProvider();

    // 顶级分区切换保留（全局筛选语义）。
    nav.setSearch('周');
    nav.select(NavSection.albums);
    expect(nav.search, '周');
    nav.select(NavSection.sources);
    expect(nav.search, '周');

    // 进入源清空；源内输入后退出再清空。
    nav.enterSource('local:test');
    expect(nav.search, '');
    nav.setSearch('夜曲');
    nav.exitSource();
    expect(nav.search, '');

    // 从源内直接点顶部导航切区：同样视为离开详情，清空。
    nav.enterSource('local:test');
    nav.setSearch('夜曲');
    nav.select(NavSection.songs);
    expect(nav.search, '');

    // 返回键离开源内。
    nav.enterSource('local:test');
    nav.setSearch('夜曲');
    expect(nav.backToPrevious(), isTrue);
    expect(nav.search, '');

    // 歌单详情进出清空（含返回键路径）。
    nav.enterPlaylist(7);
    expect(nav.search, '');
    nav.setSearch('晴天');
    nav.exitPlaylist();
    expect(nav.search, '');
    nav.enterPlaylist(7);
    nav.setSearch('晴天');
    expect(nav.backToPrevious(), isTrue);
    expect(nav.search, '');

    // 宽屏专辑/歌手详情进出清空。
    const artist = Artist(name: '周杰伦', songCount: 0, albumCount: 0);
    nav.enterArtist(artist, const []);
    expect(nav.search, '');
    nav.setSearch('夜曲');
    nav.enterAlbum(
      Album(
        id: 1,
        artist: '周杰伦',
        album: '十一月的萧邦',
        groupKey: 'album\x00十一月的萧邦',
        trackCount: 0,
        totalDuration: 0,
      ),
      const [],
    );
    expect(nav.search, '');
    nav.setSearch('晴天');
    nav.exitDetail();
    expect(nav.search, '');
  });

  test('详情页清空搜索不产生重复通知', () {
    final nav = NavigationProvider();
    var notified = 0;
    nav.addListener(() => notified++);

    nav.setSearch('周');
    notified = 0;
    nav.enterSource('local:test');
    expect(notified, 1, reason: '进入源：清空搜索 + 路由变更应合为一次通知');
    expect(nav.search, '');

    nav.setSearch('夜曲');
    notified = 0;
    nav.exitSource();
    expect(notified, 1, reason: '退出源：清空搜索 + 路由变更应合为一次通知');
    expect(nav.search, '');
  });
}
