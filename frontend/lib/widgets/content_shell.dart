import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 内容页列表宽度上限（类比 css max-width）：大屏下内容列不再横向摊满，
/// 避免列表左右分家；窄屏（可用宽度不足 [kContentMinWidth]）退化为整宽。
///
/// 布局：外层 [Stack] 页面把匹配 [widgets/row_list]／[widgets/square_card_grid]
/// 的列表收到目标宽度的方案 → 把整页（含右下角悬浮按钮的 [Stack]）包进本组件，
/// 悬浮按钮即自然跟随内容列右缘。
const double kContentMinWidth = 500;
const double kContentFraction = 0.8;
const double kContentMaxWidth = 1500;

/// 将 [child] 收窄到内容列宽度上限（顶部居中）。
class ContentShell extends StatelessWidget {
  final Widget child;
  const ContentShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final target = math.min(width * kContentFraction, kContentMaxWidth);
    final maxW = target < kContentMinWidth ? width : target;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: math.min(kContentMinWidth, width),
          maxWidth: maxW,
        ),
        child: child,
      ),
    );
  }
}