import 'package:flutter/material.dart';

/// 一列表格的定义（歌曲表 / 播放数据 / 元数据表共用）。
///
/// [defaultWeight] 是自适应布局下的相对权重；[minWeight] 是拖拽/缩放的
/// 下限，避免把手调成 0 宽；[rightPadding] 与行内单元格保持一致，
/// 表头与行才能逐列对齐。
@immutable
class TableColumnSpec {
  final String id;
  final String label;
  final double defaultWeight;
  final double minWeight;
  final TextAlign align;
  final double rightPadding;
  final bool sortable;

  const TableColumnSpec({
    required this.id,
    required this.label,
    required this.defaultWeight,
    this.minWeight = 24,
    this.align = TextAlign.left,
    this.rightPadding = 8,
    this.sortable = false,
  });
}

/// 默认列权重。
List<double> defaultTableWeights(List<TableColumnSpec> columns) =>
    [for (final c in columns) c.defaultWeight];

/// 读取持久化权重：列数不符/非法值回退默认；低于下限的钳到下限。
List<double> sanitizeTableWeights(
    List<TableColumnSpec> columns, List<double>? stored) {
  if (stored == null || stored.length != columns.length) {
    return defaultTableWeights(columns);
  }
  final out = <double>[];
  for (var i = 0; i < columns.length; i++) {
    final w = stored[i];
    if (!w.isFinite || w <= 0) return defaultTableWeights(columns);
    out.add(w < columns[i].minWeight ? columns[i].minWeight : w);
  }
  return out;
}

/// flex 只收整数：把权重放大 10 倍换取足够分辨率（1/10 权重 ≈ 亚像素级）。
int tableColumnFlex(double weight) => (weight * 10).round().clamp(1, 1 << 20);

/// 拖拽分隔线：把像素位移换算成权重，在相邻两列之间转移。
///
/// 返回新权重列表（总权重不变）；触到任一列下限时返回原列表（本次不动）。
List<double> resizeTableWeights({
  required List<TableColumnSpec> columns,
  required List<double> weights,
  required int dividerIndex,
  required double deltaPixels,
  required double contentWidth,
}) {
  if (dividerIndex < 0 ||
      dividerIndex >= columns.length - 1 ||
      contentWidth <= 0 ||
      weights.length != columns.length) {
    return weights;
  }
  final total = weights.fold<double>(0, (a, b) => a + b);
  if (total <= 0) return weights;
  final delta = deltaPixels / contentWidth * total;
  var left = weights[dividerIndex] + delta;
  var right = weights[dividerIndex + 1] - delta;
  final minLeft = columns[dividerIndex].minWeight;
  final minRight = columns[dividerIndex + 1].minWeight;
  if (left < minLeft) {
    right -= minLeft - left;
    left = minLeft;
  }
  if (right < minRight) {
    left -= minRight - right;
    right = minRight;
  }
  if (left < minLeft || right < minRight) return weights;
  final next = List<double>.of(weights);
  next[dividerIndex] = left;
  next[dividerIndex + 1] = right;
  return next;
}

/// 列几何：行与表头必须共用同一份 `buildCells`，宽度才不会漂移。
@immutable
class TableColumnLayout {
  const TableColumnLayout(this.columns, this.weights)
      : assert(columns.length == weights.length);

  final List<TableColumnSpec> columns;
  final List<double> weights;

  Widget buildCells(List<Widget> cells) {
    assert(cells.length == columns.length);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < columns.length; i++)
          Expanded(
            flex: tableColumnFlex(weights[i]),
            child: columns[i].rightPadding == 0
                ? cells[i]
                : Padding(
                    padding: EdgeInsets.only(right: columns[i].rightPadding),
                    child: cells[i],
                  ),
          ),
      ],
    );
  }
}
