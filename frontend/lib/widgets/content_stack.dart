import 'package:flutter/material.dart';

import '../data/local/app_settings.dart';
import '../providers/navigation_provider.dart';
import '../utils/motion.dart';
import 'page_transition.dart';

/// 内容区栈：常驻基座（六分组 Pager）+ 内容路由层（设置/歌单/源内/详情/歌曲信息）。
///
/// - [base] 常驻：打开/返回详情都不卸载底层分组页（滚动位置、筛选、选择状态
///   原样保留）；内容页只是叠在它上面的一层；
/// - 内容页懒构建：只有真正进入栈的层才构建，出栈动画结束后立即销毁；
/// - 被盖住的层 `Offstage` + `TickerMode(false)`：不绘制、不跑动画、不进语义树；
/// - 进/出沿用全局「页面切换」设置（[pageTransition]），静止时只保留最上层；
/// - 设置分区同层替换时用固定 Key，交给页面内部的切换器做分区动画。
class ContentStack extends StatefulWidget {
  const ContentStack({
    super.key,
    required this.base,
    required this.routes,
    required this.builder,
    required this.transition,
    required this.baseKey,
  });

  /// 底层常驻页（分组 Pager）。
  final Widget base;

  /// 内容栈（底 → 顶），由 [NavigationProvider.contentRoutes] 驱动。
  final List<ContentRoute> routes;

  /// 按路由构建内容页（懒构建；每层只在自己的 State 里缓存数据）。
  final Widget Function(BuildContext context, ContentRoute route) builder;

  /// 全局页面切换动画档位。
  final PlayerTransition transition;

  /// 底层页标识（分组 + 分栏/整页）：变化说明用户切走了分组/呈现形态，
  /// 内容层直接消失（不播退场动画），避免残留到新区域。
  final String baseKey;

  @override
  State<ContentStack> createState() => _ContentStackState();
}

class _ContentStackState extends State<ContentStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: kPageMotion,
    value: 1,
  );
  late final CurvedAnimation _curved =
      CurvedAnimation(parent: _ctrl, curve: kPageMotionCurve);

  /// 正在退场的层（已从栈里移除；退场动画结束后销毁）。
  ContentRoute? _exiting;
  int? _exitingIndex;
  bool _flying = false;

  static const Offset _offset = Offset(1, 0);
  static const Key _baseKey = ValueKey<String>('content-stack-base');

  /// 设置分区之间是同层替换：同一栈位的 Key 固定，分区动画由页面内部处理。
  Key _layerKey(ContentRoute route, int index) => route is SettingsRoute
      ? ValueKey<String>('content-settings-$index')
      : ObjectKey(route);

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
    setState(() {
      _flying = false;
      _exiting = null;
      _exitingIndex = null;
    });
  }

  @override
  void didUpdateWidget(ContentStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLen = oldWidget.routes.length;
    final newLen = widget.routes.length;
    if (newLen == oldLen && widget.baseKey == oldWidget.baseKey) return;

    // 单步进出才做动画；区域切换/连点/同深度替换直接定格。
    final canAnimate = !_flying &&
        widget.baseKey == oldWidget.baseKey &&
        widget.transition != PlayerTransition.none &&
        (newLen == oldLen + 1 || newLen == oldLen - 1);
    _ctrl.stop();
    if (!canAnimate) {
      _flying = false;
      _exiting = null;
      _exitingIndex = null;
      _ctrl.value = 1;
      return;
    }
    if (newLen > oldLen) {
      _exiting = null;
      _exitingIndex = null;
      _flying = true;
      _ctrl.forward(from: 0);
    } else {
      _exiting = oldWidget.routes.last;
      _exitingIndex = oldWidget.routes.length - 1;
      _flying = true;
      _ctrl.reverse(from: 1);
    }
  }

  Widget _layer(BuildContext context, ContentRoute route) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: widget.builder(context, route),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exiting = _exiting;
    final entries = <(Key, Widget)>[
      (_baseKey, widget.base),
      for (var i = 0; i < widget.routes.length; i++)
        (_layerKey(widget.routes[i], i), _layer(context, widget.routes[i])),
      if (exiting != null)
        (
          _layerKey(exiting, _exitingIndex ?? widget.routes.length),
          _layer(context, exiting)
        ),
    ];
    final top = entries.length - 1;
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final (key, page) = entries[i];
      Widget layer = page;
      if (_flying && i == top) {
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
      final visible = _flying || i == top;
      children.add(Positioned.fill(
        key: key,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(enabled: visible, child: layer),
        ),
      ));
    }
    return IgnorePointer(
      ignoring: _flying,
      child: Stack(fit: StackFit.expand, children: children),
    );
  }
}
