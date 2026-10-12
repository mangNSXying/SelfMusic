import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../data/local/app_settings.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/song_title_format.dart';
import '../widgets/list_selection.dart';
import '../widgets/row_list.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_list.dart';
import '../widgets/song_row_view.dart';
import '../widgets/sort_menu_button.dart';

/// 当前播放队列页（改进.txt UI6）：无绑定歌单（全部歌曲/喜欢/专辑/歌手/播放源
/// 点播等）时右滑进入的兜底页，展示运行时播放队列。
///
/// 全屏 + 顶部搜索框 + 排序（按设置规则，仅展示层重排，不影响播放顺序），
/// 点行按真实队列序号切歌、当前曲高亮；支持单曲移除 / 清空 / 多选批量移除
/// （只改运行时队列）。行统一为完整形态（[SongTile] 完整行）。
class QueuePage extends StatefulWidget {
  /// 为 true 时返回无 Scaffold/AppBar 的嵌入式 Column（标题行 + 搜索/多选栏 +
  /// 列表），供横屏「左歌单右播放」分栏的左栏直接复用；完整功能（搜索/排序/
  /// 多选移除/清空）与整页形态一致。
  final bool embedded;

  const QueuePage({super.key, this.embedded = false});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  late CollectionSort _sort;

  /// 多选状态：key 一律取「真实队列下标」（可含同名歌，规避按 ref 撞键）。
  final Selection<int> _sel = Selection<int>();

  /// 可见序列缓存守卫：队列长度 / 查询词 / 排序任一变化才重算
  /// （播放事件频繁 notify，避免每次 build 重查权重库）。
  (CollectionSort, String, int)? _sig;
  List<int> _visible = const [];

  /// 行级视图数据缓存（R-1）。
  final SongRowCache _rowCache = SongRowCache();

  @override
  void initState() {
    super.initState();
    _sort = context.read<DirectSourceManager>().settings.sortQueue;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Song s, String q, SongTitleFormat fmt) {
    if (q.isEmpty) return true;
    if (formatSongTitle(s, fmt).toLowerCase().contains(q)) return true;
    final artist = (s.artist ?? '').toLowerCase();
    return artist.contains(q);
  }

  /// 先搜索过滤、再按设置排序，产出「真实队列下标」的展示序列。
  /// 排序仅作用于展示层：行状态只与真实序列（positives 原序）挂接，播放顺序不动。
  void _rebuildVisible(List<Song> queue, String q, DirectSourceManager direct) {
    final searched = <int>[
      for (var i = 0; i < queue.length; i++)
        if (_matches(queue[i], q, direct.settings.songTitleFormat)) i,
    ];
    if (searched.length < 2 || _sort == CollectionSort.defaultOrder) {
      _visible = searched;
      return;
    }
    final weight = direct.weight;
    // 权重/播放统计排序一次批量读取（按 sourceKey 分组），避免逐首同步查库。
    final keys = weight.sortKeysOf(queue,
        factors: _sort.isWeight, playSecs: _sort.isPlayStat);
    final songs = [for (final i in searched) queue[i]];
    _visible = [
      for (final i in songSortOrder(songs, _sort,
          factorOf: keys.factorOf, playSecOf: keys.playSecOf))
        searched[i],
    ];
  }

  Future<bool> _confirm(String title, String content, String okLabel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: Text(okLabel)),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _removeOne(PlayerProvider player, int realIndex) async {
    if (!await _confirm('移除歌曲', '确定从队列中移除这首歌曲？', '移除')) return;
    player.removeAt(realIndex);
  }

  Future<void> _clearQueue(PlayerProvider player) async {
    if (!await _confirm('清空队列', '确定清空整个播放队列并停止播放？', '清空')) return;
    player.clearQueue();
  }

  Future<void> _removeSelected(PlayerProvider player) async {
    final selected = _sel.selected.toList()..sort((a, b) => b.compareTo(a));
    if (selected.isEmpty) return;
    if (!await _confirm('移除选中', '确定从队列中移除选中的 ${selected.length} 首歌曲？',
        '移除')) {
      return;
    }
    // 从大到小逐删：已删的更大下标不会影响仍待删的较小下标有效性。
    for (final i in selected) {
      player.removeAt(i);
    }
    setState(_sel.cancel);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final queue = player.queue;
    final q = _query.trim().toLowerCase();
    final sig = (_sort, q, queue.length);
    if (sig != _sig) {
      _sig = sig;
      _rebuildVisible(queue, q, direct);
    }

    // 行级视图数据（R-1）：按展示序列计算派生文本/收藏态并缓存（懒求值）。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    _rowCache.begin(
      (
        queue.length,
        _sort,
        q,
        direct.metaVersion,
        direct.favoriteVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
      ),
      _visible.length,
      onWarm: () => direct.weight.warmMetaOf(queue),
    );

    if (widget.embedded) return _embeddedBody(context, player, direct, queue);
    return Scaffold(
      appBar: AppBar(
        title: Text('播放队列（${queue.length}）'),
        actions: [
          if (queue.isNotEmpty) ...[
            SortMenuButton(
              value: direct.settings.sortQueue,
              scope: SortScope.songs,
              onChanged: (v) {
                setState(() => _sort = v);
                direct.settings.sortQueue = v;
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空队列',
              onPressed: () => _clearQueue(player),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _searchOrSelection(player, direct),
        ),
      ),
      body: _listBody(player, direct, queue),
    );
  }

  /// 搜索框与多选栏共用同一位置（整页 AppBar.bottom 与嵌入式共用）。
  Widget _searchOrSelection(PlayerProvider player, DirectSourceManager direct) {
    if (_sel.active) {
      return SelectionBar(
        total: _visible.length,
        selectedCount: _sel.of(_visible).length,
        onToggleAll: () => setState(() {
          _sel.active = true;
          _sel.setAll(_visible);
        }),
        onCancel: () => setState(_sel.cancel),
        actions: [
          SelectionAction(
            icon: Icons.playlist_remove,
            label: '移除选中',
            onPressed:
                _sel.selected.isEmpty ? null : () => _removeSelected(player),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: '搜索当前队列',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: '清除',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
    );
  }

  /// 嵌入式：与 SongList 同形的 Column（标题行 + 搜索/多选栏 + Expanded 列表），
  /// 无 Scaffold/AppBar，可直接放进分栏 Row 的左栏（父级给足高度即可）。
  Widget _embeddedBody(BuildContext context, PlayerProvider player,
      DirectSourceManager direct, List<Song> queue) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '播放队列（${queue.length}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (queue.isNotEmpty) ...[
                SortMenuButton(
                  value: direct.settings.sortQueue,
                  scope: SortScope.songs,
                  onChanged: (v) {
                    setState(() => _sort = v);
                    direct.settings.sortQueue = v;
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '清空队列',
                  onPressed: () => _clearQueue(player),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
          child: _searchOrSelection(player, direct),
        ),
        const Divider(height: 1),
        Expanded(child: _listBody(player, direct, queue)),
      ],
    );
  }

  Widget _listBody(PlayerProvider player, DirectSourceManager direct,
      List<Song> queue) {
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    return _visible.isEmpty
        ? Center(child: Text(queue.isEmpty ? '队列为空' : '无匹配歌曲'))
        : RowList(
              count: _visible.length,
              itemBuilder: (c, i) {
                final realIndex = _visible[i];
                final s = queue[realIndex];
                // 下标判高亮（展示可重排，用真实队列下标；复本仅新播行亮）。
                final isCurrent = realIndex == player.currentIndex;
                return SongTile(
                  song: s,
                  source: null,
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
                  playing: isCurrent,
                  selectionMode: _sel.active,
                  selected: _sel.contains(realIndex),
                  onSelect: () => setState(() {
                    _sel.active = true;
                    _sel.toggle(realIndex);
                  }),
                  onStartSelect: () =>
                      setState(() => _sel.startWith(realIndex)),
                  onPlay: () => player.playAt(realIndex),
                  extraMenuItems: const [
                    PopupMenuItem(
                      value: 'row:remove',
                      child: Text('移除'),
                    ),
                  ],
                  onExtraMenu: (v) {
                    if (v == 'row:remove') _removeOne(player, realIndex);
                  },
                );
              },
            );
  }
}