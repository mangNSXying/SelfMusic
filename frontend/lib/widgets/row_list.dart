import 'package:flutter/material.dart';

/// 内容列表行高（72 高度 ListTile + 1px 分隔线）。
///
/// 全 App 内容列表（歌曲/喜欢/专辑/歌手/源浏览/歌单/播放源/队列）统一走
/// [RowList] 与这两个常量，避免行高/分隔线缩进在各页各写一份。
const double kRowHeight = 72;

/// 列表顶栏总高度：计数头（`CountHeader`）与多选栏（`SelectionBar`）共用，
/// 保证进出多选模式时内容区不跳动。
const double kListHeaderHeight = 44;

/// 行间分隔线高度（计入 [kRowExtent]）。
const double kRowSeparatorHeight = 1;

/// itemExtent：固定行高 + 分隔线，供 Sliver 虚拟化与深位置定位使用。
const double kRowExtent = kRowHeight + kRowSeparatorHeight;

/// 分隔线缩进（与行内 leading 对齐：44 封面 + 左右内边距）。
const double kRowDividerIndent = 72;

/// 固定行高列表外壳：统一 `itemExtent`、末行不带分隔线、可选下拉刷新。
///
/// [itemBuilder] 只负责行本体，分隔线与行高由外壳统一提供。
///
/// **为什么必须固定 itemExtent**：没有它时 Sliver 为定位深处目标需从第 0 行
/// 逐行排到目标行——千首歌单一帧构建 700+ 行与封面，进入必卡（实测 712 项 vs
/// 16 项，见 `playlists_view` 歌单详情注释与 `playlists_view_test` 回归用例）。
class RowList extends StatelessWidget {
  final int count;

  /// 行本体（不含分隔线）。
  final Widget Function(BuildContext context, int index) itemBuilder;

  final ScrollController? controller;

  /// 非空时自动包一层下拉刷新。
  final RefreshCallback? onRefresh;

  /// 行高，默认 [kRowHeight]；分隔线缩进默认 [kRowDividerIndent]。
  final double rowHeight;
  final double dividerIndent;

  const RowList({
    super.key,
    required this.count,
    required this.itemBuilder,
    this.controller,
    this.onRefresh,
    this.rowHeight = kRowHeight,
    this.dividerIndent = kRowDividerIndent,
  });

  @override
  Widget build(BuildContext context) {
    final last = count - 1;
    final list = ListView.builder(
      controller: controller,
      itemExtent: rowHeight + kRowSeparatorHeight,
      itemCount: count,
      itemBuilder: (c, i) => Column(
        children: [
          SizedBox(height: rowHeight, child: itemBuilder(c, i)),
          if (i != last)
            Divider(height: kRowSeparatorHeight, indent: dividerIndent),
        ],
      ),
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}
