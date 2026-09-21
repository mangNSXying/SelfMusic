import 'package:flutter/material.dart';

/// 全 APP 统一按压反馈（改进 B6-U2）：水波纹 + 轻微缩放。
///
/// IconButton / ListTile 保持原生水波纹；自定义大按钮（播放/切歌等）
/// 用此组件，保证"点按有交互感"。用法：
/// ```dart
/// Pressable(onPressed: player.toggle, child: Icon(Icons.play_arrow, size: 40))
/// ```
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;

  /// 按下时的缩放（1.0 = 无缩放）。
  final double pressedScale;
  final String? tooltip;

  const Pressable({
    super.key,
    required this.child,
    required this.onPressed,
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
    this.padding = const EdgeInsets.all(8),
    this.pressedScale = 0.9,
    this.tooltip,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  var _down = false;

  @override
  Widget build(BuildContext context) {
    Widget w = Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: widget.borderRadius,
        onTap: widget.onPressed,
        onHighlightChanged: (v) {
          if (mounted) setState(() => _down = v);
        },
        child: Padding(
          padding: widget.padding,
          child: AnimatedScale(
            scale: _down ? widget.pressedScale : 1.0,
            duration: const Duration(milliseconds: 90),
            child: widget.child,
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    if (tip != null) w = Tooltip(message: tip, child: w);
    return w;
  }
}
