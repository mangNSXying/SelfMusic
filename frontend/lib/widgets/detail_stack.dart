import 'package:flutter/material.dart';

import '../data/local/app_settings.dart';
import '../providers/navigation_provider.dart';
import '../utils/motion.dart';
import 'page_transition.dart';

/// 内容区详情叠层（宽屏整页详情：专辑/歌手）。
///
/// 设计口径（方案 D：窄屏弹层不动，宽屏内容区整页）：
/// - [base] 常驻：打开/返回详情都不卸载底层分组页（滚动位置、筛选、选择状态
///   原样保留）；详情页只是叠在它上面的一层；
/// - 详情页懒构建：只有真正进入栈的层才构建，出栈动画结束后立即销毁（不缓存）；
/// - 被盖住的层 `Offstage` + `TickerMode(false)`：不绘制、不跑动画、不进语义树；
/// - 进/出沿用全局「页面切换」设置（[pageTransition]），静止时只保留最上层。
class DetailStack extends StatefulWidget {
  const DetailStack({
    super.key,
    required this.base,
    required this.routes,
    required this.builder,
    required this.transition,
    required this.baseKey,
  });

  /// 底层常驻页（分组 Pager）。
  final Widget base;

  /// 详情栈（底 → 顶），由 [NavigationProvider.details] 驱动。
  final List<DetailRoute> routes;

  /// 按路由构建详情页（懒构建；每层只在自己的 State 里缓存数据）。
  final Widget Function(BuildContext context, DetailRoute route) builder;

  /// 全局页面切换动画档位。
  final PlayerTransition transition;

  /// 底层页标识（区域键 + 分组名）：变化说明用户切走了分组/区域，详情层
  /// 直接消失（不播退场动画，交给区域切换动画），避免新区域上残留旧详情。
  final String baseKey;

  @override
  State<DetailStack> createState() => _DetailStackState();
}

class _DetailStackState extends State<DetailStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: kPageMotion,
    value: 1,
  );
  late final CurvedAnimation _curved =
      CurvedAnimation(parent: _ctrl, curve: kPageMotionCurve);

  /// 正在退场的详情（已从栈里移除；退场动画结束后销毁）。
  DetailRoute? _exiting;
  bool _flying = false;

  /// 详情页统一从右侧进入、向右侧退出（前进/返回的标准方向）。
  static const Offset _offset = Offset(1, 0);

  static const Key _baseKey = ValueKey<String>('detail-stack-base');

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _curved.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (!_flying) return;
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    // 进场结束：只保留顶层可见；退场结束：移出退场页（State 随之销毁）。
    setState(() {
      _flying = false;
      _exiting = null;
    });
  }

  @override
  void didUpdateWidget(DetailStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLen = oldWidget.routes.length;
    final newLen = widget.routes.length;
    if (newLen == oldLen && widget.baseKey == oldWidget.baseKey) return;

    // 单步进出才做动画；区域切换/连点/两层裁剪（同深度替换）直接定格。
    final canAnimate = !_flying &&
        widget.baseKey == oldWidget.baseKey &&
        widget.transition != PlayerTransition.none &&
        (newLen == oldLen + 1 || newLen == oldLen - 1);
    _ctrl.stop();
    if (!canAnimate) {
      _flying = false;
      _exiting = null;
      _ctrl.value = 1;
      return;
    }
    if (newLen > oldLen) {
      _exiting = null;
      _flying = true;
      _ctrl.forward(from: 0);
    } else {
      _exiting = oldWidget.routes.last;
      _flying = true;
      _ctrl.reverse(from: 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 层（底 → 顶）：底层页 + 栈内详情 + 正在退场的详情。
    // 用每层自己的对象做 Key：裁剪/替换时按"层"复用 State，而不是按位置错配
    //（否则同类型歌手页会拿上一位歌手的缓存数据）。
    final exiting = _exiting;
    final entries = <(Key, Widget)>[
      (_baseKey, widget.base),
      for (final route in widget.routes)
        (ObjectKey(route), widget.builder(context, route)),
      if (exiting != null)
        (ObjectKey(exiting), widget.builder(context, exiting)),
    ];
    final top = entries.length - 1;
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final (key, page) = entries[i];
      Widget layer = page;
      if (_flying && i == top) {
        // 只重建过渡壳，页面子树走 child 参数不重建。
        layer = AnimatedBuilder(
          animation: _curved,
          child: layer,
          builder: (context, child) => pageTransition(
            widget.transition,
            child!,
            _curved,
            slideOffset: _offset,
          ),
        );
      }
      // 静止时只亮最上层；动画期间全亮（下滑/淡入需要露出下层垫底）。
      final visible = _flying || i == top;
      children.add(Positioned.fill(
        key: key,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(enabled: visible, child: layer),
        ),
      ));
    }
    // 过渡期间屏蔽点击，避免半开状态误触下层。
    return IgnorePointer(
      ignoring: _flying,
      child: Stack(fit: StackFit.expand, children: children),
    );
  }
}
