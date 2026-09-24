import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/direct_source_manager.dart';
import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../theme/app_theme.dart';
import '../utils/collection_sort.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/area_switcher.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/list_selection.dart';
import '../widgets/page_transition.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_tile.dart';
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

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final page = _areaPage(nav);
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
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => pageTransition(transition, child, anim,
          backdrop: Theme.of(context).scaffoldBackgroundColor),
      child: KeyedSubtree(key: ValueKey(nav.areaKey), child: page),
    );
  }

  /// 当前区域页面（设置 / 源内浏览 / 歌单详情 / 六分组 pager）。
  Widget _areaPage(NavigationProvider nav) {
    if (nav.inSettings) {
      return const SettingsScreen();
    }
    // 播放源「文件夹」子级：源内浏览（原地切换）。
    if (nav.section == NavSection.sources && nav.browsingSourceKey != null) {
      return SourceBrowseView(sourceKey: nav.browsingSourceKey!);
    }
    // 歌单详情子视图。
    if (nav.section == NavSection.playlists && nav.browsingPlaylistId != null) {
      return PlaylistDetailView(playlistId: nav.browsingPlaylistId!);
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

class _SectionPagerState extends State<SectionPager> {
  late final PageController _ctrl;
  late int _applied;
  bool _programmatic = false;
  bool _slideActive = false;

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
  void initState() {
    super.initState();
    final nav = context.read<NavigationProvider>();
    final initial = _indexOf(nav.section);
    _applied = initial;
    nav.pageOffset.value = initial.toDouble();
    _ctrl = PageController(initialPage: initial);
    _ctrl.addListener(_syncOffset);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_syncOffset);
    _ctrl.dispose();
    super.dispose();
  }

  /// 控制器页码（含拖拽小数）同步给顶栏，顶栏据此跟手高亮/滚动。
  void _syncOffset() {
    if (!_ctrl.hasClients) return;
    final nav = context.read<NavigationProvider>();
    nav.pageOffset.value = _ctrl.page ?? _applied.toDouble();
  }

  void _onPageChanged(int i) {
    _applied = i;
    _programmatic = false;
    context.read<NavigationProvider>().select(NavSection.values[i]);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final target = _indexOf(nav.section);

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
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) =>
              pageTransition(transition, child, anim,
                  backdrop:
                      Theme.of(context).scaffoldBackgroundColor),
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
        _programmatic = true;
        _applied = target;
        _ctrl.animateToPage(target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic);
      }
    }

    return PageView(
      controller: _ctrl,
      onPageChanged: _onPageChanged,
      children: _pages,
    );
  }
}

/// 歌曲搜索过滤（标题/歌手，忽略大小写；空白词返回原列表）。
/// 歌曲页与喜欢页共用，保证两处匹配语义一致。
List<Song> filterSongs(List<Song> songs, String q) {
  if (q.trim().isEmpty) return songs;
  final qq = q.trim().toLowerCase();
  return songs
      .where((s) =>
          (s.title.toLowerCase().contains(qq)) ||
          (s.artist?.toLowerCase().contains(qq) ?? false))
      .toList();
}

/// 喜欢（收藏）列表：统一来自 play_meta.is_favorite（直连 + 服务器）。
class _LikedView extends StatefulWidget {
  const _LikedView();

  @override
  State<_LikedView> createState() => _LikedViewState();
}

class _LikedViewState extends State<_LikedView> {
  final Selection<String> _sel = Selection<String>();

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  void _playSelected(List<Song> songs) {
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    context.read<PlayerProvider>().playQueue(selected);
    context.read<NavigationProvider>().openPlayer();
  }

  void _unlikeSelected(List<Song> songs) {
    final direct = context.read<DirectSourceManager>();
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    for (final s in selected) {
      direct.setFavorite(s, false);
    }
    AppToast.show('已取消喜欢 ${selected.length} 首', isError: false);
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final nav = context.watch<NavigationProvider>();
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final all = direct.favoriteSongs();
    final songs = sortSongs(filterSongs(all, nav.search),
        direct.settings.sortFavorites,
        factorOf: direct.weight.factorOf);

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              CountHeader(
                count: songs.length,
                trailing: SortMenuButton(
                  value: direct.settings.sortFavorites,
                  withWeight: true,
                  onChanged: (v) =>
                      setState(() => direct.settings.sortFavorites = v),
                ),
              ),
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
                      onPressed: _sel.isEmpty ? null : () => _unlikeSelected(songs),
                    ),
                  ],
                ),
              if (_sel.active) const Divider(height: 1),
              Expanded(
                child: songs.isEmpty
                    ? Center(
                        child: Text(all.isEmpty
                            ? '暂无喜欢的歌曲，去歌曲页点 ♡ 收藏'
                            : '无匹配歌曲'))
                    : ListView.separated(
                        itemCount: songs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                        itemBuilder: (c, i) {
                          final s = songs[i];
                          return SongTile(
                            song: s,
                            source: lib.sourceFor(s.sourceKey),
                            onPlay: () {
                              player.playQueue(songs, index: i);
                              context.read<NavigationProvider>().openPlayer();
                            },
                            selectionMode: _sel.active,
                            selected: _sel.contains(songKey(s)),
                            onSelect: () => _toggle(songKey(s)),
                            onStartSelect:
                                () => setState(() => _sel.startWith(songKey(s))),
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

class _SongsViewState extends State<_SongsView> {
  final Selection<String> _sel = Selection<String>();

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.songs.isEmpty && !lib.loading) {
        final nav = context.read<NavigationProvider>();
        lib.startup(query: nav.search.isEmpty ? null : nav.search);
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
    context.read<PlayerProvider>().playQueue(selected);
    context.read<NavigationProvider>().openPlayer();
  }

  void _addToPlaylistSelected(List<Song> songs) {
    final selected = selectedSongs(_sel, songs);
    _sel.cancel();
    showAddToPlaylistSheetForSongs(context, selected);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final player = context.read<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();

    // 依据全局搜索词过滤（喜欢页共用同一匹配函数），再按本页排序偏好排序。
    final songs = sortSongs(filterSongs(lib.songs, nav.search),
        direct.settings.sortSongs,
        factorOf: direct.weight.factorOf);

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        CountHeader(
          count: songs.length,
          trailing: SortMenuButton(
            value: direct.settings.sortSongs,
            withWeight: true,
            onChanged: (v) => setState(() => direct.settings.sortSongs = v),
          ),
        ),
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
                icon: Icons.playlist_add,
                label: '加入歌单',
                onPressed: _sel.isEmpty
                    ? null
                    : () => _addToPlaylistSelected(songs),
              ),
            ],
          ),
        Expanded(
          child: songs.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadSongs(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadSongs(query: nav.search.isEmpty ? null : nav.search),
                  child: ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (c, i) {
                      final s = songs[i];
                      return SongTile(
                        song: s,
                        source: lib.sourceFor(s.sourceKey),
                        onPlay: () {
                          player.playQueue(songs, index: i);
                          context.read<NavigationProvider>().openPlayer();
                        },
                        selectionMode: _sel.active,
                        selected: _sel.contains(songKey(s)),
                        onSelect: () => _toggle(songKey(s)),
                        onStartSelect: () { setState(() => _sel.startWith(songKey(s))); },
                      );
                    },
                  ),
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

class _AlbumsViewState extends State<_AlbumsView> {
  /// 本地覆盖的展示形式（null 时读设置）。
  CollectionViewMode? _mode;

  CollectionViewMode _modeOf(BuildContext c) =>
      _mode ?? c.read<DirectSourceManager>().settings.viewModeAlbums;

  void _setMode(BuildContext c, CollectionViewMode m) {
    c.read<DirectSourceManager>().settings.viewModeAlbums = m;
    setState(() => _mode = m);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.albums.isEmpty && !lib.loading) {
        lib.startup(
            query: context.read<NavigationProvider>().search.isEmpty
                ? null
                : context.read<NavigationProvider>().search);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    final albums = sortByCollection(
        _filter(lib.albums, nav.search), direct.settings.sortAlbums,
        (a) => a.album);
    final card = _modeOf(context) == CollectionViewMode.card;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        CountHeader(
          count: albums.length,
          unit: '张',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SortMenuButton(
                value: direct.settings.sortAlbums,
                onChanged: (v) => setState(() => direct.settings.sortAlbums = v),
              ),
              ViewModeToggle(
                card: card,
                onChanged: (v) => _setMode(
                    context, v ? CollectionViewMode.card : CollectionViewMode.list),
              ),
            ],
          ),
        ),
        Expanded(
          child: albums.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadAlbums(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadAlbums(query: nav.search.isEmpty ? null : nav.search),
                  child: card
                      ? SquareCardGrid(
                          itemCount: albums.length,
                          itemBuilder: (c, i) => _AlbumCard(album: albums[i]),
                        )
                      : ListView.separated(
                          itemCount: albums.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 72),
                          itemBuilder: (c, i) =>
                              _AlbumListTile(album: albums[i]),
                        ),
                ),
        ),
      ],
    );
  }

  List<Album> _filter(List<Album> albums, String q) {
    if (q.trim().isEmpty) return albums;
    final qq = q.trim().toLowerCase();
    return albums.where((a) =>
        a.album.toLowerCase().contains(qq) ||
        (a.artist.toLowerCase().contains(qq))).toList();
  }
}

/// 打开专辑歌曲弹层（卡片/列表两种形态共用）。
Future<void> _openAlbum(BuildContext context, Album album) async {
  final lib = context.read<LibraryProvider>();
  final songs = lib.albumSongs(album);
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => _AlbumSongsSheet(album: album, songs: songs),
  );
}

class _AlbumListTile extends StatelessWidget {
  final Album album;
  const _AlbumListTile({required this.album});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 44,
          child: album.coverPath != null
              ? Image.file(File(album.coverPath!),
                  fit: BoxFit.cover,
                  cacheWidth: 88,
                  cacheHeight: 88,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.album, color: colorScheme.primary))
              : Container(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  child: Icon(Icons.album, color: colorScheme.primary),
                ),
        ),
      ),
      title: Text(album.album,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text('${album.artist} · ${album.trackCount}首',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openAlbum(context, album),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) => SquareCard(
        title: album.album,
        subtitle: '${album.artist} · ${album.trackCount}首',
        coverPath: album.coverPath,
        fallbackIcon: Icons.album,
        onTap: () => _openAlbum(context, album),
      );
}

class _AlbumSongsSheet extends StatelessWidget {
  final Album album;
  final List<Song> songs;
  const _AlbumSongsSheet({required this.album, required this.songs});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (c, scrollCtrl) {
        final player = context.read<PlayerProvider>();
        final lib = context.read<LibraryProvider>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(album.album,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            CountHeader(count: songs.length),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollCtrl,
                itemCount: songs.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                itemBuilder: (c, i) {
                  final s = songs[i];
                  return SongTile(
                    song: s,
                    source: lib.sourceFor(s.sourceKey),
                    onPlay: () {
                      Navigator.of(c).pop();
                      player.playQueue(songs, index: i);
                      context.read<NavigationProvider>().openPlayer();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ArtistsView extends StatefulWidget {
  const _ArtistsView();

  @override
  State<_ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<_ArtistsView> {
  /// 本地覆盖的展示形式（null 时读设置）。
  CollectionViewMode? _mode;

  CollectionViewMode _modeOf(BuildContext c) =>
      _mode ?? c.read<DirectSourceManager>().settings.viewModeArtists;

  void _setMode(BuildContext c, CollectionViewMode m) {
    c.read<DirectSourceManager>().settings.viewModeArtists = m;
    setState(() => _mode = m);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.artists.isEmpty && !lib.loading) {
        lib.startup(
            query: context.read<NavigationProvider>().search.isEmpty
                ? null
                : context.read<NavigationProvider>().search);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    final artists = sortByCollection(
        _filter(lib.artists, nav.search), direct.settings.sortArtists,
        (a) => a.name);
    final card = _modeOf(context) == CollectionViewMode.card;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        CountHeader(
          count: artists.length,
          unit: '位',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SortMenuButton(
                value: direct.settings.sortArtists,
                onChanged: (v) =>
                    setState(() => direct.settings.sortArtists = v),
              ),
              ViewModeToggle(
                card: card,
                onChanged: (v) => _setMode(
                    context, v ? CollectionViewMode.card : CollectionViewMode.list),
              ),
            ],
          ),
        ),
        Expanded(
          child: artists.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadArtists(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadArtists(query: nav.search.isEmpty ? null : nav.search),
                  child: card
                      ? SquareCardGrid(
                          itemCount: artists.length,
                          itemBuilder: (c, i) => _ArtistCard(artist: artists[i]),
                        )
                      : ListView.separated(
                          itemCount: artists.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 72),
                          itemBuilder: (c, i) =>
                              _ArtistListTile(artist: artists[i]),
                        ),
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

/// 打开歌手歌曲弹层（卡片/列表两种形态共用）。
void _openArtist(BuildContext context, Artist artist) {
  final lib = context.read<LibraryProvider>();
  final songs = lib.artistSongs(artist);
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => _ArtistSongsSheet(artist: artist, songs: songs),
  );
}

class _ArtistListTile extends StatelessWidget {
  final Artist artist;
  const _ArtistListTile({required this.artist});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          width: 44,
          height: 44,
          child: artist.coverPath != null
              ? Image.file(File(artist.coverPath!),
                  fit: BoxFit.cover,
                  cacheWidth: 88,
                  cacheHeight: 88,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.person, color: colorScheme.primary))
              : Container(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  child: Icon(Icons.person, color: colorScheme.primary),
                ),
        ),
      ),
      title: Text(artist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text('${artist.songCount}首 · ${artist.albumCount}张专辑',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openArtist(context, artist),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  final Artist artist;
  const _ArtistCard({required this.artist});

  @override
  Widget build(BuildContext context) => SquareCard(
        title: artist.name,
        subtitle: '${artist.songCount}首 · ${artist.albumCount}张专辑',
        coverPath: artist.coverPath,
        fallbackIcon: Icons.person,
        onTap: () => _openArtist(context, artist),
      );
}

class _ArtistSongsSheet extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;
  const _ArtistSongsSheet({required this.artist, required this.songs});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (c, scrollCtrl) {
        final player = context.read<PlayerProvider>();
        final lib = context.read<LibraryProvider>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(artist.name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            CountHeader(count: songs.length),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollCtrl,
                itemCount: songs.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                itemBuilder: (c, i) {
                  final s = songs[i];
                  return SongTile(
                    song: s,
                    source: lib.sourceFor(s.sourceKey),
                    onPlay: () {
                      Navigator.of(c).pop();
                      player.playQueue(songs, index: i);
                      context.read<NavigationProvider>().openPlayer();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
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
          Icon(Icons.music_off, size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('暂无内容'),
          const SizedBox(height: 8),
          TextButton.icon(icon: const Icon(Icons.refresh), label: const Text('刷新/扫描'), onPressed: onRefresh),
        ],
      ),
    );
  }
}