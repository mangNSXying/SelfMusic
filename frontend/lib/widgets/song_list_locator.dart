import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'row_list.dart';

/// 歌曲列表「定位当前曲」的统一滚动口径：目标行顶边落在列表顶栏下方
/// [margin] 处，越界交给滚动位置钳位。
///
/// 各页只负责把「当前曲」映射成行号 / 行顶边在滚动空间中的偏移：
/// - 统计栏在滚动区外（歌曲列表、宽屏队列侧板）：[coveredTop] 传 0；
/// - 置顶标题栏在滚动区内（队列弹层、专辑/歌手详情）：行顶边要加上它之前
///   的滚动距离，[coveredTop] 传标题栏高度。
///
/// 触发时机/失败重试统一由 `CurrentSongFocusController` 负责，本类只做几何计算。
class SongListLocator {
  /// 目标行顶边距列表可视区顶部的距离（各列表统一视觉口径）。
  static const double margin = 96;

  /// 第 [row] 行顶边的滚动偏移（固定行高列表，供 initialScrollOffset 用）。
  static double offsetForRow(
    int row, {
    double rowExtent = kRowExtent,
    double coveredTop = 0,
  }) =>
      offsetFor(row, rowExtent: rowExtent, coveredTop: coveredTop);

  /// 统一的行偏移口径：[offsetForRow] 与 [jumpTo]/[jumpToRow] 共用同一套数学。
  static double offsetFor(
    int row, {
    double rowExtent = kRowExtent,
    double coveredTop = 0,
  }) =>
      math.max(0.0, row * rowExtent - coveredTop - margin);

  /// 跳到 [rowTop]（行顶边在滚动空间中的偏移），并让出置顶栏 [coveredTop]。
  static void jumpTo(
    ScrollController ctrl, {
    required double rowTop,
    double coveredTop = 0,
  }) {
    tryJump(ctrl, rowTop: rowTop, coveredTop: coveredTop);
  }

  /// 同 [jumpTo]，但返回是否真的完成了滚动。
  ///
  /// 布局未就绪（无 clients / 尚无内容尺寸）时返回 false，且**不做任何动作**；
  /// 调用方（`CurrentSongFocusController`）据此保留 pending 并在度量就绪后重试。
  static bool tryJump(
    ScrollController ctrl, {
    required double rowTop,
    double coveredTop = 0,
  }) {
    if (!ctrl.hasClients) return false;
    final position = ctrl.position;
    if (!position.hasContentDimensions) return false;
    ctrl.jumpTo(
        (rowTop - coveredTop - margin).clamp(0.0, position.maxScrollExtent));
    return true;
  }

  /// 固定行高列表的便捷入口。
  static void jumpToRow(
    ScrollController ctrl,
    int row, {
    double rowExtent = kRowExtent,
    double coveredTop = 0,
  }) =>
      jumpTo(ctrl, rowTop: row * rowExtent, coveredTop: coveredTop);

  /// 该 sliver 之前已占用的滚动距离（置顶标题栏 / 附加区 / 表格表头）；
  /// 未布局或不是 sliver 时返回 0。
  static double precedingExtentOf(BuildContext? context) {
    final ro = context?.findRenderObject();
    return ro is RenderSliver ? ro.constraints.precedingScrollExtent : 0.0;
  }
}
