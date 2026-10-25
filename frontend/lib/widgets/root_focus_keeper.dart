import 'package:flutter/widgets.dart';

/// 无控件聚焦时 Flutter 会把焦点退到祖先 FocusScope（例如播放页收起、
/// 搜索框失焦）。该 Scope 在应用根 [Focus] 之上，按键不会再冒泡到根节点，
/// 导致窗口快捷键全部失效。此组件在检测到焦点落到根节点的祖先 Scope 时，
/// 把焦点拉回 [focusNode]；输入框、弹窗和 pushed 路由保持自身焦点。
class RootFocusKeeper extends StatefulWidget {
  const RootFocusKeeper({
    super.key,
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  State<RootFocusKeeper> createState() => _RootFocusKeeperState();
}

class _RootFocusKeeperState extends State<RootFocusKeeper> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (_scheduled) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary is! FocusScopeNode) return;
    if (!widget.focusNode.ancestors.contains(primary)) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || widget.focusNode.hasFocus) return;
      final current = FocusManager.instance.primaryFocus;
      if (current is! FocusScopeNode) return;
      if (!widget.focusNode.ancestors.contains(current)) return;
      if (Navigator.maybeOf(context)?.canPop() ?? false) return;
      widget.focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
