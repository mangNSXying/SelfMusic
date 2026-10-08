import 'package:flutter/material.dart';

/// 单行文本，超长时自动横向滚动（marquee）替代折行/省略：
/// - 不超长：按普通单行文本渲染；
/// - 超长：横向来回滚动显示完整文本，点击可暂停/继续；
/// - 始终单行，避免长标题/长歌词折行挤占纵向空间。
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  /// 单程滚动时长（超长文本按长度自适应放大）。
  final Duration baseDuration;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.baseDuration = const Duration(milliseconds: 6000),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.baseDuration);
  }

  @override
  void didUpdateWidget(covariant MarqueeText old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text) {
      _ctrl
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _startIfNeeded(double overflow) {
    if (overflow > 0.5 && _running && !_ctrl.isAnimating) {
      final ratio = (overflow + _gap) / 200;
      _ctrl.duration = widget.baseDuration * ratio.clamp(1.0, 4.0);
      _ctrl.repeat(reverse: true);
    }
  }

  double get _gap => 28.0;

  @override
  Widget build(BuildContext context) {
    // R-4 按需运行：宿主处于 TickerMode 关闭态（路由不可见/被覆盖/后台）时
    // 停表，避免无限 repeat 使引擎无法进入空闲、与滚动/过渡叠加时每帧成本翻倍。
    // 保留 TickerMode.of：stable 3.47 虽标记弃用（建议 valuesOf），但 ohos 分支
    // 工具链 3.41.9 无 valuesOf，须双 SDK 兼容（同 lyrics_view 的 cacheExtent 口径）。
    // ignore: deprecated_member_use
    final tickerEnabled = TickerMode.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final maxW = constraints.maxWidth;
      final overflow = tp.width - maxW;

      if (overflow <= 0.5) {
        _ctrl
          ..stop()
          ..value = 0;
        return Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: widget.textAlign,
        );
      }

      if (tickerEnabled) {
        _startIfNeeded(overflow);
      } else {
        _ctrl.stop();
      }

      return ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            setState(() {
              _running = !_running;
              if (_running) {
                _startIfNeeded(overflow);
              } else {
                _ctrl.stop();
              }
            });
          },
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              final shift = -(overflow + _gap) * _ctrl.value;
              return SizedBox(
                height: tp.height,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Transform.translate(
                        offset: Offset(shift, 0),
                        child: Text(
                          widget.text,
                          style: widget.style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    });
  }
}