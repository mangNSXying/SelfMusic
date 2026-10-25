import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../utils/interaction_gate.dart';
import '../utils/motion.dart';
import '../widgets/draggable_sheet.dart';
import 'sidebar.dart';
import 'top_bar.dart';
import 'queue_panel.dart';
import 'mini_player_bar.dart';

/// 布局壳：桌面 = [侧边栏 | 顶栏+内容 | 队列面板]，窄屏 = 抽屉 + 顶栏。
///
/// 宽屏侧边栏/右队列面板伸缩与全场页面动效统一 300ms（[kPageMotion]）；
/// 窄屏抽屉走框架默认 246ms（无对外配置口，暂保持）。
class AppShell extends StatefulWidget {
  /// 主内容区。
  final Widget content;
  const AppShell({super.key, required this.content});

  /// 宽屏判定（UI10）：宽 ≥900，或横屏（宽>高）一律按桌面布局
  ///（常驻可收缩侧边栏 + 右队列槽 + 内容多列自适应）。
  /// 竖屏窄屏仍走抽屉。宽屏内容区整页详情也按同一口径分流。
  static bool isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 900 || size.width > size.height;
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _sidebarVisible = true;
  NavigationProvider? _nav;
  int _seenSidebarToggle = 0;

  /// 交互门控（可能为 null：未接入门控的旧测试/调用方，走原路径）。
  InteractionGate? _gate;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate = InteractionGate.maybeOf(context);
    final nav = context.read<NavigationProvider>();
    if (!identical(_nav, nav)) {
      _nav?.removeListener(_onNavChanged);
      _nav = nav;
      _seenSidebarToggle = nav.sidebarToggleTick;
      nav.addListener(_onNavChanged);
    }
  }

  @override
  void dispose() {
    _nav?.removeListener(_onNavChanged);
    super.dispose();
  }

  void _onNavChanged() {
    final nav = _nav;
    if (nav == null || !mounted) return;
    final tick = nav.sidebarToggleTick;
    if (tick == _seenSidebarToggle) return;
    _seenSidebarToggle = tick;
    _toggleSidebar();
  }

  void _toggleSidebar() {
    if (!AppShell.isWide(context)) {
      final scaffold = _scaffoldKey.currentState;
      if (scaffold == null) return;
      if (scaffold.isDrawerOpen) {
        scaffold.closeDrawer();
      } else {
        scaffold.openDrawer();
      }
    } else {
      setState(() => _sidebarVisible = !_sidebarVisible);
    }
  }

  /// 内容区滚动信号 → 交互门控：滚动期间聚合并去重后台数据通知（R-2）。
  ///
  /// 用 NotificationListener 统一接管所有后代 Scrollable 的滚动通知
  /// （列表/网格/Pager 均会冒泡到此层），无需逐页接线。
  bool _onScrollNotification(ScrollNotification n) {
    final gate = _gate;
    if (gate != null) {
      if (n is ScrollStartNotification) {
        gate.beginScroll();
      } else if (n is ScrollEndNotification) {
        gate.endScroll();
      }
    }
    return false; // 不拦截，继续向上冒泡。
  }

  @override
  Widget build(BuildContext context) {
    final wide = AppShell.isWide(context);
    // 订阅收窄（T005）：布局壳只关注队列面板开合；区段/搜索/播放页等变更
    // 不再牵连整壳重建。
    final nav = context.read<NavigationProvider>();
    final queueOpen =
        context.select<NavigationProvider, bool>((n) => n.queueOpen);
    // 队列面板开合 → 门控：面板打开/关闭期间被视为「交互中」。
    if (_gate != null && _gate!.queuePanelOpen != queueOpen) {
      final open = queueOpen;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _gate?.setQueuePanelOpen(open));
    }

    final contentColumn = Column(
      children: [
        // 图层隔离：顶栏/迷你条高频重建（滑动跟手、播放进度）不脏内容页，
        // 内容页横滑/列表滚动各自独立栅格化，降低掉帧。
        RepaintBoundary(child: TopBar(onSidebarToggle: _toggleSidebar)),
        Expanded(
          // 顶栏已用 SafeArea 消费过状态栏；内容区不能再叠加一次系统安全区。
          // Flutter 的 ListView/GridView 在 padding==null 时会把 MediaQuery.padding
          //（状态栏+手势条）自动加为滚动内边距——这正是 UI4「列表均多一条空白」的根因。
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            // 内容区滚动通知统一冒泡到门控（不影响原层级与栅格化隔离）。
            child: RepaintBoundary(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: widget.content,
              ),
            ),
          ),
        ),
        const RepaintBoundary(child: MiniPlayerBar()),
      ],
    );

    final shell = wide
        ? Row(
            children: [
              // 宽屏侧边栏伸缩：宽 260↔0，300ms 与播放页/内容页统一。
              // 常驻挂载 + Clip 裁剪（收起后 IgnorePointer），避免 if 直挂的瞬时显隐。
              AnimatedContainer(
                duration: kPageMotion,
                curve: kPageMotionCurve,
                width: _sidebarVisible ? 260 : 0,
                child: ClipRect(
                  child: OverflowBox(
                    maxWidth: 260,
                    alignment: Alignment.centerLeft,
                    child: IgnorePointer(
                      ignoring: !_sidebarVisible,
                      child: const SizedBox(width: 260, child: Sidebar()),
                    ),
                  ),
                ),
              ),
              Expanded(child: contentColumn),
              // 宽屏右队列伸缩：宽 360↔0，同 300ms。
              // 宽屏必须有界宽度：Row 非 flex 子项是无界宽度，width=null
              // 会让面板内部 Spacer/Expanded 抛 unbounded 布局异常（整面板
              // 空白）。窄屏底部弹层不受影响（Sheet 有界）。内层固定
              // kQueuePanelWidth 满足有界要求，外层负责伸缩。
              AnimatedContainer(
                duration: kPageMotion,
                curve: kPageMotionCurve,
                width: queueOpen ? kQueuePanelWidth : 0,
                child: ClipRect(
                  child: OverflowBox(
                    maxWidth: kQueuePanelWidth,
                    alignment: Alignment.centerRight,
                    child: IgnorePointer(
                      ignoring: !queueOpen,
                      child: SizedBox(
                        width: kQueuePanelWidth,
                        child: QueuePanel(
                            onClose: nav.closeQueue, width: kQueuePanelWidth),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          )
        : Stack(
            children: [
              contentColumn,
            ],
          );

    if (!wide) {
      // 窄屏：顶部抽屉由 Drawer 承载；队列入口在顶栏与迷你播放条。
      return _withSheetHost(Scaffold(
        key: _scaffoldKey,
        drawer: const Sidebar(),
        body: shell,
      ));
    }

    return _withSheetHost(Scaffold(body: shell));
  }

  /// 叠加统一拖拽式窗口宿主（[AppSheetHost]）。
  ///
  /// 挂载点固定在 Scaffold 之外（不被 `MediaQuery.removePadding` 裁剪、悬浮层
  /// 继承真实安全区）；窗口本身画在首页路由条目之上、后续 push 的菜单/弹窗
  /// 路由之下（历史 bug：裸 OverlayEntry 会被导航历史重排压到路由之上，
  /// 见 [AppSheetLauncher]）。
  Widget _withSheetHost(Widget scaffold) {
    return Stack(
      children: [scaffold, const AppSheetHost()],
    );
  }
}
