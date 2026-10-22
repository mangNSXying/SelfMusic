import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../data/local/song_weight_store.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/song_groups.dart';
import '../utils/song_search.dart';
import 'app_dialog_actions.dart';
import 'header_action_button.dart';
import 'list_selection.dart';
import 'selection_bar.dart';
import 'song_collection_view.dart';
import 'song_tile.dart';

export 'song_tile.dart';

/// 统一歌单歌曲列表（歌曲列表的标准化实现）。
///
/// 内容区歌单详情与播放器带的「歌单页」共用这一份代码路径，保证：
/// 同源（同一持久化歌单 [playlists_provider]）、同一行形态（[SongTile] 完整行）、
/// 同一增删写回语义（[PlaylistsProvider.removeItemRow] / [PlaylistsProvider.moveItemRow]，
/// 并联动播放器 [PlayerProvider.onPlaylistSongRemoved]）、同一排序键
/// （[DirectSourceManager.settings.sortPlaylistDetail]）。
///
/// 分类/折叠/多选/计数栏由 [SongCollectionView] 统一实现。
///
/// 差异点收敛为参数：
/// - [onBack]：非空时头部左侧显示返回按钮（内容区详情返回内容层）；歌单页
///   传 null，不显示任何箭头/关闭（横向滑动即返回播放页）。
/// - [globalSearch]：true 时跟随全局搜索框（`NavigationProvider.search`，内容区）；
///   false 时列表自带搜索框（歌单页）。
class SongList extends StatefulWidget {
  final int playlistId;

  /// 头部左侧返回按钮；null 表示不显示（歌单页无左上箭头/右上关闭）。
  final VoidCallback? onBack;

  /// true：搜索跟随全局搜索框；false：页内自带搜索框。
  final bool globalSearch;

  /// 重进歌单页的追焦信号（每进一次 +1）：歌单页被 PageView 预热保活后重进
  /// 不重挂载，仅靠挂载追焦不够，tick 时重新定位当前播放歌曲。
  final ValueListenable<int>? focusTick;

  const SongList({
    super.key,
    required this.playlistId,
    this.onBack,
    this.globalSearch = false,
    this.focusTick,
  });

  @override
  State<SongList> createState() => _SongListState();
}

class _SongListState extends State<SongList> {
  /// 页内自带搜索（[widget.globalSearch] 为 false 时使用）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _localQuery = '';

  /// 歌单数据按 [PlaylistsProvider.dataRevision] / 元数据版本 / 排序缓存，
  /// 避免每次重建重查 SQLite；排序偏好变化时同样重排（平行数组按同一顺序
  /// 重排，行与歌不拆散）。
  int _songsRevision = -1;
  int _metaVersion = -1;
  CollectionSort _sort = CollectionSort.defaultOrder;
  List<Song> _songs = const [];
  List<PlaylistItemRow> _items = const [];

  /// 搜索过滤结果缓存（按歌单列表身份 + 搜索词）：build 重跑不重扫全单。
  List<Song>? _filterBase;
  String? _filterQuery;
  List<int> _visible = const [];
  List<Song> _displaySongs = const [];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SongList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换歌单后强制重取数据。
    if (widget.playlistId != oldWidget.playlistId) {
      _songsRevision = -1;
      _metaVersion = -1;
    }
  }

  /// 按数据版本拉取歌单条目；数据未变且排序未变时直接复用缓存（0 次 SQLite）。
  void _syncSongs(PlaylistsProvider provider, CollectionSort sort,
      SongWeightStore weight, int metaVersion) {
    final rev = provider.dataRevision;
    if (rev == _songsRevision && sort == _sort && metaVersion == _metaVersion) {
      return;
    }
    _songsRevision = rev;
    _metaVersion = metaVersion;
    _sort = sort;
    final items = provider.itemsOf(widget.playlistId);
    // 与歌曲页/喜欢页同源：条目快照优先解析为本机索引实时行
    // （封面、标题显示格式、歌手·专辑元数据即时可用）；源不在本机时保留快照。
    // 批量按源分组 IN 查询解析（resolveLiveSongs），代替逐行 songByRef 的
    // N+1 逐条 SELECT——整单首装曾把横滑进歌单页的帧拖到 300ms+。
    final songs = provider.store.index
        .resolveLiveSongs([for (final r in items) provider.songOf(r)]);
    if (sort == CollectionSort.defaultOrder) {
      _items = items;
      _songs = List.unmodifiable(songs);
      return;
    }
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = weight.sortKeysOf(songs,
        factors: sort.isWeight, playSecs: sort.isPlayStat);
    final order = songSortOrder(songs, sort,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _items = [for (final i in order) items[i]];
    _songs = List.unmodifiable([for (final i in order) songs[i]]);
  }

  /// 播放本组歌曲（播完即止），锚点与整单播放一致。
  Future<void> _playGroup(BuildContext c, List<Song> list) async {
    if (list.isEmpty) return;
    final provider = c.read<PlaylistsProvider>();
    final uuid =
        await provider.store.index.ensurePlaylistUuid(widget.playlistId);
    if (!c.mounted) return;
    final player = c.read<PlayerProvider>();
    player.playQueue(list,
        index: 0,
        playlistUuid: uuid,
        contextKey: PlayerProvider.anchorForPlaylist(uuid),
        resetAnchor: true,
        resumeFromBreakpoint: false);
    c.read<NavigationProvider>().openPlayer();
  }

  /// 批量「从歌单移除」。
  Future<void> _removeSelected(PlaylistsProvider provider, List<Song> selected,
      VoidCallback clearSelection) async {
    final count = selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('从歌单移除'),
        content: Text('确定从歌单中移除选中的 $count 首歌曲？'),
        actions: appDialogActions(
          c,
          confirmLabel: '移除',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    clearSelection();
    final keys = {for (final s in selected) songKey(s)};
    // 从后往前移除，避免 store 序号移位问题（_items 与 _songs 按同序平行）。
    final removed = <Song>[];
    for (var i = _items.length - 1; i >= 0; i--) {
      if (keys.contains(songKey(_songs[i]))) {
        provider.removeItemRow(widget.playlistId, _items[i]);
        removed.add(_songs[i]);
      }
    }
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

  /// 「播放 / 从头播放」。[startWithOrder] 为 true 时起始曲按当前播放顺序
  /// 算法决定（加权=权重抽样、列表循环=接续当前曲、顺序/单曲=首曲），
  /// 否则固定首曲。
  Future<void> _playAll({required bool startWithOrder}) async {
    final provider = context.read<PlaylistsProvider>();
    final player = context.read<PlayerProvider>();
    final nav = context.read<NavigationProvider>();
    final uuid =
        await provider.store.index.ensurePlaylistUuid(widget.playlistId);
    if (!mounted) return;
    player.playQueue(_songs,
        index: startWithOrder ? player.startIndexForPlaylist(_songs) : 0,
        playlistUuid: uuid,
        contextKey: PlayerProvider.anchorForPlaylist(uuid),
        resetAnchor: true,
        resumeFromBreakpoint: startWithOrder);
    nav.openPlayer();
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄：仅在"全局搜索"场景（内容区歌单详情）订阅全局搜索词；
    // 播放器带的歌单页（globalSearch=false）选择恒定的 '' 值、不订阅搜索词，
    // 全局搜索变化不重建。
    final search = context.select<NavigationProvider, String>(
        (n) => widget.globalSearch ? n.search : '');
    final provider = context.watch<PlaylistsProvider>();
    final direct = context.watch<DirectSourceManager>();

    PlaylistRow? playlist;
    for (final p in provider.playlists) {
      if (p.id == widget.playlistId) playlist = p;
    }
    // 数据版本/元数据版本不变时复用缓存的歌单条目。
    _syncSongs(provider, direct.settings.sortPlaylistDetail, direct.weight,
        direct.metaVersion);
    // 搜索：全局搜索框（内容区）或页内自带搜索框（歌单页）过滤；visible 为原始下标映射。
    final query = (widget.globalSearch ? search.trim() : _localQuery.trim())
        .toLowerCase();
    final searching = query.isNotEmpty;
    if (!identical(_filterBase, _songs) || _filterQuery != query) {
      _filterBase = _songs;
      _filterQuery = query;
      _visible = <int>[
        for (var i = 0; i < _songs.length; i++)
          if (songMatchesQuery(_songs[i], query)) i,
      ];
      _displaySongs = [for (final i in _visible) _songs[i]];
    }
    final visible = _visible;
    final displaySongs = _displaySongs;
    final groupMode = direct.settings.groupPlaylistDetail;
    final grouped = !searching && groupMode != SongGroupMode.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                  onPressed: widget.onBack,
                ),
              Expanded(
                child: Text(
                  playlist?.name ?? '歌单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (_songs.isNotEmpty) ...[
                HeaderActionButton(
                  primary: true,
                  icon: const Icon(Icons.play_arrow),
                  label: '播放',
                  onPressed: () => _playAll(startWithOrder: true),
                ),
                const SizedBox(width: 8),
                HeaderActionButton(
                  primary: false,
                  icon: const Icon(Icons.replay),
                  label: '从头播放',
                  onPressed: () => _playAll(startWithOrder: false),
                ),
              ],
            ],
          ),
        ),
        // 歌单页自带搜索框（内容区详情跟随全局搜索框，不重复渲染）。
        if (!widget.globalSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _localQuery = v),
              decoration: InputDecoration(
                hintText: '搜索当前歌单',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _localQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _localQuery = '');
                        },
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        Expanded(
          child: SongCollectionView(
            songs: displaySongs,
            searching: searching,
            collectionKey: 'playlist:${widget.playlistId}',
            groupMode: groupMode,
            onGroupModeChanged: (v) =>
                setState(() => direct.settings.groupPlaylistDetail = v),
            sort: direct.settings.sortPlaylistDetail,
            onSortChanged: (v) =>
                setState(() => direct.settings.sortPlaylistDetail = v),
            sortScope: SortScope.songs,
            focusCurrent: true,
            focusTick: widget.focusTick,
            sourceOf: null,
            emptyText: _songs.isEmpty ? '歌单为空' : '无匹配歌曲',
            countLabel: (n, _) => '共 $n 首歌曲',
            onPlay: (list, si) async {
              final full = visible[si];
              final player = context.read<PlayerProvider>();
              final nav = context.read<NavigationProvider>();
              final uuid = await provider.store.index
                  .ensurePlaylistUuid(widget.playlistId);
              if (!mounted) return;
              player.playQueue(_songs,
                  index: full,
                  playlistUuid: uuid,
                  contextKey: PlayerProvider.anchorForPlaylist(uuid));
              nav.openPlayer();
            },
            onPlayGroup: (list) => _playGroup(context, list),
            // 分组视图是重排展示，手动调序只在平铺下有意义：
            // 分组时隐藏上移/下移，仅保留移除。
            extraMenuItems: (s, si) {
              if (grouped) {
                return const [
                  PopupMenuItem(value: 'row:remove', child: Text('移除')),
                ];
              }
              final full = visible[si];
              return [
                PopupMenuItem(
                  value: 'row:up',
                  enabled: full > 0,
                  child: const Text('上移'),
                ),
                PopupMenuItem(
                  value: 'row:down',
                  enabled: full < _songs.length - 1,
                  child: const Text('下移'),
                ),
                const PopupMenuItem(
                  value: 'row:remove',
                  child: Text('移除'),
                ),
              ];
            },
            onExtraMenu: (s, v) {
              final full = _songs.indexOf(s);
              if (full < 0) return;
              final itemRow = _items[full];
              switch (v) {
                case 'row:up':
                  if (full > 0) {
                    provider.moveItemRow(widget.playlistId, itemRow, -1);
                  }
                case 'row:down':
                  if (full < _songs.length - 1) {
                    provider.moveItemRow(widget.playlistId, itemRow, 1);
                  }
                case 'row:remove':
                  provider.removeItemRow(widget.playlistId, itemRow);
                  _notifyPlayerRemoved(provider, [provider.songOf(itemRow)]);
              }
            },
            selectionActions: (selected, clear) => [
              SelectionAction(
                icon: Icons.playlist_remove,
                label: '从歌单移除',
                onPressed: selected.isEmpty
                    ? null
                    : () => _removeSelected(provider, selected, clear),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
