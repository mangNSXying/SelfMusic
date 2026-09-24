import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import 'sidebar.dart';
import 'top_bar.dart';
import 'queue_panel.dart';
import 'mini_player_bar.dart';

/// 布局壳：桌面 = [侧边栏 | 顶栏+内容 | 队列面板]，窄屏 = 抽屉 + 顶栏。
///
/// 侧边栏折叠后完全隐藏；右队列面板可折叠。
class AppShell extends StatefulWidget {
  /// 主内容区。
  final Widget content;
  const AppShell({super.key, required this.content});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _sidebarVisible = true;

  /// 宽屏判定（UI10）：宽 ≥900，或横屏（宽>高）一律按桌面布局
  ///（常驻可收缩侧边栏 + 右队列槽 + 内容多列自适应）。
  /// 竖屏窄屏仍走抽屉。
  static bool isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 900 || size.width > size.height;
  }

  void _toggleSidebar() {
    if (!isWide(context)) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      setState(() => _sidebarVisible = !_sidebarVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final nav = context.watch<NavigationProvider>();

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
            child: RepaintBoundary(child: widget.content),
          ),
        ),
        const RepaintBoundary(child: MiniPlayerBar()),
      ],
    );

    final shell = wide
        ? Row(
            children: [
              if (_sidebarVisible) const Sidebar(),
              Expanded(child: contentColumn),
              if (nav.queueOpen) QueuePanel(onClose: nav.closeQueue),
            ],
          )
        : Stack(
            children: [
              contentColumn,
            ],
          );

    if (!wide) {
      // 窄屏：顶部抽屉由 Drawer 承载；队列入口在顶栏与迷你播放条。
      return Scaffold(
        key: _scaffoldKey,
        drawer: const Sidebar(),
        body: shell,
      );
    }

    return Scaffold(body: shell);
  }
}
