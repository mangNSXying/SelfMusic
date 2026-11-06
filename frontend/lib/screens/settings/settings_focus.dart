import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 设置项定位锚点 ID：分区名 + 条目名，搜索索引与锚点共用同一口径。
String settingsAnchorId(SettingsItem section, String label) =>
    '${section.name}/$label';

/// 设置搜索的定位请求：由侧栏发起，目标分区里的锚点消费。
class SettingsFocusController {
  final ValueNotifier<String?> pending = ValueNotifier<String?>(null);
  final ValueNotifier<String?> highlight = ValueNotifier<String?>(null);
  Timer? _pendingTimer;
  Timer? _highlightTimer;

  void request(String id) {
    _pendingTimer?.cancel();
    pending.value = id;
    _pendingTimer = Timer(const Duration(seconds: 2), () {
      if (pending.value == id) pending.value = null;
    });
  }

  void consume(String id) {
    if (pending.value != id) return;
    _pendingTimer?.cancel();
    pending.value = null;
    highlight.value = id;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (highlight.value == id) highlight.value = null;
    });
  }

  void clear() {
    _pendingTimer?.cancel();
    _highlightTimer?.cancel();
    pending.value = null;
    highlight.value = null;
  }

  void dispose() {
    _pendingTimer?.cancel();
    _highlightTimer?.cancel();
    pending.dispose();
    highlight.dispose();
  }
}

/// 把控制器放进子树；没有 Scope 时锚点退化为普通布局（测试可省略）。
class SettingsFocusScope extends InheritedWidget {
  const SettingsFocusScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SettingsFocusController controller;

  static SettingsFocusController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsFocusScope>()
      ?.controller;

  /// 事件回调里读取，不建立依赖。
  static SettingsFocusController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsFocusScope>()?.controller;

  @override
  bool updateShouldNotify(SettingsFocusScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 可被搜索定位的设置项包装：滚动到可见 + 短暂高亮。
class SettingsFocusAnchor extends StatefulWidget {
  const SettingsFocusAnchor({
    super.key,
    required this.id,
    required this.child,
  });

  final String id;
  final Widget child;

  @override
  State<SettingsFocusAnchor> createState() => _SettingsFocusAnchorState();
}

class _SettingsFocusAnchorState extends State<SettingsFocusAnchor> {
  final GlobalKey _anchorKey = GlobalKey();
  SettingsFocusController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = SettingsFocusScope.maybeOf(context);
    if (identical(next, _controller)) return;
    _controller?.pending.removeListener(_onPending);
    _controller = next;
    _controller?.pending.addListener(_onPending);
    _onPending();
  }

  void _onPending() {
    final controller = _controller;
    if (controller == null || controller.pending.value != widget.id) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller.pending.value != widget.id) return;
      final target = _anchorKey.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.28,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      controller.consume(widget.id);
    });
    // 设置页可能处于静止状态（无动画/滚动），addPostFrameCallback 本身不排帧；
    // 不主动排一帧，回调会一直等不到下一次绘制。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _controller?.pending.removeListener(_onPending);
    super.dispose();
  }

  Widget _wrap(Widget child) => KeyedSubtree(
        key: ValueKey<String>('settings-anchor:${widget.id}'),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final controller = SettingsFocusScope.maybeOf(context);
    if (controller == null) {
      return _wrap(KeyedSubtree(key: _anchorKey, child: widget.child));
    }
    return _wrap(
      ValueListenableBuilder<String?>(
        valueListenable: controller.highlight,
        child: widget.child,
        builder: (context, highlighted, child) {
          final active = highlighted == widget.id;
          return AnimatedContainer(
            key: _anchorKey,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          );
        },
      ),
    );
  }
}
