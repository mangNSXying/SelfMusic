import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';

/// 列表行、设置行、单选行右侧的紧凑图标按钮。
///
/// 右侧动作不是页面主操作，统一收窄到 [kRowActionButtonSize] 见方、图标
/// [kRowActionIconSize]，避免多个动作并排时挤占标题/副标题宽度。页面级
/// AppBar 动作仍用原生 [IconButton]（48 命中区），不要混用。
class RowActionIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  const RowActionIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: kRowActionIconSize),
      tooltip: tooltip,
      onPressed: onPressed,
      color: color,
      padding: EdgeInsets.zero,
      splashRadius: kRowActionButtonSize / 2,
      constraints: const BoxConstraints.tightFor(
        width: kRowActionButtonSize,
        height: kRowActionButtonSize,
      ),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 列表行、设置行右侧的紧凑文字按钮（如「设置」「选择」）。
///
/// 标准按钮高度 40 会把副标题行撑高；这里压到
/// [kRowActionTextButtonHeight]，字号 13，保持与行内文字同一密度。
class RowActionTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  const RowActionTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, kRowActionTextButtonHeight),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: color,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}
