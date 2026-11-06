import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';

/// 页面右下角圆角矩形悬浮按钮（歌单/喜欢/播放源的新建入口，歌手页的重新解析入口）。
///
/// 配合 [CornerFabLayer] 使用（定位与滚动显隐由它统一负责）。
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
    final radius = BorderRadius.circular(kButtonRadius);
    return Material(
      color: scheme.primary,
      borderRadius: radius,
      elevation: 4,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: text == null
                ? Icon(icon, color: scheme.onPrimary, size: 26)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: scheme.onPrimary, size: 22),
                      const SizedBox(width: 8),
                      Text(text,
                          style: TextStyle(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 右下角悬浮按钮的滚动感知层（内容 + 右下角按钮的统一外壳）。
///
/// 直接替换页面里的 `Stack + Positioned(right: 16, bottom: 16, child: 按钮)`：
/// [content] 放页面内容（含可滚动列表），[fab] 放按钮本体（如 [CornerAddButton]）。
///
/// 显隐口径：向下浏览（内容上推、滚动位置增大）时按钮下滑淡出，向上浏览时
/// 滑回；停手保持当前状态。只跟随纵向滚动，分组横滑 / 播放页 PageView 等
/// 横向翻页不触发。
class CornerFabLayer extends StatefulWidget {
  /// 页面内容（其内部的滚动通知冒泡到本层）。
  final Widget content;

  /// 右下角按钮本体（定位由本层负责，不要再自己包 Positioned）。
  final Widget fab;

  /// 单向滚动累计超过该像素才切换显隐，滤掉触摸抖动与边缘回弹。
  final double threshold;

  const CornerFabLayer({
    super.key,
    required this.content,
    required this.fab,
    this.threshold = 8,
  });

  @override
  State<CornerFabLayer> createState() => _CornerFabLayerState();
}

class _CornerFabLayerState extends State<CornerFabLayer> {
  static const Duration _motion = Duration(milliseconds: 180);

  /// 按钮当前是否收起（最近一次定向滚动为向下）；停手后保持。
  bool _hidden = false;

  /// 单向滚动累计量：换向即清零，走满 [CornerFabLayer.threshold] 才切换，
  /// 慢速轻扫不会把按钮抖出来。
  double _travel = 0;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification) {
      _travel = 0;
      return false;
    }
    if (n is! ScrollUpdateNotification) return false;
    // 正向 = 位置增大 = 向下浏览（看后面的内容）。
    final delta = n.scrollDelta ?? 0;
    if (delta == 0) return false;
    if ((delta > 0) != (_travel > 0)) _travel = 0;
    _travel += delta;
    if (!_hidden && _travel > widget.threshold) {
      setState(() => _hidden = true);
    } else if (_hidden && _travel < -widget.threshold) {
      setState(() => _hidden = false);
    }
    // 不拦截：外层（AppShell 交互门控）仍要吃滚动通知。
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.content,
          Positioned(
            right: 16,
            bottom: 16,
            child: IgnorePointer(
              ignoring: _hidden,
              child: ExcludeFocus(
                excluding: _hidden,
                child: AnimatedSlide(
                  offset: _hidden ? const Offset(0, 1.4) : Offset.zero,
                  duration: _motion,
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _hidden ? 0 : 1,
                    duration: _motion,
                    child: widget.fab,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
