import 'package:flutter/material.dart';
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
  bool _queueVisible = false;

  void _toggleSidebar() {
    final w = MediaQuery.of(context).size.width;
    if (w < 900) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      setState(() => _sidebarVisible = !_sidebarVisible);
    }
  }

  void _toggleQueue() {
    // 窄屏：以底部弹层展示队列（宽屏为右侧常驻面板）。
    if (MediaQuery.of(context).size.width < 900) {
      if (_queueVisible) return;
      setState(() => _queueVisible = true);
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (c) => FractionallySizedBox(
          heightFactor: 0.6,
          child: QueuePanel(onClose: () => Navigator.of(c).pop()),
        ),
      ).whenComplete(() {
        if (mounted) setState(() => _queueVisible = false);
      });
      return;
    }
    setState(() => _queueVisible = !_queueVisible);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;

    final contentColumn = Column(
      children: [
        TopBar(onSidebarToggle: _toggleSidebar, onQueueToggle: _toggleQueue, queueActive: _queueVisible),
        Expanded(child: widget.content),
        const MiniPlayerBar(),
      ],
    );

    final shell = wide
        ? Row(
            children: [
              if (_sidebarVisible) const Sidebar(),
              Expanded(child: contentColumn),
              if (_queueVisible) QueuePanel(onClose: _toggleQueue),
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
