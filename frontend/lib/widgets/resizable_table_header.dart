import 'package:flutter/material.dart';

import 'table_columns.dart';

/// 通用表头：标题、排序箭头、可拖拽的列分隔线。
///
/// 列宽全部按 [weights] 的 flex 比例随可用宽度自适应；用户拖动分隔线时只在
/// 相邻两列之间转移权重（总权重不变），因此窗口/文件夹块变窄时仍等比缩放。
/// 双击分隔线恢复默认权重。
///
/// 行单元格由页面用 [TableColumnLayout.buildCells] 渲染，两边共用同一份
/// [columns]/[weights]，列才不会漂移。
class ResizableTableHeader extends StatelessWidget {
  final List<TableColumnSpec> columns;
  final List<double> weights;

  /// 当前排序列（null = 无排序列）；只影响箭头与强调色。
  final int? sortIndex;
  final bool sortDescending;

  /// 点击可排序列；由页面决定升/降/循环语义。
  final ValueChanged<int>? onSortColumn;

  /// 拖拽中的实时权重（用于页面 setState 重绘）。
  final ValueChanged<List<double>>? onWeightsChanged;

  /// 拖拽结束/双击恢复时提交权重（用于持久化）。
  final ValueChanged<List<double>>? onWeightsCommitted;

  /// 双击分隔线：恢复默认列宽。
  final VoidCallback? onResetWeights;

  final double height;
  final EdgeInsetsGeometry padding;
  final Color? background;

  const ResizableTableHeader({
    super.key,
    required this.columns,
    required this.weights,
    this.sortIndex,
    this.sortDescending = false,
    this.onSortColumn,
    this.onWeightsChanged,
    this.onWeightsCommitted,
    this.onResetWeights,
    this.height = 32,
    this.padding = EdgeInsets.zero,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    final draggable = onWeightsChanged != null && columns.length > 1;

    Widget cell(int i) {
      final spec = columns[i];
      final active = sortIndex == i;
      final label = active ? '${spec.label} ${sortDescending ? '↓' : '↑'}' : spec.label;
      final content = Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: spec.align,
        style: baseStyle?.copyWith(
          color: active ? cs.primary : cs.onSurfaceVariant,
        ),
      );
      final body = spec.sortable && onSortColumn != null
          ? InkWell(
              onTap: () => onSortColumn!(i),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: content,
              ),
            )
          : content;
      return Expanded(
        flex: tableColumnFlex(weights[i]),
        child: spec.rightPadding == 0
            ? body
            : Padding(
                padding: EdgeInsets.only(right: spec.rightPadding),
                child: body,
              ),
      );
    }

    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? Theme.of(context).scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = constraints.maxWidth;
          final row = Row(children: [for (var i = 0; i < columns.length; i++) cell(i)]);
          if (!draggable || contentWidth <= 0) return row;
          final total = weights.fold<double>(0, (a, b) => a + b);
          if (total <= 0) return row;
          final boundaries = <double>[];
          var acc = 0.0;
          for (var i = 0; i < columns.length - 1; i++) {
            acc += contentWidth * weights[i] / total;
            boundaries.add(acc);
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              row,
              for (var i = 0; i < boundaries.length; i++)
                Positioned(
                  left: boundaries[i] - 4,
                  top: 0,
                  bottom: 0,
                  width: 8,
                  child: _ResizeHandle(
                    key: ValueKey('table-resize-${columns[i].id}'),
                    columns: columns,
                    weights: weights,
                    dividerIndex: i,
                    contentWidth: contentWidth,
                    onChanged: onWeightsChanged!,
                    onCommitted: onWeightsCommitted,
                    onReset: onResetWeights,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  final List<TableColumnSpec> columns;
  final List<double> weights;
  final int dividerIndex;
  final double contentWidth;
  final ValueChanged<List<double>> onChanged;
  final ValueChanged<List<double>>? onCommitted;
  final VoidCallback? onReset;

  const _ResizeHandle({
    super.key,
    required this.columns,
    required this.weights,
    required this.dividerIndex,
    required this.contentWidth,
    required this.onChanged,
    this.onCommitted,
    this.onReset,
  });

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  late List<double> _latest = widget.weights;

  @override
  void didUpdateWidget(covariant _ResizeHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _latest = widget.weights;
  }

  void _onDrag(DragUpdateDetails d) {
    final next = resizeTableWeights(
      columns: widget.columns,
      weights: _latest,
      dividerIndex: widget.dividerIndex,
      deltaPixels: d.delta.dx,
      contentWidth: widget.contentWidth,
    );
    if (identical(next, _latest)) return;
    _latest = next;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: _onDrag,
        onHorizontalDragEnd: (_) => widget.onCommitted?.call(_latest),
        onDoubleTap: widget.onReset,
        child: Center(
          child: Container(
            width: 1,
            color: cs.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
