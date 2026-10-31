import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';
import '../widgets/resizable_paginated_table.dart';
import '../widgets/table_columns.dart';
import 'library_info_detail_shared.dart';

/// 歌曲信息 → 元数据详情：精确到每一首歌，各维度“有没有 / 是什么”。
///
/// 过滤：搜索（歌名/歌手/专辑）+ 维度缺失过滤；排序：歌曲名 / 歌手 / 缺失数。
/// 数据入场走后台 isolate（[DetailDataLoader]），宽屏用可拖拽列宽的分页表格
/// （[ResizablePaginatedTable]），窄屏用卡片。
class MetaDetailScreen extends StatefulWidget {
  const MetaDetailScreen({super.key});

  @override
  State<MetaDetailScreen> createState() => _MetaDetailScreenState();
}

class _MetaDetailScreenState extends State<MetaDetailScreen> {
  late final DetailDataLoader<List<MetaDetailRow>> _loader;

  String _query = '';
  String? _dimFilter; // null=全部，'missing_any'=有缺失，否则为维度 key
  int _sortMode = 0; // 0=歌曲名，1=歌手，2=缺失数
  bool _ascending = true;
  final _searchCtrl = TextEditingController();

  static const dims = [
    ('meta_read', '已读元数据'),
    ('artist', '歌手'),
    ('album', '专辑'),
    ('album_artist', '专辑歌手'),
    ('genre', '流派'),
    ('track_no', '曲目号'),
    ('year', '年份'),
    ('duration', '时长'),
    ('cover', '专辑封面'),
    ('lyrics', '歌词'),
    ('format', '格式'),
    ('bitrate', '码率（大小+时长估算）'),
  ];

  /// 宽屏表格的维度列：除歌手（已有独立列）外的 11 维，直接显示值。
  static const wideDims = [
    ('meta_read', '已读'),
    ('album', '专辑'),
    ('album_artist', '专辑歌手'),
    ('genre', '流派'),
    ('track_no', '曲目号'),
    ('year', '年份'),
    ('duration', '时长'),
    ('cover', '封面'),
    ('lyrics', '歌词'),
    ('format', '格式'),
    ('bitrate', '码率'),
  ];

  /// 宽屏表格列：前三列可排序，其余维度直接显示值。
  static final List<TableColumnSpec> _columns = [
    const TableColumnSpec(
        id: 'title',
        label: '歌曲名',
        defaultWeight: 200,
        minWeight: 70,
        rightPadding: 12,
        sortable: true),
    const TableColumnSpec(
        id: 'artist',
        label: '歌手',
        defaultWeight: 140,
        minWeight: 50,
        rightPadding: 12,
        sortable: true),
    const TableColumnSpec(
        id: 'missing',
        label: '缺失数',
        defaultWeight: 80,
        minWeight: 40,
        rightPadding: 12,
        align: TextAlign.right,
        sortable: true),
    for (final d in wideDims)
      TableColumnSpec(
        id: 'dim_${d.$1}',
        label: d.$2,
        defaultWeight: 90,
        minWeight: 36,
        rightPadding: 12,
      ),
  ];

  @override
  void initState() {
    super.initState();
    _loader = DetailDataLoader<List<MetaDetailRow>>(
        () => context.read<DirectSourceManager>().index
            .metaDetailRowsInBackground());
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

  /// 表头点击：同列切方向；换列时缺失数默认降序，文本列升序。
  void _onHeaderSort(int column) {
    setState(() {
      if (_sortMode == column) {
        _ascending = !_ascending;
      } else {
        _sortMode = column;
        _ascending = column != 2;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = _loader.data;
    if (all == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('元数据信息')),
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

    final q = _query.trim().toLowerCase();
    var rows = all.where((r) {
      if (q.isNotEmpty) {
        final hit = r.title.toLowerCase().contains(q) ||
            (r.artist ?? '').toLowerCase().contains(q) ||
            (r.album ?? '').toLowerCase().contains(q);
        if (!hit) return false;
      }
      if (_dimFilter == null) return true;
      if (_dimFilter == 'missing_any') return r.missingCount > 0;
      return !r.hasDim(_dimFilter!);
    }).toList();

    int cmp(MetaDetailRow a, MetaDetailRow b) {
      int c;
      switch (_sortMode) {
        case 1:
          c = (a.artist ?? '')
              .toLowerCase()
              .compareTo((b.artist ?? '').toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 2:
          c = a.missingCount.compareTo(b.missingCount);
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 0:
        default:
          c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
      }
      return _ascending ? c : -c;
    }

    rows.sort(cmp);
    final wide = isWideDetail(context);

    return Scaffold(
      appBar: AppBar(title: const Text('元数据信息')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '按歌曲名 / 歌手 / 专辑过滤',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _dimFilter == null,
                    onSelected: (_) => setState(() => _dimFilter = null),
                  ),
                  ChoiceChip(
                    label: const Text('有缺失'),
                    selected: _dimFilter == 'missing_any',
                    onSelected: (_) =>
                        setState(() => _dimFilter = 'missing_any'),
                  ),
                  for (final d in dims)
                    ChoiceChip(
                      label: Text('缺${d.$2}'),
                      selected: _dimFilter == d.$1,
                      onSelected: (_) =>
                          setState(() => _dimFilter = d.$1),
                    ),
                ],
              ),
            ),
          ),
          // 窄屏用按钮组排序，宽屏用表格表头排序。
          if (!wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  _sortBtn(context, 0, '歌曲名'),
                  const SizedBox(width: 6),
                  _sortBtn(context, 1, '歌手'),
                  const SizedBox(width: 6),
                  _sortBtn(context, 2, '缺失数'),
                  const Spacer(),
                  Text('${rows.length} / ${all.length} 首',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          if (wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('${rows.length} / ${all.length} 首',
                    style: Theme.of(context).textTheme.bodySmall),
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

  Widget _sortBtn(BuildContext context, int mode, String label) {
    final selected = _sortMode == mode;
    final arrow = selected ? (_ascending ? ' ↑' : ' ↓') : '';
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      onPressed: () => setState(() {
        if (_sortMode == mode) {
          _ascending = !_ascending;
        } else {
          _sortMode = mode;
          _ascending = mode == 2 ? false : true;
        }
      }),
      child: Text('$label$arrow'),
    );
  }

  /// 宽屏分页表格：歌曲 / 歌手 / 缺失数（可排序表头）+ 其余 11 维直接显示值。
  /// 缺失值红色显示，有值显示原文；表头列宽可拖拽。
  Widget _wideTable(List<MetaDetailRow> rows) {
    return ResizablePaginatedTable<MetaDetailRow>(
      key: const Key('meta-detail-table'),
      tableId: 'library_meta_detail',
      columns: _columns,
      rows: rows,
      resetToken: '$_sortMode|$_ascending|$_dimFilter|$_query',
      sortIndex: _sortMode,
      sortAscending: _ascending,
      onSortColumn: _onHeaderSort,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      rowHeight: 48,
      cellBuilder: _cell,
    );
  }

  Widget _cell(BuildContext context, MetaDetailRow r, int column) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall;
    TextStyle? missingStyle(bool ok) => ok
        ? base
        : base?.copyWith(color: cs.error, fontWeight: FontWeight.w600);
    Widget text(String s,
            {TextStyle? style, TextAlign align = TextAlign.left}) =>
        Text(
          s,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: style ?? base,
        );
    if (column == 0) return text(r.title);
    if (column == 1) {
      return text(metaDimValue(r, 'artist'),
          style: missingStyle(r.hasArtist));
    }
    if (column == 2) {
      return text('${r.missingCount}', align: TextAlign.right);
    }
    final d = wideDims[column - 3];
    return text(
      metaDimValue(r, d.$1),
      style: missingStyle(r.hasDim(d.$1)),
    );
  }

  /// 窄屏卡片：标题=歌名，副标题=歌手·专辑·源，展开看 12 维值。
  Widget _narrowCards(List<MetaDetailRow> rows) {
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        final missing = r.missingCount;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ExpansionTile(
            dense: true,
            // 展开态默认画上下分割线（dividerColor），卡片本身已有边界，去掉。
            shape: const Border(),
            collapsedShape: const Border(),
            title:
                Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${(r.artist == null || r.artist!.isEmpty) ? '未知歌手' : r.artist} · ${(r.album == null || r.album!.isEmpty) ? '未知专辑' : r.album} · ${r.sourceKey}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (missing == 0 ? cs.primary : cs.error)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                missing == 0 ? '全齐' : '缺 $missing 项',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: missing == 0 ? cs.primary : cs.error,
                    ),
              ),
            ),
            children: [
              for (final d in dims)
                _dimLine(context, d.$2, _dimValue(r, d.$1),
                    ok: r.hasDim(d.$1)),
            ],
          ),
        );
      },
    );
  }

  String _dimValue(MetaDetailRow r, String dim) => metaDimValue(r, dim);

  Widget _dimLine(BuildContext context, String label, String value,
      {required bool ok}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7))),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ok ? null : cs.error,
                    fontWeight: ok ? null : FontWeight.w600,
                  ),
            ),
          ),
          Icon(ok ? Icons.check : Icons.close,
              size: 14, color: ok ? cs.primary : cs.error),
        ],
      ),
    );
  }
}

/// 维度展示值：文本空/数字缺 → `缺失`（卡片与宽屏表格共用）。
String metaDimValue(MetaDetailRow r, String dim) => switch (dim) {
      'meta_read' => r.metaRead ? '已读' : '待读取',
      'artist' => metaText(r.artist),
      'album' => metaText(r.album),
      'album_artist' => metaText(r.albumArtist),
      'genre' => metaText(r.genre),
      'track_no' => r.trackNo?.toString() ?? '缺失',
      'year' => r.year?.toString() ?? '缺失',
      'duration' =>
        r.duration != null && r.duration! > 0 ? '${r.duration} 秒' : '缺失',
      'cover' => r.hasCover ? '有' : '缺失',
      'lyrics' => r.hasLyrics ? '有' : '缺失',
      'format' => metaText(r.format),
      'bitrate' => r.bitrateEstimable ? '可估算' : '缺失',
      _ => '',
    };

String metaText(String? s) => (s == null || s.isEmpty) ? '缺失' : s;
