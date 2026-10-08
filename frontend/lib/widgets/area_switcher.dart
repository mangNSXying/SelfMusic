import 'package:flutter/material.dart';

import '../utils/interaction_gate.dart';

/// 分层区域切换器（滑动模式专用）：底层永远静止，只有高层移动，主荧幕不黑。
///
/// 层级（低→高）：分组区 < 源内/歌单详情 < 设置（播放页为悬浮层，不走这里）。
/// - 进入高层（level 上升或同级）：旧页静止垫底，新页沿 [slideOffset] 移入覆盖；
/// - 离开高层（level 下降）：新页静止垫底，旧页沿 -[slideOffset] 移出显露底层。
/// 底层始终是不透明整页，动画任意时刻都有内容垫底，不会透出窗口黑底。
class AreaSwitcher extends StatefulWidget {
  final String areaKey;
  final int level;
  final Offset slideOffset;
  final Widget child;
  const AreaSwitcher({
    super.key,
    required this.areaKey,
    required this.level,
    required this.slideOffset,
    required this.child,
  });

  @override
  State<AreaSwitcher> createState() => _AreaSwitcherState();
}

class _AreaSwitcherState extends State<AreaSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final CurvedAnimation _curved =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);

  Widget? _prevChild;
  int _prevLevel = 1;
  Widget? _lastChild;
  int _lastLevel = 1;
  bool _flying = false;
  bool _forward = true;
  Offset _offset = const Offset(1, 0);

  /// 交互门控（区域切换动画期间聚合后台数据通知）。
  InteractionGate? _gate;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate = InteractionGate.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    _lastChild = widget.child;
    _lastLevel = widget.level;
    _prevLevel = widget.level;
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() {
          _flying = false;
          _prevChild = null;
        });
        _gate?.setTransitioning(false);
      }
    });
  }

  @override
  void dispose() {
    _gate?.setTransitioning(false);
    _curved.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AreaSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.areaKey != oldWidget.areaKey) {
      // 飞行中再次切换：以上次目标页为旧层（静态呈现，轻微跳变可接受）。
      _prevChild = _lastChild;
      _prevLevel = _lastLevel;
      _lastChild = widget.child;
      _lastLevel = widget.level;
      _forward = widget.level >= _prevLevel;
      _offset = widget.slideOffset;
      _flying = true;
      _gate?.setTransitioning(true);
      _ctrl.forward(from: 0);
    } else {
      _lastChild = widget.child;
      _lastLevel = widget.level;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_flying || _prevChild == null) return widget.child;
    // 遮罩（改进 B6-U8）：滑动中新页/旧页衬不透明底，避免两页内容重叠透视。
    final bg = Theme.of(context).scaffoldBackgroundColor;
    // 图层策略（T013）：把整段切换合成包进 RepaintBoundary，隔离两页平移对
    // 其余内容的重栅格化影响。当前环境无真机实测，属保守、无回归处理：
    // 未改变层数/透明度/动画曲线；若 Phase 5 实测表明 Raster 线程主导，
    // 再据此评估收敛双页合成层数与过度绘制（见 baseline.md）。
    if (_forward) {
      return RepaintBoundary(
        child: Stack(
          children: [
            Positioned.fill(child: RepaintBoundary(child: _prevChild!)),
            Positioned.fill(
              child: RepaintBoundary(
                child: SlideTransition(
                  position: Tween<Offset>(begin: _offset, end: Offset.zero)
                      .animate(_curved),
                  child: ColoredBox(color: bg, child: widget.child),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RepaintBoundary(
      child: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: widget.child)),
          Positioned.fill(
            child: RepaintBoundary(
              child: SlideTransition(
                position: Tween<Offset>(begin: Offset.zero, end: -_offset)
                    .animate(_curved),
                child: ColoredBox(color: bg, child: _prevChild!),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
