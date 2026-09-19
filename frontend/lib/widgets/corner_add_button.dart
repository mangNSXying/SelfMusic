import 'package:flutter/material.dart';

/// 页面右下角圆角矩形「+」号按钮（播放列表/喜欢/播放源统一新建入口）。
///
/// 配合 Stack + Positioned(right: 16, bottom: 16) 使用。
class CornerAddButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;
  const CornerAddButton({super.key, required this.onPressed, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Icon(Icons.add, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}
