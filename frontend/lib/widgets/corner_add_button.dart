import 'package:flutter/material.dart';

/// 页面右下角圆角矩形悬浮按钮（歌单/喜欢/播放源的新建入口，歌手页的重新解析入口）。
///
/// 配合 Stack + Positioned(right: 16, bottom: 16) 使用。
/// [icon] / [label] 可换：不给 [label] 时就是纯图标（原来的「+」号）。
class CornerAddButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;
  final String? label;
  const CornerAddButton({
    super.key,
    required this.onPressed,
    required this.tooltip,
    this.icon = Icons.add,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = label;
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: text == null
                ? Icon(icon, color: Colors.white, size: 26)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 22),
                      const SizedBox(width: 8),
                      Text(text,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}