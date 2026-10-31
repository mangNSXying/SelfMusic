import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/table_column_weights.dart';
import '../providers/direct_source_manager.dart';
import 'resizable_table_header.dart';
import 'table_columns.dart';

/// 通用「可拖拽列宽 + 分页」表格（播放数据 / 元数据详情共用）。
///
/// - 列宽：默认自适应，用户拖动表头分隔线改权重；双击恢复默认；按 [tableId]
///   持久化到 AppSettings。
/// - 分页：只构建当前页行，行高固定。
/// - 排序：表头只负责发出列下标，升/降语义由页面决定。
class ResizablePaginatedTable<T> extends StatefulWidget {
  final String tableId;
  final List<TableColumnSpec> columns;
  final List<T> rows;

  /// 排序/过滤/搜索变化时传一个新值，表格会回到第 1 页。
  final Object? resetToken;

  final int sortIndex;
  final bool sortAscending;
  final ValueChanged<int> onSortColumn;

  final Widget Function(BuildContext context, T row, int column) cellBuilder;

  final double rowHeight;
  final EdgeInsetsGeometry padding;
  final int initialRowsPerPage;
  final List<int> rowsPerPageOptions;

  const ResizablePaginatedTable({
    super.key,
    required this.tableId,
    required this.columns,
    required this.rows,
    required this.resetToken,
    required this.sortIndex,
    required this.sortAscending,
    required this.onSortColumn,
    required this.cellBuilder,
    this.rowHeight = 48,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.initialRowsPerPage = 25,
    this.rowsPerPageOptions = const [15, 25, 50, 100],
  });

  @override
  State<ResizablePaginatedTable<T>> createState() =>
      _ResizablePaginatedTableState<T>();
}

class _ResizablePaginatedTableState<T>
    extends State<ResizablePaginatedTable<T>> {
  List<double> _weights = const [];
  bool _weightsLoaded = false;
  late int _rowsPerPage = widget.initialRowsPerPage;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    TableColumnWeightsRevision.instance.addListener(_reloadWeights);
  }

  @override
  void dispose() {
    TableColumnWeightsRevision.instance.removeListener(_reloadWeights);
    super.dispose();
  }

  void _reloadWeights() {
    if (!mounted || !_weightsLoaded) return;
    final stored = context
        .read<DirectSourceManager>()
        .settings
        .tableColumnWeights(widget.tableId);
    final next = sanitizeTableWeights(widget.columns, stored);
    if (listEquals(next, _weights)) return;
    setState(() => _weights = next);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_weightsLoaded) {
      _weightsLoaded = true;
      final stored = context
          .read<DirectSourceManager>()
          .settings
          .tableColumnWeights(widget.tableId);
      _weights = sanitizeTableWeights(widget.columns, stored);
    }
  }

  @override
  void didUpdateWidget(covariant ResizablePaginatedTable<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken) {
      _page = 0;
    }
    final maxPage = _maxPage(widget.rows.length);
    if (_page > maxPage) _page = maxPage;
  }

  int _maxPage(int total) =>
      total == 0 ? 0 : (total - 1) ~/ _rowsPerPage;

  void _persist(List<double> weights) {
    context
        .read<DirectSourceManager>()
        .settings
        .setTableColumnWeights(widget.tableId, weights);
  }

  void _reset() {
    context
        .read<DirectSourceManager>()
        .settings
        .setTableColumnWeights(widget.tableId, null);
    setState(() {
      _weights = defaultTableWeights(widget.columns);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.rows.length;
    final maxPage = _maxPage(total);
    final page = _page.clamp(0, maxPage);
    final start = page * _rowsPerPage;
    final end = math.min(start + _rowsPerPage, total);
    final pageRows = start < total ? widget.rows.sublist(start, end) : <T>[];
    final layout = TableColumnLayout(widget.columns, _weights);

    return Column(
      children: [
        Padding(
          padding: widget.padding,
          child: ResizableTableHeader(
            columns: widget.columns,
            weights: _weights,
            sortIndex: widget.sortIndex,
            sortDescending: !widget.sortAscending,
            onSortColumn: widget.onSortColumn,
            onWeightsChanged: (w) => setState(() => _weights = w),
            onWeightsCommitted: _persist,
            onResetWeights: _reset,
            height: 44,
          ),
        ),
        Expanded(
          child: pageRows.isEmpty
              ? const Center(child: Text('无匹配歌曲'))
              : ListView.builder(
                  key: ValueKey(
                      '${widget.resetToken}|$page|$_rowsPerPage'),
                  itemExtent: widget.rowHeight,
                  itemCount: pageRows.length,
                  itemBuilder: (context, i) {
                    final row = pageRows[i];
                    final cells = [
                      for (var c = 0; c < widget.columns.length; c++)
                        widget.cellBuilder(context, row, c),
                    ];
                    return Padding(
                      padding: widget.padding,
                      child: Container(
                        height: widget.rowHeight,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: cs.outlineVariant.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        child: layout.buildCells(cells),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              const Text('每页'),
              const SizedBox(width: 6),
              DropdownButton<int>(
                value: _rowsPerPage,
                underline: const SizedBox.shrink(),
                items: [
                  for (final n in widget.rowsPerPageOptions)
                    DropdownMenuItem(value: n, child: Text('$n')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _rowsPerPage = v;
                    _page = 0;
                  });
                },
              ),
              const Spacer(),
              Text(total == 0 ? '0 / 0' : '${start + 1}–$end / $total',
                  style: Theme.of(context).textTheme.bodySmall),
              IconButton(
                tooltip: '上一页',
                icon: const Icon(Icons.chevron_left),
                onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
              ),
              IconButton(
                tooltip: '下一页',
                icon: const Icon(Icons.chevron_right),
                onPressed: page < maxPage
                    ? () => setState(() => _page = page + 1)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
