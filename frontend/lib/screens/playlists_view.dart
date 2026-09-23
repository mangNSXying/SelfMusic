import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/song_title_format.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/square_card.dart';
import '../widgets/list_selection.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_tile.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/view_mode_toggle.dart';

/// 歌单栏：列表页（新建 / 重命名 / 删除 / 长按多选删除）与详情原地子视图。
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({super.key});

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  final Selection<int> _sel = Selection<int>();

  /// 本地覆盖的展示形式（null 时读设置）。
  CollectionViewMode? _mode;

  CollectionViewMode _modeOf(BuildContext c) =>
      _mode ?? c.read<DirectSourceManager>().settings.viewModePlaylists;

  void _setMode(BuildContext c, CollectionViewMode m) {
    c.read<DirectSourceManager>().settings.viewModePlaylists = m;
    setState(() => _mode = m);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  void _toggleSelect(int id) => setState(() {
        _sel.active = true;
        _sel.toggle(id);
      });

  Future<void> _deleteSelected(PlaylistsProvider provider) async {
    final playlists = provider.playlists;
    final names = _sel
        .of(playlists.map((p) => p.id))
        .map((id) => playlists.firstWhere((p) => p.id == id).name)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除选中的 ${names.length} 个播放列表？'
            '（仅移除播放列表，其中歌曲不会被删除。）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = context.read<NavigationProvider>();
    final player = context.read<PlayerProvider>();
    for (final id in _sel.selected.toList()) {
      if (nav.browsingPlaylistId == id) nav.exitPlaylist();
      final uuid = provider.store.index.playlistUuidOf(id);
      provider.delete(id);
      if (uuid != null) player.onPlaylistDeleted(uuid);
    }
    setState(_sel.cancel);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaylistsProvider>();
    final nav = context.watch<NavigationProvider>();
    final direct = context.watch<DirectSourceManager>();
    final q = nav.search.trim().toLowerCase();
    final all = provider.playlists;
    final playlists = sortByCollection(
        q.isEmpty
            ? all
            : all.where((p) => p.name.toLowerCase().contains(q)).toList(),
        direct.settings.sortPlaylists,
        (p) => p.name);
    final card = _modeOf(context) == CollectionViewMode.card;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              if (_sel.active)
                SelectionBar(
                  total: playlists.length,
                  selectedCount: _sel.count,
                  onToggleAll: () =>
                      setState(() => _sel.setAll(playlists.map((p) => p.id))),
                  onCancel: () => setState(_sel.cancel),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.delete),
                      tooltip: '删除选中',
                      onPressed: _sel.isEmpty
                          ? null
                          : () => _deleteSelected(provider),
                    ),
                  ],
                ),
              if (_sel.active) const Divider(height: 1),
              if (!_sel.active)
                CountHeader(
                  count: playlists.length,
                  unit: '个播放列表',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SortMenuButton(
                        value: direct.settings.sortPlaylists,
                        onChanged: (v) => setState(
                            () => direct.settings.sortPlaylists = v),
                      ),
                      ViewModeToggle(
                        card: card,
                        onChanged: (v) => _setMode(
                            context,
                            v
                                ? CollectionViewMode.card
                                : CollectionViewMode.list),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: playlists.isEmpty
                    ? Center(
                        child: Text(all.isEmpty
                            ? '暂无歌单，点右下角「+」创建'
                            : '无匹配播放列表'))
                    : card
                        ? SquareCardGrid(
                            itemCount: playlists.length,
                            titleMaxLines: 2,
                            itemBuilder: (c, i) =>
                                _playlistCard(provider, playlists[i]),
                          )
                        : ListView.separated(
                            itemCount: playlists.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 72),
                            itemBuilder: (c, i) =>
                                _playlistTile(provider, playlists[i]),
                          ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: CornerAddButton(
              tooltip: '新建播放列表',
              onPressed: () => _createDialog(context, provider),
            ),
          ),
        ],
      );
  }

  Widget _playlistTile(PlaylistsProvider provider, PlaylistRow p) {
    return ListTile(
      selected: _sel.active && _sel.contains(p.id),
      leading: _sel.active
          ? Checkbox(
              value: _sel.contains(p.id),
              onChanged: (_) => _toggleSelect(p.id),
            )
          : const Icon(Icons.queue_music),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${provider.countOf(p.id)} 首'),
      trailing: _sel.active ? null : _playlistMenu(provider, p),
      onTap: _sel.active
          ? () => _toggleSelect(p.id)
          : () => context.read<NavigationProvider>().enterPlaylist(p.id),
      onLongPress: _sel.active
          ? () => _toggleSelect(p.id)
          : () => setState(() => _sel.startWith(p.id)),
    );
  }

  Widget _playlistCard(PlaylistsProvider provider, PlaylistRow p) {
    return SquareCard(
      title: p.name,
      titleMaxLines: 2,
      subtitle: '${provider.countOf(p.id)} 首',
      fallbackIcon: Icons.queue_music,
      onTap: _sel.active
          ? () => _toggleSelect(p.id)
          : () => context.read<NavigationProvider>().enterPlaylist(p.id),
      onLongPress: _sel.active
          ? () => _toggleSelect(p.id)
          : () => setState(() => _sel.startWith(p.id)),
      cornerAction: _sel.active
          ? Checkbox(
              value: _sel.contains(p.id),
              onChanged: (_) => _toggleSelect(p.id),
            )
          : _playlistMenu(provider, p),
    );
  }

  Widget _playlistMenu(PlaylistsProvider provider, PlaylistRow p) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      onSelected: (v) {
        switch (v) {
          case 'rename':
            _renameDialog(context, provider, p);
          case 'delete':
            _confirmDelete(context, provider, p);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }

  static Future<void> _createDialog(
      BuildContext context, PlaylistsProvider provider) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建播放列表'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(c).pop(t);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      provider.create(name);
    }
  }

  static Future<void> _renameDialog(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名播放列表'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(c).pop(t);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) provider.rename(p.id, name);
  }

  static Future<void> _confirmDelete(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除「${p.name}」？其中歌曲不会被删除，仅移除播放列表。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final nav = context.read<NavigationProvider>();
      if (nav.browsingPlaylistId == p.id) nav.exitPlaylist();
      provider.delete(p.id);
    }
  }
}

/// 歌单详情（原地子视图，仿源内浏览）：播放全部 / 移除 / 上移 / 下移。
class PlaylistDetailView extends StatefulWidget {
  final int playlistId;
  const PlaylistDetailView({super.key, required this.playlistId});

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  final Selection<String> _sel = Selection<String>();

  /// 歌单内歌曲滚动定位（打开时定位到当前播放歌曲）。
  ///
  /// 行高恒定为 72（双行 ListTile）+ 1 分隔线。追焦参考播放队列：进入时
  /// 直接用 initialScrollOffset 落在追焦处（首帧即渲染目标行，无可见扫描），
  /// 不再依赖逐行 GlobalKey 估算或首帧后再 jumpTo（曾因行高估算偏差导致
  /// 定位失败 + 触发两波封面解码尖峰，详见性能排查）。
  late final ScrollController _scroll;
  static const double _rowExtent = 72;
  static const double _sepExtent = 1;
  /// 已就位（首帧 initialScrollOffset 或顶部）；true 后不再触发兜底追焦。
  bool _located = false;

  /// 歌单数据按 [PlaylistsProvider.dataRevision] 缓存，避免每次重建重查 SQLite；
  /// 排序偏好变化时同样重排（平行数组按同一顺序重排，行与歌不拆散）。
  int _songsRevision = -1;
  CollectionSort _sort = CollectionSort.defaultOrder;
  List<Song> _songs = const [];
  List<PlaylistItemRow> _items = const [];

  /// 追焦目标 offset：队列同款固定上边距（目标行置于距顶 96px 处），
  /// 无需等 viewport；超出列表范围的值交由滚动位置钳位。
  double _focusOffset(int index) =>
      (index * (_rowExtent + _sepExtent) - 96).clamp(0.0, double.infinity);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PlaylistDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换歌单（原地子视图理论不会，但防御）后强制重取数据。
    if (widget.playlistId != oldWidget.playlistId) _songsRevision = -1;
  }

  /// 按数据版本拉取歌单条目；数据未变且排序未变时直接复用缓存（0 次 SQLite）。
  void _syncSongs(PlaylistsProvider provider, CollectionSort sort,
      double Function(Song) factorOf) {
    final rev = provider.dataRevision;
    if (rev == _songsRevision && sort == _sort) return;
    _songsRevision = rev;
    _sort = sort;
    final items = provider.itemsOf(widget.playlistId);
    final songs = [for (final r in items) provider.songOf(r)];
    if (sort == CollectionSort.defaultOrder) {
      _items = items;
      _songs = List.unmodifiable(songs);
      return;
    }
    final order = songSortOrder(songs, sort, factorOf: factorOf);
    _items = [for (final i in order) items[i]];
    _songs = List.unmodifiable([for (final i in order) songs[i]]);
  }

  /// 兜底定位到第 [index] 行（首次数据未加载时的边缘情况）：
  /// 一次精确 jumpTo（固定行高保证落点必在视口内）。
  void _scrollToCurrent(int index) {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_focusOffset(index)
        .clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void initState() {
    super.initState();
    // 打开即落在当前播放歌曲处：进 state 时同步读取已加载数据算出目标，
    // 用 initialScrollOffset 让首帧直接渲染追焦处（无可见扫描）。数据
    // 未加载时置 0，交给 build 里的兜底追焦逻辑。
    final provider = context.read<PlaylistsProvider>();
    final player = context.read<PlayerProvider>();
    final direct = context.read<DirectSourceManager>();
    var firstIdx = -1;
    if (provider.loaded && !_located) {
      _syncSongs(provider, direct.settings.sortPlaylistDetail,
          direct.weight.factorOf);
      firstIdx = _songs.indexWhere(player.isCurrent);
    }
    if (firstIdx >= 0) {
      _scroll = ScrollController(initialScrollOffset: _focusOffset(firstIdx));
      _located = true;
    } else {
      _scroll = ScrollController();
    }
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  Future<void> _removeSelected(PlaylistsProvider provider) async {
    final songsNow = provider.songsOf(widget.playlistId);
    final itemsNow = provider.itemsOf(widget.playlistId);
    final count = _sel.of(songsNow.map((s) => songKey(s))).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('从歌单移除'),
        content: Text('确定从歌单中移除选中的 $count 首歌曲？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 从后往前移除，避免 store 序号移位问题。
    final removed = <Song>[];
    for (var i = itemsNow.length - 1; i >= 0; i--) {
      if (_sel.contains(songKey(songsNow[i]))) {
        provider.removeItemRow(widget.playlistId, itemsNow[i]);
        removed.add(songsNow[i]);
      }
    }
    setState(_sel.cancel);
    _notifyPlayerRemoved(provider, removed);
  }

  /// 歌单删歌后联动当前播放（删到当前曲则播新末尾；深层列表移除引用）。
  void _notifyPlayerRemoved(PlaylistsProvider provider, List<Song> removed) {
    if (removed.isEmpty) return;
    final uuid = provider.store.index.playlistUuidOf(widget.playlistId);
    if (uuid == null) return;
    final player = context.read<PlayerProvider>();
    final count = provider.countOf(widget.playlistId);
    for (final s in removed) {
      unawaited(player.onPlaylistSongRemoved(uuid, s, newPlaylistCount: count));
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final provider = context.watch<PlaylistsProvider>();
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final titleFormat = direct.settings.songTitleFormat;

    PlaylistRow? playlist;
    for (final p in provider.playlists) {
      if (p.id == widget.playlistId) playlist = p;
    }
    // 数据版本不变时复用缓存的歌单条目（避免每帧/每次通知重查 SQLite）。
    _syncSongs(provider, direct.settings.sortPlaylistDetail,
        direct.weight.factorOf);
    var currentIdx = -1;
    currentIdx = _songs.indexWhere((s) => player.isCurrent(s));

    // 打开歌单后自动定位到当前播放歌曲（仅一次）。
    if (!_located && currentIdx >= 0) {
      _located = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent(currentIdx);
      });
    }

    return SectionSwipe(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                onPressed: () => nav.exitPlaylist(),
              ),
              Expanded(
                child: Text(
                  playlist?.name ?? '播放列表',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (_songs.isNotEmpty) ...[
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放全部'),
                  onPressed: () {
                    player.playQueue(_songs,
                        playlistUuid: provider.store.index
                            .ensurePlaylistUuid(widget.playlistId),
                        resumeFromBreakpoint: true);
                    context.read<NavigationProvider>().openPlayer();
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: '更多播放方式',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'fromStart') {
                      player.playQueue(_songs,
                          playlistUuid: provider.store.index
                              .ensurePlaylistUuid(widget.playlistId));
                      context.read<NavigationProvider>().openPlayer();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'fromStart', child: Text('从头播放')),
                  ],
                ),
              ],
            ],
          ),
        ),
        CountHeader(
          count: _songs.length,
          trailing: SortMenuButton(
            value: direct.settings.sortPlaylistDetail,
            withWeight: true,
            onChanged: (v) => setState(
                () => direct.settings.sortPlaylistDetail = v),
          ),
        ),
        if (_sel.active)
          SelectionBar(            total: _items.length,
            selectedCount: _sel.of(_items.map((r) => songKey(provider.songOf(r))))
                .length,
            onToggleAll: () => setState(() {
              _sel.active = true;
              _sel.setAll(_items.map((r) => songKey(provider.songOf(r))));
            }),
            onCancel: () => setState(_sel.cancel),
            actions: [
              IconButton(
                icon: const Icon(Icons.playlist_remove),
                tooltip: '从歌单移除',
                onPressed:
                    _sel.selected.isEmpty ? null : () => _removeSelected(provider),
              ),
            ],
          ),
        const Divider(height: 1),
        Expanded(
          child: _songs.isEmpty
              ? const Center(child: Text('歌单为空'))
              // itemExtent 固定行高（含 1px 分隔线）：深位置（首帧定位/跳转）
              // 只构建可见行，否则 Sliver 会从第 0 行逐行排到目标行——千首歌单
              // 一帧构建 700+ 行与封面，进入必卡（实测 712 项 vs 16 项）。
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowExtent + _sepExtent,
                  itemCount: _items.length,
                  itemBuilder: (c, i) {
                    final row = _items[i];
                    final s = _songs[i];
                    final isFirst = i == 0;
                    final isLast = i == _items.length - 1;
                    final key = songKey(s);
                    final isCurrent = i == currentIdx;
                    final cs = Theme.of(context).colorScheme;
                    final tile = ListTile(
                      selected: _sel.active && _sel.contains(key),
                      leading: _sel.active
                          ? Checkbox(
                              value: _sel.contains(key),
                              onChanged: (_) => _toggle(key),
                            )
                          : isCurrent
                              ? Icon(Icons.graphic_eq, color: cs.primary)
                              : CoverThumb(coverPath: s.coverPath),
                      title: Text(
                          formatSongTitle(s, titleFormat),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? TextStyle(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600)
                              : null),
                      subtitle: Text(
                        '${s.artist ?? "Unknown"} · ${s.albumName ?? ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _sel.active
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (v) {
                                switch (v) {
                                  case 'up':
                                    if (!isFirst) {
                                      provider.moveItemRow(
                                          widget.playlistId, row, -1);
                                    }
                                  case 'down':
                                    if (!isLast) {
                                      provider.moveItemRow(
                                          widget.playlistId, row, 1);
                                    }
                                  case 'remove':
                                    provider.removeItemRow(
                                        widget.playlistId, row);
                                    _notifyPlayerRemoved(
                                        provider, [provider.songOf(row)]);
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'up',
                                  enabled: !isFirst,
                                  child: const Text('上移'),
                                ),
                                PopupMenuItem(
                                  value: 'down',
                                  enabled: !isLast,
                                  child: const Text('下移'),
                                ),
                                const PopupMenuItem(
                                  value: 'remove',
                                  child: Text('移除'),
                                ),
                              ],
                            ),
                      onTap: _sel.active
                          ? () => _toggle(key)
                          : () {
                              player.playQueue(_songs,
                                  index: i,
                                  playlistUuid: provider.store.index
                                      .ensurePlaylistUuid(widget.playlistId));
                              context.read<NavigationProvider>().openPlayer();
                            },
                      onLongPress: _sel.active
                          ? () => _toggle(key)
                          : () => setState(() => _sel.startWith(key)),
                    );
                    return Column(
                      children: [
                        Expanded(child: tile),
                        if (!isLast)
                          const Divider(height: 1, indent: 56),
                      ],
                    );
                  },
                ),
        ),
        ],
      ),
    );
  }
}