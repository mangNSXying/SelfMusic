import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';
import '../utils/play_progress.dart';
import '../utils/play_stats.dart';
import '../widgets/resizable_paginated_table.dart';
import '../widgets/table_columns.dart';
import 'library_info_detail_shared.dart';

/// 歌曲信息 → 播放数据详情：全部有效歌曲的播放次数、播放时长与中位播放进度。
///
/// 口径：次数 = play_sec / 歌曲时长（见 [playCountOf]），未知时长按 0 次；
/// 中位进度为全历史离开进度直方图的中位数（见 [PlayProgressHistogram]）。
/// 数据入场走后台 isolate（[DetailDataLoader]），宽屏用可拖拽列宽的分页表格
/// （[ResizablePaginatedTable]），窄屏用卡片。
class PlayDetailScreen extends StatefulWidget {
  const PlayDetailScreen({super.key});

  @override
  State<PlayDetailScreen> createState() => _PlayDetailScreenState();
}

class _PlayDetailScreenState extends State<PlayDetailScreen> {
  late final DetailDataLoader<List<PlayDetailRow>> _loader;

  String _query = '';
  bool _onlyWithPlay = false;

  /// 0=歌曲名，1=歌手，2=播放次数，3=播放时长，4=中位进度，5=播放源。
  int _sortColumn = 2;
  bool _ascending = false;
  final _searchCtrl = TextEditingController();

  static const _sortLabels = ['歌曲名', '歌手', '次数', '时长', '中位进度', '源'];

  static const List<TableColumnSpec> _columns = [
    TableColumnSpec(
        id: 'title',
        label: '歌曲名',
        defaultWeight: 220,
        minWeight: 80,
        rightPadding: 16,
        sortable: true),
    TableColumnSpec(
        id: 'artist',
        label: '歌手',
        defaultWeight: 160,
        minWeight: 60,
        rightPadding: 16,
        sortable: true),
    TableColumnSpec(
        id: 'count',
        label: '播放次数',
        defaultWeight: 110,
        minWeight: 50,
        rightPadding: 16,
        align: TextAlign.right,
        sortable: true),
    TableColumnSpec(
        id: 'play_time',
        label: '播放时长',
        defaultWeight: 110,
        minWeight: 50,
        rightPadding: 16,
        align: TextAlign.right,
        sortable: true),
    TableColumnSpec(
        id: 'median',
        label: '中位进度',
        defaultWeight: 120,
        minWeight: 50,
        rightPadding: 16,
        align: TextAlign.right,
        sortable: true),
    TableColumnSpec(
        id: 'source',
        label: '播放源',
        defaultWeight: 160,
        minWeight: 60,
        rightPadding: 0,
        sortable: true),
  ];

  @override
  void initState() {
    super.initState();
    _loader = DetailDataLoader<List<PlayDetailRow>>(
        () => context.read<DirectSourceManager>().index
            .playDetailRowsInBackground());
    _loader.onUpdate = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 登记索引依赖：扫描/元数据写入等数据变更通知 → 重跑后台查询。
    context.watch<DirectSourceManager>();
    _scheduleLoad();
  }

  bool _loadScheduled = false;
  void _scheduleLoad() {
    if (_loadScheduled) return;
    _loadScheduled = true;
    // 首帧后再查：首帧只出页面框架，重查询不冻入场。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (mounted) _loader.request();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 表头点击：同列切方向；换列时次数/时长/中位进度默认降序，文本列升序。
  void _onHeaderSort(int column) {
    setState(() {
      if (_sortColumn == column) {
        _ascending = !_ascending;
      } else {
        _sortColumn = column;
        _ascending = column != 2 && column != 3 && column != 4;
      }
    });
  }

  static double _countOf(PlayDetailRow r) {
    if (r.playSec <= 0) return 0;
    final d = r.duration;
    if (d == null || d <= 0) return 0;
    return r.playSec / d;
  }

  @override
  Widget build(BuildContext context) {
    final all = _loader.data;
    if (all == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('播放数据')),
        body: Center(
          child: _loader.failed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('加载失败'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _loader.request,
                      child: const Text('重试'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    var totalSec = 0;
    var totalCount = 0.0;
    for (final r in all) {
      totalSec += r.playSec;
      totalCount += _countOf(r);
    }

    final q = _query.trim().toLowerCase();
    var rows = all.where((r) {
      if (_onlyWithPlay && r.playSec <= 0) return false;
      if (q.isEmpty) return true;
      final t = r.title.toLowerCase().contains(q);
      final a = (r.artist ?? '').toLowerCase().contains(q);
      return t || a;
    }).toList();

    int cmp(PlayDetailRow a, PlayDetailRow b) {
      int c;
      switch (_sortColumn) {
        case 0:
          c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case 1:
          c = (a.artist ?? '')
              .toLowerCase()
              .compareTo((b.artist ?? '').toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 2:
          c = _countOf(a).compareTo(_countOf(b));
          if (c == 0) c = a.playSec.compareTo(b.playSec);
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 3:
          c = a.playSec.compareTo(b.playSec);
          if (c == 0) c = _countOf(a).compareTo(_countOf(b));
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 4:
          c = (a.medianPercent ?? -1).compareTo(b.medianPercent ?? -1);
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 5:
        default:
          c = a.sourceKey.toLowerCase().compareTo(b.sourceKey.toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
      }
      return _ascending ? c : -c;
    }

    rows.sort(cmp);
    final wide = isWideDetail(context);

    return Scaffold(
      appBar: AppBar(title: const Text('播放数据')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${all.length} 首 · '
                        '累计 ${totalCount.toStringAsFixed(1)} 次 · '
                        '${playSecLabel(totalSec)}',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '按歌曲名 / 歌手过滤',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('仅看有播放'),
                  selected: _onlyWithPlay,
                  onSelected: (v) => setState(() => _onlyWithPlay = v),
                ),
                const SizedBox(width: 8),
                Text('${rows.length} 首',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          // 窄屏表格表头放不下，改用按钮组排序（与元数据详情页同样式）。
          if (!wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < _sortLabels.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      _sortBtn(i, _sortLabels[i]),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('无匹配歌曲'))
                : wide
                    ? _wideTable(rows)
                    : _narrowCards(rows),
          ),
        ],
      ),
    );
  }

  Widget _sortBtn(int mode, String label) {
    final selected = _sortColumn == mode;
    final arrow = selected ? (_ascending ? ' ↑' : ' ↓') : '';
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      onPressed: () => setState(() {
        if (_sortColumn == mode) {
          _ascending = !_ascending;
        } else {
          _sortColumn = mode;
          // 次数/时长/中位进度默认降序，文本列默认升序。
          _ascending = mode == 2 || mode == 3 || mode == 4 ? false : true;
        }
      }),
      child: Text('$label$arrow'),
    );
  }

  /// 宽屏分页表格：列序 歌名、歌手、播放次数、播放时长、中位进度、播放源。
  ///
  /// 只构建当前页若干行；表头列宽可拖拽（与歌曲表共用同一套表头核心）。
  Widget _wideTable(List<PlayDetailRow> rows) {
    return ResizablePaginatedTable<PlayDetailRow>(
      key: const Key('play-detail-table'),
      tableId: 'library_play_detail',
      columns: _columns,
      rows: rows,
      resetToken: '$_sortColumn|$_ascending|$_onlyWithPlay|$_query',
      sortIndex: _sortColumn,
      sortAscending: _ascending,
      onSortColumn: _onHeaderSort,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      rowHeight: 48,
      cellBuilder: _cell,
    );
  }

  Widget _cell(BuildContext context, PlayDetailRow r, int column) {
    final base = Theme.of(context).textTheme.bodySmall;
    Widget text(String s, {TextAlign align = TextAlign.left}) => Text(
          s,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: base,
        );
    return switch (column) {
      0 => text(r.title),
      1 => text(r.artist ?? ''),
      2 => text(playCountLabel(r.playSec, r.duration),
          align: TextAlign.right),
      3 => text(playSecLabel(r.playSec), align: TextAlign.right),
      4 => text(formatMedianProgress(r.medianPercent),
          align: TextAlign.right),
      _ => text(r.sourceKey),
    };
  }

  /// 窄屏卡片：复用元数据详情页的 `Card + ExpansionTile` 样式。
  Widget _narrowCards(List<PlayDetailRow> rows) {
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        final played = r.playSec > 0;
        final artist = (r.artist == null || r.artist!.isEmpty)
            ? '未知歌手'
            : r.artist!;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ExpansionTile(
            dense: true,
            // 展开态默认画上下分割线（dividerColor），卡片本身已有边界，去掉。
            shape: const Border(),
            collapsedShape: const Border(),
            title:
                Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('$artist · ${r.sourceKey}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (played ? cs.primary : cs.outline)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                playCountLabel(r.playSec, r.duration),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: played ? cs.primary : cs.outline,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            children: [
              _infoLine('播放次数', playCountLabel(r.playSec, r.duration)),
              _infoLine('播放时长', playSecLabel(r.playSec)),
              _infoLine('中位进度', formatMedianProgress(r.medianPercent)),
              _infoLine('播放源', r.sourceKey),
              _infoLine(
                  '歌曲时长',
                  r.duration != null && r.duration! > 0
                      ? '${r.duration} 秒'
                      : '未知'),
            ],
          ),
        );
      },
    );
  }

  Widget _infoLine(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7))),
          ),
          Expanded(
            child: Text(value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
