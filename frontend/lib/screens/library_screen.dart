import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/direct_source_manager.dart';
import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../services/artist_resolver.dart';
import '../theme/app_theme.dart';
import '../utils/collection_sort.dart';
import '../utils/perf_log.dart';
import '../utils/interaction_gate.dart';
import '../utils/motion.dart';
import '../utils/song_search.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/area_switcher.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/draggable_sheet.dart';
import '../widgets/row_list.dart';
import '../widgets/list_selection.dart';
import '../widgets/page_transition.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_list.dart';
import '../widgets/song_row_view.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/square_card.dart';
import '../widgets/view_mode_toggle.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';
import 'source_browse_view.dart';
import 'playlists_view.dart';

/// 内容区：根据导航 Section / 设置分区动态渲染对应页面（播放页为悬浮层，不在这里）。
class AppContent extends StatelessWidget {
  const AppContent({super.key});

  /// 冷启动首帧定位：只记第一次 build（后续路由切换不再刷屏）。
  static bool _bootLogged = false;

  @override
  Widget build(BuildContext context) {
    if (!_bootLogged) {
      _bootLogged = true;
      perfLog('boot.firstBuild AppContent');
    }
    // 订阅收窄（T008）：内容路由只订阅"路由键"（section + 设置分区 + 源内 key +
    // 歌单详情 id），一次 record select 覆盖全部路由依赖；搜索/队列/播放页等
    // 变更不再牵连内容路由重建。areaKey/areaLevel/slideOffset 由上述字段派生，
    // 在本次重建内即时读取即可。
    final nav = context.read<NavigationProvider>();
    final routeKey =
        context.select<NavigationProvider, NavRouteKey>((n) => n.routeKey);
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final page = _areaPage(routeKey);
    if (transition == PlayerTransition.none) return page;
    if (transition == PlayerTransition.slide) {
      // 分层切换：底层静止垫底，只有高层移动，不透黑底。
      return AreaSwitcher(
        areaKey: nav.areaKey,
        level: nav.areaLevel,
        slideOffset: nav.slideOffset,
        child: page,
      );
    }
    return AnimatedSwitcher(
      duration: kPageMotion,
      switchInCurve: kPageMotionCurve,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => pageTransition(
          transition, child, anim,
          backdrop: Theme.of(context).scaffoldBackgroundColor),
      child: KeyedSubtree(key: ValueKey(nav.areaKey), child: page),
    );
  }

  /// 当前区域页面（设置 / 源内浏览 / 歌单详情 / 六分组 pager）。
  Widget _areaPage(NavRouteKey routeKey) {
    if (routeKey.settings != null) {
      return const SettingsScreen();
    }
    // 播放源「文件夹」子级：源内浏览（原地切换）。
    if (routeKey.section == NavSection.sources && routeKey.sourceKey != null) {
      return SourceBrowseView(sourceKey: routeKey.sourceKey!);
    }
    // 歌单详情子视图。
    if (routeKey.section == NavSection.playlists &&
        routeKey.playlistId != null) {
      return PlaylistDetailView(playlistId: routeKey.playlistId!);
    }
    // 六个顶级分组：滑动模式跟手 PageView，其余模式松手触发区切换。
    return const SectionPager();
  }
}

/// 六个顶级分组的容器（歌单/喜欢/播放源/歌曲/专辑/歌手）。
///
/// - 滑动档：跟手 PageView（原生跟手 + 位置/速度吸附）；
///   程序驱动（顶栏点击/返回键）`animateToPage`，方向天然正确；
///   双向同步防抢：手指拖拽中不调 `animateToPage`（`_programmatic` +
///   `isScrolling` 双条件）。
/// - 淡入/缩放/关闭档：单页 + 按设置的过渡（横滑松手触发切换）。
class SectionPager extends StatefulWidget {
  const SectionPager({super.key});

  @override
  State<SectionPager> createState() => _SectionPagerState();
}

class _SectionPagerState extends State<SectionPager>
    with SingleTickerProviderStateMixin {
  late final PageController _ctrl;
  late int _applied;
  bool _programmatic = false;
  bool _slideActive = false;

  /// 非相邻分组的入场动画（不穿中间页）：整页从目标方向滑入。
  late final AnimationController _enterCtrl;
  late final CurvedAnimation _enterCurve;
  int _enterDir = 1;

  /// 首帧空闲后开启相邻页预构建（allowImplicitScrolling 给 PageView 一屏
  /// cacheExtent）：不在启动首帧多背两页，又让首次横滑不必现场建目标页。
  /// 页内是固定行高懒列表，预构建只建「可能显示的行」，不会整表构建。
  bool _warmNeighbors = false;

  /// 交互门控（横滑/入场动画期间聚合后台数据通知）。
  InteractionGate? _gate;

  static int _indexOf(NavSection s) => NavSection.values.indexOf(s);

  /// 六个分组页（顺序与 NavSection.values 一致）。
  static const _pages = [
    PlaylistsView(),
    _LikedView(),
    SourcesScreen(),
    _SongsView(),
    _AlbumsView(),
    _ArtistsView(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate = InteractionGate.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    final nav = context.read<NavigationProvider>();
    final initial = _indexOf(nav.section);
    _applied = initial;
    nav.pageOffset.value = initial.toDouble();
    _ctrl = PageController(initialPage: initial);
    _ctrl.addListener(_syncOffset);
    _enterCtrl = AnimationController(
        vsync: this, duration: kPageMotion, value: 1);
    _enterCurve =
        CurvedAnimation(parent: _enterCtrl, curve: kPageMotionCurve);
    // 跨页入场动画进行中 → 门控视为「过渡中」。
    _enterCtrl.addStatusListener((s) {
      final gate = _gate;
      if (gate == null) return;
      if (s == AnimationStatus.forward) {
        gate.setTransitioning(true);
      } else if (s == AnimationStatus.completed ||
          s == AnimationStatus.dismissed) {
        _refreshTransitionSignal();
      }
    });
    // 首帧空闲后再预构建左右邻页（内存/启动成本的折中，见字段注释）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _warmNeighbors = true);
    });
  }

  @override
  void dispose() {
    // 组件销毁时若仍在动画中，避免门控停留在「过渡中」。
    _gate?.setTransitioning(false);
    _ctrl.removeListener(_syncOffset);
    _ctrl.dispose();
    _enterCurve.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  /// 依据 PageView 拖拽/吸附与入场动画状态刷新门控的「过渡中」信号。
  void _refreshTransitionSignal() {
    final gate = _gate;
    if (gate == null) return;
    final scrolling =
        _ctrl.hasClients && _ctrl.position.isScrollingNotifier.value;
    gate.setTransitioning(scrolling || _enterCtrl.isAnimating);
  }

  /// 控制器页码（含拖拽小数）同步给顶栏，顶栏据此跟手高亮/滚动。
  void _syncOffset() {
    if (!_ctrl.hasClients) return;
    final nav = context.read<NavigationProvider>();
    nav.pageOffset.value = _ctrl.page ?? _applied.toDouble();
    _refreshTransitionSignal();
  }

  void _onPageChanged(int i) {
    _applied = i;
    _programmatic = false;
    context.read<NavigationProvider>().select(NavSection.values[i]);
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T009）：Pager 只关注目标 `section`；拖拽期跟手页码由 pageOffset
    // （ValueNotifier）独立驱动。
    final nav = context.read<NavigationProvider>();
    final section =
        context.select<NavigationProvider, NavSection>((n) => n.section);
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final target = _indexOf(section);

    // 非滑动档：单页按设置过渡（松手触发切换）；顶栏高亮随后同步。
    // 滑动档：跟手 PageView，顶栏由控制器监听逐帧同步。
    if (transition != PlayerTransition.slide) {
      _slideActive = false;
      _programmatic = false;
      _applied = target;
      if (nav.pageOffset.value != target.toDouble()) {
        final t = target.toDouble();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && nav.pageOffset.value != t) nav.pageOffset.value = t;
        });
      }
      final page = KeyedSubtree(key: ValueKey(target), child: _pages[target]);
      if (transition == PlayerTransition.none) {
        return SectionSwipe(child: page);
      }
      return SectionSwipe(
        child: AnimatedSwitcher(
          duration: kPageMotion,
          switchInCurve: kPageMotionCurve,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => pageTransition(
              transition, child, anim,
              backdrop: Theme.of(context).scaffoldBackgroundColor),
          child: page,
        ),
      );
    }

    // 从非滑动档切回：控制器可能停留在旧页，首帧对齐到当前分组。
    if (!_slideActive) {
      _slideActive = true;
      _applied = target;
      _programmatic = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl.hasClients && _ctrl.page?.round() != target) {
          _ctrl.jumpToPage(target);
        }
      });
    }

    if (target != _applied) {
      final scrolling =
          _ctrl.hasClients && _ctrl.position.isScrollingNotifier.value;
      // 手指拖拽中跳过，避免拽手指；程序飞行中可重定向。
      if (!scrolling || _programmatic) {
        // 上一段入场动画未跑完：先落定，再按新目标重排。
        _enterCtrl.stop();
        _enterCtrl.value = 1;
        final current =
            _ctrl.hasClients ? (_ctrl.page?.round() ?? _applied) : _applied;
        _programmatic = true;
        _applied = target;
        if (_ctrl.hasClients && (target - current).abs() > 1) {
          // 跨多页：跳页 + 方向滑入，不再高速扫过中间分组。
          // jumpToPage 同步通知会踩 build 期 markNeedsBuild，放到帧后执行。
          final dir = target > current ? 1 : -1;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _applied != target || !_ctrl.hasClients) return;
            _enterDir = dir;
            _enterCtrl.forward(from: 0);
            _ctrl.jumpToPage(target);
          });
        } else {
          _ctrl.animateToPage(target,
              duration: kPageMotion, curve: kPageMotionCurve);
        }
      }
    }

    return SlideTransition(
      position: _enterCurve.drive(Tween<Offset>(
          begin: Offset(_enterDir.toDouble(), 0), end: Offset.zero)),
      child: PageView(
        controller: _ctrl,
        onPageChanged: _onPageChanged,
        // 首次横滑前预构建左右邻页（只建可见范围的行），降低滑动首帧构建开销。
        allowImplicitScrolling: _warmNeighbors,
        // 每页独立图层：横滑期间页面平移只重合成、不重栅格化（降低滑动掉帧）。
        children: [for (final p in _pages) RepaintBoundary(child: p)],
      ),
    );
  }
}

/// 过滤/排序结果快照（raw = 未过滤全集，用于空态提示）。
class _SortedResult {
  const _SortedResult(this.raw, this.songs);
  final List<Song> raw;
  final List<Song> songs;
}

/// 喜欢（收藏）列表：统一来自 play_meta.is_favorite（直连 + 服务器）。
class _LikedView extends StatefulWidget {
  const _LikedView();

  @override
  State<_LikedView> createState() => _LikedViewState();
}

class _LikedViewState extends State<_LikedView>
    with AutomaticKeepAliveClientMixin {
  /// 滑动档横滑时保持存活：PageView 离开可视区即销毁 State，重新进入会重跑
  /// 全量收藏查询 + 重排（千首 × 多表查询全压在动画帧），KeepAlive 保留之。
  @override
  bool get wantKeepAlive => true;

  final Selection<String> _sel = Selection<String>();

  /// 行级视图数据缓存（R-1）：签名不变时复用整表。
  final SongRowCache _rowCache = SongRowCache();

  /// 收藏列表缓存：仅在（收藏版本, 设置版本）变化时查库（滑动/重绘不重复全量查询）。
  /// 设置版本同步忽略排除规则的生效：忽略音频改动后喜欢页即时过滤（改进.txt 功能6）。
  int _favVersion = -1;
  int _favSettingsVer = -1;
  List<Song> _favAll = const [];

  /// 排序/过滤结果按 (收藏版本, 设置版本, 搜索词, 排序偏好) 缓存：build 因 AnyChange 重跑时
  /// 不重排（权重排序每首一次 SQL，几千首重排一次 = 上万条同步查询）。
  (int, int, String, CollectionSort)? _sortedKey;
  _SortedResult _sorted = const _SortedResult([], []);

  List<Song> _favoritesOf(DirectSourceManager direct) {
    if (direct.favoriteVersion != _favVersion ||
        direct.settingsVersion != _favSettingsVer) {
      _favVersion = direct.favoriteVersion;
      _favSettingsVer = direct.settingsVersion;
      _favAll = direct.favoriteSongs();
    }
    return _favAll;
  }

  /// 过滤 + 排序，命中缓存直接复用（喜欢页数据不变时 build 重跑 0 次排序/查询）。
  _SortedResult _sortSongs(DirectSourceManager direct, String search) {
    final pref = direct.settings.sortFavorites;
    final key = (_favVersion, _favSettingsVer, search, pref);
    if (_sortedKey == key) return _sorted;
    final all = _favoritesOf(direct);
    final filtered = filterSongs(all, search);
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = direct.weight.sortKeysOf(filtered,
        factors: pref.isWeight, playSecs: pref.isPlayStat);
    final songs = sortSongs(filtered, pref,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _sortedKey = key;
    _sorted = _SortedResult(_favAll, songs);
    return _sorted;
  }

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  void _playSelected(List<Song> songs) {
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    context
        .read<PlayerProvider>()
        .playQueue(selected, contextKey: PlayerProvider.anchorForLiked());
    context.read<NavigationProvider>().openPlayer();
  }

  void _unlikeSelected(List<Song> songs) {
    final direct = context.read<DirectSourceManager>();
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    final player = context.read<PlayerProvider>();
    for (final s in selected) {
      direct.setFavorite(s, false);
      unawaited(player.onAnchorSongRemoved(PlayerProvider.anchorForLiked(), s));
    }
    AppToast.show('已取消喜欢 ${selected.length} 首', isError: false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：喜欢页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final res = _sortSongs(direct, search);
    final all = res.raw;
    final songs = res.songs;

    // 行级视图数据（R-1）：懒算派生文本/收藏态并缓存，行组件纯参数渲染。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    _rowCache.begin(
      (
        identityHashCode(songs),
        _favVersion,
        _favSettingsVer,
        direct.metaVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
      ),
      songs.length,
      onWarm: () => direct.weight.warmMetaOf(songs),
    );

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 多选栏与计数栏共用同一位置（多选时覆盖「共 xx」，退出恢复）。
            if (_sel.active)
              SelectionBar(
                total: songs.length,
                selectedCount: _sel.of(songs.map(songKey)).length,
                onToggleAll: () =>
                    setState(() => _sel.setAll(songs.map(songKey))),
                onCancel: () => setState(_sel.cancel),
                actions: [
                  SelectionAction(
                    icon: Icons.play_arrow,
                    label: '播放选中',
                    onPressed: _sel.isEmpty ? null : () => _playSelected(songs),
                  ),
                  SelectionAction(
                    icon: Icons.favorite_border,
                    label: '取消喜欢',
                    onPressed:
                        _sel.isEmpty ? null : () => _unlikeSelected(songs),
                  ),
                ],
              )
            else
              CountHeader(
                count: songs.length,
                trailing: SortMenuButton(
                  value: direct.settings.sortFavorites,
                  onChanged: (v) =>
                      setState(() => direct.settings.sortFavorites = v),
                ),
              ),
            if (_sel.active) const Divider(height: 1),
            Expanded(
              child: songs.isEmpty
                  ? Center(
                      child: Text(all.isEmpty ? '暂无喜欢的歌曲，去歌曲页点 ♡ 收藏' : '无匹配歌曲'))
                  : RowList(
                      count: songs.length,
                      itemBuilder: (c, i) {
                        final s = songs[i];
                        return SongTile(
                          song: s,
                          source: lib.sourceFor(s.sourceKey),
                          row: _rowCache.rowAt(i, () {
                            final meta = direct.weight.metaOf(s);
                            return SongRowView.of(
                              song: s,
                              titleFormat: direct.settings.songTitleFormat,
                              favorite: meta.favorite,
                              disliked: meta.frozen,
                              wide: wide,
                            );
                          }),
                          onPlay: () {
                            player.playQueue(songs,
                                index: i,
                                contextKey: PlayerProvider.anchorForLiked());
                            context.read<NavigationProvider>().openPlayer();
                          },
                          playing: player.isCurrent(s),
                          selectionMode: _sel.active,
                          selected: _sel.contains(songKey(s)),
                          onSelect: () => _toggle(songKey(s)),
                          onStartSelect: () =>
                              setState(() => _sel.startWith(songKey(s))),
                        );
                      },
                    ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: CornerAddButton(
            tooltip: '去歌曲页收藏',
            onPressed: () =>
                context.read<NavigationProvider>().select(NavSection.songs),
          ),
        ),
      ],
    );
  }
}

class _SongsView extends StatefulWidget {
  const _SongsView();

  @override
  State<_SongsView> createState() => _SongsViewState();
}

class _SongsViewState extends State<_SongsView>
    with AutomaticKeepAliveClientMixin {
  /// 滑动档横滑时保持存活：离开可视区即销毁 State，重新进入会重跑全库查询
  /// （allSongs 全表扫描）与万吨排序，KeepAlive 保留使来回滑动 0 查询。
  @override
  bool get wantKeepAlive => true;

  final Selection<String> _sel = Selection<String>();

  /// 行级视图数据缓存（R-1）。
  final SongRowCache _rowCache = SongRowCache();

  /// 排序/过滤结果缓存（同喜欢页）：
  /// 键 = (歌曲全集身份, 搜索词, 排序偏好)。build 重跑不重排不重查。
  List<Song>? _lastBase;
  (int, String, CollectionSort)? _sortedKey;
  _SortedResult _sorted = const _SortedResult([], []);

  _SortedResult _sortSongs(
      LibraryProvider lib, DirectSourceManager direct, String search) {
    final base = lib.songs;
    final pref = direct.settings.sortSongs;
    final key = (base.length, search, pref);
    if (_sortedKey == key && identical(base, _lastBase)) return _sorted;
    final filtered = filterSongs(base, search);
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = direct.weight.sortKeysOf(filtered,
        factors: pref.isWeight, playSecs: pref.isPlayStat);
    final songs = sortSongs(filtered, pref,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _sortedKey = key;
    _lastBase = base;
    return _sorted = _SortedResult(base, songs);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.songs.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
  }

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  void _playSelected(List<Song> songs) {
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    context
        .read<PlayerProvider>()
        .playQueue(selected, contextKey: PlayerProvider.anchorForSongs());
    context.read<NavigationProvider>().openPlayer();
  }

  void _addToPlaylistSelected(List<Song> songs) {
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    showAddToPlaylistSheetForSongs(context, selected);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final player = context.read<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();

    // 订阅收窄（T011）：歌曲页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);

    // 依据全局搜索词过滤（喜欢页共用同一匹配函数），再按本页排序偏好排序。
    final songs = _sortSongs(lib, direct, search).songs;

    // 行级视图数据（R-1）：懒算派生文本/收藏态并缓存，行组件纯参数渲染。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    _rowCache.begin(
      (
        identityHashCode(songs),
        lib.songs.length,
        direct.metaVersion,
        direct.favoriteVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
      ),
      songs.length,
      onWarm: () => direct.weight.warmMetaOf(songs),
    );

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child:
                  Text(lib.error!, style: const TextStyle(color: Colors.red))),
        // 多选栏与计数栏共用同一位置（多选时覆盖「共 xx」，退出恢复）。
        if (_sel.active)
          SelectionBar(
            total: songs.length,
            selectedCount: _sel.of(songs.map(songKey)).length,
            onToggleAll: () => setState(() => _sel.setAll(songs.map(songKey))),
            onCancel: () => setState(_sel.cancel),
            actions: [
              SelectionAction(
                icon: Icons.play_arrow,
                label: '播放选中',
                onPressed: _sel.isEmpty ? null : () => _playSelected(songs),
              ),
              SelectionAction(
                icon: Icons.playlist_add,
                label: '加入歌单',
                onPressed:
                    _sel.isEmpty ? null : () => _addToPlaylistSelected(songs),
              ),
            ],
          )
        else
          CountHeader(
            count: songs.length,
            trailing: SortMenuButton(
              value: direct.settings.sortSongs,
              onChanged: (v) => setState(() => direct.settings.sortSongs = v),
            ),
          ),
        Expanded(
          child: songs.isEmpty
              ? _EmptyHint(onRefresh: lib.loadSongs)
              : RowList(
                  count: songs.length,
                  onRefresh: lib.loadSongs,
                  itemBuilder: (c, i) {
                    final s = songs[i];
                    return SongTile(
                      song: s,
                      source: lib.sourceFor(s.sourceKey),
                      row: _rowCache.rowAt(
                        i,
                        () {
                          final meta = direct.weight.metaOf(s);
                          return SongRowView.of(
                            song: s,
                            titleFormat: direct.settings.songTitleFormat,
                            favorite: meta.favorite,
                            disliked: meta.frozen,
                            wide: wide,
                          );
                        },
                      ),
                      onPlay: () {
                        player.playQueue(songs,
                            index: i,
                            contextKey: PlayerProvider.anchorForSongs());
                        context.read<NavigationProvider>().openPlayer();
                      },
                      playing: player.isCurrent(s),
                      selectionMode: _sel.active,
                      selected: _sel.contains(songKey(s)),
                      onSelect: () => _toggle(songKey(s)),
                      onStartSelect: () {
                        setState(() => _sel.startWith(songKey(s)));
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AlbumsView extends StatefulWidget {
  const _AlbumsView();

  @override
  State<_AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<_AlbumsView>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活：离开可视区即销毁 State，重新进入会重跑全量专辑查询
  /// 与重排，KeepAlive 保留使来回滑动 0 查询。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.albums;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  /// 排序/过滤结果缓存：键 = (专辑全集大小, 搜索词, 排序偏好)，build 重跑不重排。
  List<Album>? _lastBase;
  (int, String, CollectionSort)? _sortedKey;
  List<Album> _sorted = const [];

  List<Album> _filteredSorted(
      List<Album> albums, String search, CollectionSort pref) {
    final key = (albums.length, search, pref);
    if (_sortedKey == key && identical(albums, _lastBase)) return _sorted;
    _lastBase = albums;
    _sortedKey = key;
    return _sorted = sortByCollection(
        _filter(albums, search), pref, (a) => a.album,
        countOf: (a) => a.trackCount);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.albums.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：专辑页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final albums =
        _filteredSorted(lib.albums, search, direct.settings.sortAlbums);
    final card = isCard;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child:
                  Text(lib.error!, style: const TextStyle(color: Colors.red))),
        CountHeader(
          count: albums.length,
          unit: '张',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SortMenuButton(
                value: direct.settings.sortAlbums,
                scope: SortScope.collections,
                onChanged: (v) =>
                    setState(() => direct.settings.sortAlbums = v),
              ),
              viewModeToggle(),
            ],
          ),
        ),
        Expanded(
          child: albums.isEmpty
              ? _EmptyHint(onRefresh: lib.loadAlbums)
              : card
                  ? RefreshIndicator(
                      onRefresh: lib.loadAlbums,
                      child: SquareCardGrid(
                        itemCount: albums.length,
                        itemBuilder: (c, i) => _AlbumCard(album: albums[i]),
                      ),
                    )
                  : RowList(
                      count: albums.length,
                      onRefresh: lib.loadAlbums,
                      itemBuilder: (c, i) => _AlbumListTile(album: albums[i]),
                    ),
        ),
      ],
    );
  }

  List<Album> _filter(List<Album> albums, String q) {
    if (q.trim().isEmpty) return albums;
    final qq = q.trim().toLowerCase();
    return albums
        .where((a) =>
            a.album.toLowerCase().contains(qq) ||
            a.artists.any((e) => e.toLowerCase().contains(qq)))
        .toList();
  }
}

/// 专辑副标题 spans：主歌手正常色、其余合作者淡化，末尾跟曲目数。
/// 列表行与方形卡片共用，保证两处展示一致。
InlineSpan albumSubtitleSpan(BuildContext context, Album album) {
  final scheme = Theme.of(context).colorScheme;
  final main = scheme.onSurface.withValues(alpha: 0.6);
  final faint = scheme.onSurface.withValues(alpha: 0.38);
  final parts = album.artists.isEmpty ? [album.artist] : album.artists;
  final spans = <InlineSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      spans.add(TextSpan(text: '、', style: TextStyle(color: faint)));
    }
    spans.add(TextSpan(
        text: parts[i], style: TextStyle(color: i == 0 ? main : faint)));
  }
  spans.add(TextSpan(text: ' · ${album.trackCount}首', style: TextStyle(color: main)));
  return TextSpan(children: spans);
}

/// 打开专辑歌曲弹层（卡片/列表两种形态共用）。
Future<void> _openAlbum(BuildContext context, Album album) async {
  final lib = context.read<LibraryProvider>();
  final songs = lib.albumSongs(album);
  if (!context.mounted) return;
  showAppDraggableSheet<void>(
    context,
    builder: (c, scrollCtrl) =>
        _AlbumSongsSheet(album: album, songs: songs, scrollCtrl: scrollCtrl),
  );
}

class _AlbumListTile extends StatelessWidget {
  final Album album;
  const _AlbumListTile({required this.album});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading:
          CoverThumb(coverPath: album.coverPath, fallbackIcon: Icons.album),
      title: Text(album.album,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
              style: DefaultTextStyle.of(context).style,
              children: [albumSubtitleSpan(context, album)])),
      onTap: () => _openAlbum(context, album),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final parts =
        album.artists.isEmpty ? [album.artist] : album.artists;
    return SquareCard(
      title: album.album,
      subtitle: '${parts.join('、')} · ${album.trackCount}首',
      subtitleSpan: albumSubtitleSpan(context, album),
      coverPath: album.coverPath,
      fallbackIcon: Icons.album,
      onTap: () => _openAlbum(context, album),
    );
  }
}

class _AlbumSongsSheet extends StatelessWidget {
  final Album album;
  final List<Song> songs;

  /// 统一拖拽式窗口下发的共享滚动轴（头部与列表共轴，见 [showAppDraggableSheet]）。
  final ScrollController scrollCtrl;
  const _AlbumSongsSheet(
      {required this.album, required this.songs, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    return CustomScrollView(
      controller: scrollCtrl,
      slivers: [
        // 置顶标题行：滚动歌曲时专辑名/歌曲数常驻顶部（与队列/歌手弹层同构）。
        AppSheetHeader(
          height: AppSheetTitleBar.heightOf(context),
          child: AppSheetTitleBar(title: album.album, count: songs.length),
        ),
        SliverRowList(
          count: songs.length,
          itemBuilder: (c, i) {
            final s = songs[i];
            return SongTile(
              song: s,
              source: lib.sourceFor(s.sourceKey),
              playing: player.isCurrent(s),
              onPlay: () {
                Navigator.of(c).pop();
                player.playQueue(songs,
                    index: i,
                    contextKey: PlayerProvider.anchorForAlbum(album.id));
                context.read<NavigationProvider>().openPlayer();
              },
            );
          },
        ),
      ],
    );
  }
}

class _ArtistsView extends StatefulWidget {
  const _ArtistsView();

  @override
  State<_ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<_ArtistsView>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活（同专辑页）。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.artists;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  /// 排序/过滤结果缓存：键 = (歌手全集大小, 搜索词, 排序偏好)，build 重跑不重排。
  List<Artist>? _lastBase;
  (int, String, CollectionSort)? _sortedKey;
  List<Artist> _sorted = const [];

  List<Artist> _filteredSorted(
      List<Artist> artists, String search, CollectionSort pref) {
    final key = (artists.length, search, pref);
    if (_sortedKey == key && identical(artists, _lastBase)) return _sorted;
    _lastBase = artists;
    _sortedKey = key;
    return _sorted = sortByCollection(
        _filter(artists, search), pref, (a) => a.name,
        countOf: (a) => a.songCount);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.artists.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
    // 身份解析完成后的刷新挂在 LibraryProvider（解析结果落库即重算，不重扫歌曲；
    // 不在歌手页时也能保持新鲜），这里不再重复监听。
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：歌手页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final artists =
        _filteredSorted(lib.artists, search, direct.settings.sortArtists);
    final card = isCard;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child:
                  Text(lib.error!, style: const TextStyle(color: Colors.red))),
        CountHeader(
          count: artists.length,
          unit: '位',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SortMenuButton(
                value: direct.settings.sortArtists,
                scope: SortScope.collections,
                onChanged: (v) =>
                    setState(() => direct.settings.sortArtists = v),
              ),
              viewModeToggle(),
            ],
          ),
        ),
        Expanded(
          child: artists.isEmpty
              ? _EmptyHint(onRefresh: lib.loadArtists)
              : card
                  ? RefreshIndicator(
                      onRefresh: lib.loadArtists,
                      child: SquareCardGrid(
                        itemCount: artists.length,
                        itemBuilder: (c, i) => _ArtistCard(artist: artists[i]),
                      ),
                    )
                  : RowList(
                      count: artists.length,
                      onRefresh: lib.loadArtists,
                      itemBuilder: (c, i) =>
                          _ArtistListTile(artist: artists[i]),
                    ),
        ),
      ],
    );
  }

  List<Artist> _filter(List<Artist> artists, String q) {
    if (q.trim().isEmpty) return artists;
    final qq = q.trim().toLowerCase();
    return artists.where((a) => a.name.toLowerCase().contains(qq)).toList();
  }
}

/// 打开歌手（卡片/列表两种形态共用，唯一分流入口）。
///
/// 按 [Artist.resolveState] 分流，未解析成功的歌手一律不进歌曲列表：
/// - confirm（同名多真人需人工确认）→ 弹候选选择页；
/// - retry（待解析/未命中）→ 弹「重试解析」确认窗；
/// - normal（已解析/非 identity 模式）→ 打开歌曲弹层。
void _openArtist(BuildContext context, Artist artist, ArtistResolver resolver) {
  switch (artist.resolveState) {
    case ArtistResolveState.confirm:
      _showAmbiguousPicker(context, artist, resolver);
      return;
    case ArtistResolveState.retry:
      _showRetryConfirm(context, artist, resolver);
      return;
    case ArtistResolveState.normal:
      break;
  }
  final lib = context.read<LibraryProvider>();
  final songs = lib.artistSongs(artist);
  if (!context.mounted) return;
  showAppDraggableSheet<void>(
    context,
    // 弹层可上拉到全高：顶部安全区由统一窗口的路由外层 SafeArea 消费
    // （否则盖住时间/电量，见 artist_sheet_gesture_test 回归）。
    builder: (c, scrollCtrl) =>
        _ArtistSongsSheet(artist: artist, songs: songs, scrollCtrl: scrollCtrl),
  );
}

/// 歧义身份候选选择（候选来自 MB 搜索 hit，零额外请求）。
Future<void> _showAmbiguousPicker(
    BuildContext context, Artist artist, ArtistResolver resolver) async {
  final canonicalKey = artist.canonicalKey;
  if (canonicalKey == null) return;
  final candidates = await resolver.candidatesFor(canonicalKey);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (c2, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('选择「${artist.name}」对应的真人',
                style: Theme.of(c)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('本地多个不同写法的歌手指向同名的可能身份，请选择其一；'
                '未列出的可稍后重试。'),
          ),
          const Divider(height: 1),
          Expanded(
            child: candidates.isEmpty
                ? _AmbiguousEmptyState(
                    resolver: resolver,
                    canonicalKey: canonicalKey,
                  )
                : RowList(
                    controller: scrollCtrl,
                    count: candidates.length,
                    itemBuilder: (c3, i) {
                      final h = candidates[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(h.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (h.sortName != null && h.sortName != h.name)
                              h.sortName,
                            if (h.type != null) h.type,
                            if (h.disambiguation != null) h.disambiguation,
                            if (h.beginYear != null)
                              '${h.beginYear}—${h.endYear ?? '…'}',
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          await resolver.bindManual(canonicalKey, h);
                          if (c3.mounted) Navigator.of(c3).pop();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

/// 候选为空（重试后仍无可选）时的空态：
/// 网络不可用与“确实无候选”分开提示，并给出「重试解析」立即再试。
class _AmbiguousEmptyState extends StatelessWidget {
  final ArtistResolver resolver;
  final String canonicalKey;
  const _AmbiguousEmptyState({
    required this.resolver,
    required this.canonicalKey,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final offline = resolver.networkDown;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(offline ? Icons.wifi_off : Icons.search_off,
              size: 40, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(offline ? '网络不可用，可稍后再试' : '暂无可选候选，稍后自动重试',
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试解析'),
            onPressed: () async {
              await resolver.retryOne(canonicalKey);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

/// 未命中/待解析歌手：手动立即重试确认。
Future<void> _showRetryConfirm(
    BuildContext context, Artist artist, ArtistResolver resolver) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('重试解析「${artist.name}」？'),
      content: Text(artist.status == 'local'
          ? '上次解析未找到可靠身份（MusicBrainz 可能未收录），确认后立即重试。'
          : '该歌手尚未解析，确认后立即尝试。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('重试')),
        TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消')),
      ],
    ),
  );
  if (ok == true) {
    final canonicalKey = artist.canonicalKey;
    if (canonicalKey != null) await resolver.retryOne(canonicalKey);
  }
}

class _ArtistListTile extends StatelessWidget {
  final Artist artist;
  const _ArtistListTile({required this.artist});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // 歌手用圆形头像（其余集合行统一圆角方形）。
      leading: CoverThumb(
        coverPath: artist.coverPath,
        fallbackIcon: Icons.person,
        shape: CoverShape.circle,
      ),
      title: Text(artist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${artist.songCount}首 · ${artist.albumCount}张专辑',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (artist.resolveState == ArtistResolveState.confirm)
            ..._statusChip(context),
        ],
      ),
      trailing: switch (artist.resolveState) {
        ArtistResolveState.retry => IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: '重试解析',
            onPressed: () =>
                _openArtist(context, artist, context.read<ArtistResolver>()),
          ),
        ArtistResolveState.confirm =>
          const Icon(Icons.help_outline, size: 20, color: Colors.orange),
        ArtistResolveState.normal => null,
      },
      onTap: () => _openArtist(context, artist, context.read<ArtistResolver>()),
    );
  }
}

/// 身份状态小徽标（歧义/未匹配在地图右侧展示）。
List<Widget> _statusChip(BuildContext context) => [
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('需确认',
            style: TextStyle(fontSize: 11, color: Colors.orange)),
      ),
    ];

class _ArtistCard extends StatelessWidget {
  final Artist artist;
  const _ArtistCard({required this.artist});

  @override
  Widget build(BuildContext context) => SquareCard(
        title: artist.name,
        subtitle: artist.resolveState == ArtistResolveState.confirm
            ? '${artist.songCount}首 · ${artist.albumCount}张专辑 · 需确认'
            : '${artist.songCount}首 · ${artist.albumCount}张专辑',
        coverPath: artist.coverPath,
        fallbackIcon: Icons.person,
        // 未解析成功的歌手：封面右上角叠状态角标（重试/需确认），
        // 点击角标与整卡一致走 _openArtist（只弹解析交互，不进歌曲）。
        cornerAction: switch (artist.resolveState) {
          ArtistResolveState.normal => null,
          ArtistResolveState.confirm =>
            const _StatusBadge(icon: Icons.help_outline, color: Colors.orange),
          ArtistResolveState.retry =>
            const _StatusBadge(icon: Icons.refresh, color: Colors.white),
        },
        onTap: () =>
            _openArtist(context, artist, context.read<ArtistResolver>()),
      );
}

/// 卡片封面的圆形状态角标（深色底衬保证在各种封面上可见）。
class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _StatusBadge({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      );
}

class _ArtistSongsSheet extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;

  /// 统一拖拽式窗口下发的共享滚动轴（头部与列表共轴，见 [showAppDraggableSheet]）。
  final ScrollController scrollCtrl;
  const _ArtistSongsSheet(
      {required this.artist, required this.songs, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    // 详情只在人物身份下有内容（组合/角色的关系挂在成员树上，不在这里展开）。
    // 只查一次：artistDetail 会跑展示曲目数统计，别在 build 里查两遍。
    final detail = lib.artistDetail(artist);
    // 本歌手的专辑：与列表行「N 张专辑」同一分组口径（Album.fromSongs），
    // 所以这里的专辑个数应与 artist.albumCount 一致。
    final albums = Album.fromSongs(songs);
    return Stack(
      children: [
        // 头部与歌曲列表共用同一个 Scrollable / sheet controller：任意位置按下
        // 都能拖动/滚动弹层，「详情」展开只是滚动内容变长、不挤压列表。
        // 标题行经 [AppSheetHeader] 置顶：滚动时歌手名/歌曲数常驻顶部；专辑横滑条
        // 与详情属滚动内容（不钉，避免占满窗口）。
        CustomScrollView(
          controller: scrollCtrl,
          slivers: [
            AppSheetHeader(
              height: AppSheetTitleBar.heightOf(context),
              child: AppSheetTitleBar(title: artist.name, count: songs.length),
            ),
            if (albums.isNotEmpty || detail != null)
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (albums.isNotEmpty)
                      _ArtistAlbumsStrip(albums: albums, artistSongs: songs),
                    if (detail != null) _ArtistDetailBlock(detail: detail),
                  ],
                ),
              ),
            SliverRowList(
              count: songs.length,
              itemBuilder: (c, i) {
                final s = songs[i];
                return SongTile(
                  song: s,
                  source: lib.sourceFor(s.sourceKey),
                  playing: player.isCurrent(s),
                  onPlay: () {
                    Navigator.of(c).pop();
                    player.playQueue(songs,
                        index: i,
                        contextKey:
                            PlayerProvider.anchorForArtist(artist.name));
                    context.read<NavigationProvider>().openPlayer();
                  },
                );
              },
            ),
          ],
        ),
        // 「重新解析」放歌手详情页右下角：只重拉这一位（含成员展开），
        // 已有 mbid 的按该实体重取，不会漂到别的真人。
        Positioned(
          right: 16,
          bottom: 16,
          child: CornerAddButton(
            icon: Icons.sync_alt,
            label: '重新解析',
            tooltip: '重新解析 ${artist.name}',
            onPressed: () => _forceReParse(context, artist),
          ),
        ),
      ],
    );
  }

  /// 把这一位歌手打回 pending 并直跑一轮（含已解析成功的），受 MB 1 req/s 限流。
  Future<void> _forceReParse(BuildContext context, Artist artist) async {
    final resolver = context.read<ArtistResolver>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('重新解析「${artist.name}」？'),
        content: const Text('会把这一位歌手（含已解析成功的）按 MusicBrainz 重新拉取一遍，组合成员也会重新展开。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;
    // 弹页里的歌曲/详情是打开那一刻的快照，解析完身份可能变（合流、改判真人），
    // 留着旧数据容易误读：先关掉，歌手页会就地刷新。
    if (context.mounted) Navigator.of(context).pop();
    await resolver.forceRetryOne(
        artistKey: artist.identityKey, canonicalKey: artist.canonicalKey);
    AppToast.show('已开始重新解析 ${artist.name}', isError: false);
  }
}

/// 歌手弹页的「专辑」区：把该歌手的歌曲按全局专辑分组键（专辑歌手? 否则曲目
/// 歌手 + 专辑名）聚合，与列表行「N 张专辑」同一口径。点专辑打开其歌曲弹层
/// （只含该歌手的曲目，合辑不会带进同专辑的其他歌手）。
class _ArtistAlbumsStrip extends StatelessWidget {
  final List<Album> albums;
  final List<Song> artistSongs;
  const _ArtistAlbumsStrip({required this.albums, required this.artistSongs});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('专辑 (${albums.length})',
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (c, i) {
              final album = albums[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openAlbumOfArtist(context, album),
                child: SizedBox(
                  width: 72,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CoverThumb(
                          coverPath: album.coverPath,
                          fallbackIcon: Icons.album),
                      const SizedBox(height: 4),
                      Text(album.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                      Text('${album.trackCount}首',
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).disabledColor)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openAlbumOfArtist(BuildContext context, Album album) {
    final songs = artistSongs.where((s) => album.containsSong(s)).toList();
    showAppDraggableSheet<void>(
      context,
      builder: (c, scrollCtrl) =>
          _AlbumSongsSheet(album: album, songs: songs, scrollCtrl: scrollCtrl),
    );
  }
}

/// 歌手弹页里的「详情」区：只在人物身份下有内容，默认收起，展开后是
/// 组合 / 角色 / 成员三栏。带本地身份键的行可以点进去。
class _ArtistDetailBlock extends StatefulWidget {
  final ArtistDetail detail;
  const _ArtistDetailBlock({required this.detail});

  @override
  State<_ArtistDetailBlock> createState() => _ArtistDetailBlockState();
}

class _ArtistDetailBlockState extends State<_ArtistDetailBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.detail;
    if (d.isEmpty) return const SizedBox.shrink();
    final n = d.bands.length + d.roles.length + d.members.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                const Text('详情', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('($n)',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary)),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _refSection(context, '组合', d.bands, Icons.groups) ??
                    const SizedBox.shrink(),
                _refSection(context, '角色', d.roles, Icons.theater_comedy) ??
                    const SizedBox.shrink(),
                _refSection(context, '成员', d.members, Icons.person) ??
                    const SizedBox.shrink(),
              ],
            ),
          ),
      ],
    );
  }

  Widget? _refSection(
      BuildContext context, String title, List<ArtistRef> refs, IconData icon) {
    if (refs.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          for (final r in refs) _refRow(context, r, icon),
        ],
      ),
    );
  }

  Widget _refRow(BuildContext context, ArtistRef r, IconData icon) {
    final sub = _subtitle(r);
    return InkWell(
      // 本地没这条身份的行只能看，不能点进去。
      onTap: r.artistKey == null ? null : () => _openArtistByKey(context, r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).disabledColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                  if (sub != null)
                    Text(sub,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).disabledColor)),
                ],
              ),
            ),
            if (r.artistKey != null) const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  /// 第二行：作品名/副标题 + 曲目数。本地没身份就没有曲目数。
  String? _subtitle(ArtistRef r) {
    final parts = <String>[];
    if (r.disambiguation != null) parts.add(r.disambiguation!);
    if (r.songCount != null) {
      parts.add('${r.songCount} 首');
    } else {
      parts.add('未建档');
    }
    return parts.join(' · ');
  }

  void _openArtistByKey(BuildContext context, ArtistRef ref) {
    final key = ref.artistKey!;
    // 详情里的关联身份未必在歌手页当前列表里（没歌、没被筛进来），所以带
    // 显示名/曲目数兜一个临时条目，弹页标题和列表才对得上。
    _openArtist(
        context,
        Artist(
          name: ref.name,
          songCount: ref.songCount ?? 0,
          albumCount: 0,
          identityKey: key,
          canonicalKey: key,
          status: 'resolved',
        ),
        context.read<ArtistResolver>());
  }
}

class _EmptyHint extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyHint({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off,
              size: 72,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('暂无内容'),
          const SizedBox(height: 8),
          TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('刷新/扫描'),
              onPressed: onRefresh),
        ],
      ),
    );
  }
}
