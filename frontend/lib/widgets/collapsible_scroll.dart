import 'package:flutter/material.dart';

/// 可折叠顶栏的内容滚动作用域。
///
/// 内容不足一屏时默认滚动视图不接受拖动（[ScrollPhysics.shouldAcceptUserOffset]
/// 在无滚动余量且位于 0 位时返回 false），顶栏因此永远收不起来。这里让**纵向**
/// 滚动视图始终接受拖动，短内容也能产生 overscroll 通知，供 AppShell 的顶栏
/// 收起判定使用。
///
/// 只包在会启用顶栏收起的内容容器上（六个分组基座、歌单/源内/专辑/歌手详情），
/// 设置页与工具页不套用。横向滚动保持默认物理，避免短横向列表抢走分组横滑手势。
class CollapsibleScroll extends StatelessWidget {
  final Widget child;

  const CollapsibleScroll({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
        behavior: const _CollapsibleScrollBehavior(),
        child: child,
      );
}

class _CollapsibleScrollBehavior extends ScrollBehavior {
  const _CollapsibleScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _VerticalAlwaysScrollable(parent: super.getScrollPhysics(context));
}

/// 仅纵向永远接受拖动的物理；无滚动余量的纵向列表也能被拖动。
class _VerticalAlwaysScrollable extends ScrollPhysics {
  const _VerticalAlwaysScrollable({super.parent});

  @override
  _VerticalAlwaysScrollable applyTo(ScrollPhysics? ancestor) =>
      _VerticalAlwaysScrollable(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      position.axis == Axis.vertical || super.shouldAcceptUserOffset(position);
}
