import 'package:flutter/material.dart';

import 'section_swipe.dart';

/// 详情呈现形态（窄屏拖拽弹层由页面入口自行分流，不在这里）。
///
/// - [page]：整页子视图（歌单详情 / 源内浏览），保留分组横滑；
/// - [pane]：大横屏分栏右栏，不包 [SectionSwipe]（横滑属于外层分组 Pager，
///   栏内再套一层会抢手势）；
/// - [overlay]：宽屏整页叠层（专辑/歌手详情），盖在分组列表之上。
enum DetailPresentation { page, pane, overlay }

/// 详情页外壳：只决定「包不包分组横滑 / 画不画不透明底」，页面本体与数据
/// 快照语义不变。[pane] 与 [overlay] 都自绘不透明底，换详情时的过渡不会
/// 透出上一个页面/详情。
class DetailPresentationShell extends StatelessWidget {
  const DetailPresentationShell({
    super.key,
    required this.presentation,
    required this.child,
  });

  final DetailPresentation presentation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (presentation == DetailPresentation.page) {
      return SectionSwipe(child: child);
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: child,
    );
  }
}
