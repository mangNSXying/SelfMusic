import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';

/// 内容页工具条统一图标按钮：固定 [kToolbarButtonSize] 见方、图标
/// [kToolbarIconSize]，tooltip 必填。
///
/// 用于计数栏右侧的排序/分类/视图、队列页动作、弹层关闭等。AppBar 的
/// 页面级动作仍用原生 [IconButton]（48 命中区），两者不要混用。
class ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 激活态/破坏性操作用色；为空时跟随主题默认（onSurfaceVariant）。
  final Color? color;

  const ToolbarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scale = appUiScaleOf(context);
    return IconButton(
      icon: Icon(icon, size: kToolbarIconSize * scale),
      tooltip: tooltip,
      onPressed: onPressed,
      color: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints.tightFor(
        width: kToolbarButtonSize * scale,
        height: kToolbarButtonSize * scale,
      ),
    );
  }
}

/// 工具条里的弹出菜单按钮：视觉规格与 [ToolbarIconButton] 一致。
class ToolbarPopupMenuButton<T> extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final List<PopupMenuEntry<T>> Function(BuildContext) itemBuilder;
  final ValueChanged<T>? onSelected;
  final Color? color;

  const ToolbarPopupMenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    this.onSelected,
    this.color,
    this.menuColor,
    this.menuShape,
    this.menuPosition,
  });

  /// 菜单底色/圆角；为空时用 [PopupMenuButton] 的主题默认值。
  final Color? menuColor;
  final ShapeBorder? menuShape;

  /// 菜单相对按钮的弹出方向；为空时用 [PopupMenuButton] 的默认（覆盖按钮）。
  final PopupMenuPosition? menuPosition;

  @override
  Widget build(BuildContext context) {
    final scale = appUiScaleOf(context);
    return PopupMenuButton<T>(
      icon: Icon(icon, size: kToolbarIconSize * scale, color: color),
      tooltip: tooltip,
      iconSize: kToolbarIconSize * scale,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        fixedSize: Size(
          kToolbarButtonSize * scale,
          kToolbarButtonSize * scale,
        ),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelected: onSelected,
      itemBuilder: itemBuilder,
      color: menuColor,
      shape: menuShape,
      position: menuPosition,
    );
  }
}
