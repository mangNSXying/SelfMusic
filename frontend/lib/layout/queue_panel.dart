import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/row_list.dart';
import '../widgets/song_list.dart';

/// 切换播放队列面板：窄屏竖屏底部弹层（0.7 高），宽屏/横屏右侧常驻面板开关。
///
/// 顶栏队列按钮已移除，统一由迷你播放栏进入；AppShell 与迷你栏共用此入口。
/// 宽屏判定与 AppShell.isWide 一致（queue_panel 不导入 app_shell 避免循环依赖）。
void toggleQueuePanel(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= 900 || size.width > size.height;
  if (!wide) {
    if (nav.queueOpen) return;
    nav.openQueue();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => FractionallySizedBox(
        heightFactor: 0.7,
        child: QueuePanel(onClose: () => Navigator.of(c).pop()),
      ),
    ).whenComplete(nav.closeQueue);
    return;
  }
  nav.toggleQueue();
}

/// 播放队列面板：纯队列展示（当前歌曲与控制在播放页/迷你条操作）。
/// 打开时自动定位到当前播放歌曲并以强调色显示。
class QueuePanel extends StatefulWidget {
  final VoidCallback onClose;

  /// 面板宽度（null 时撑满可用宽度，供窄屏底部弹层使用）。
  final double? width;
  const QueuePanel({super.key, required this.onClose, this.width});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 打开即定位到当前播放歌曲（首帧布局完成后再滚动）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final player = context.read<PlayerProvider>();
      final idx = _currentIndex(player);
      if (idx <= 0) return;
      final target = (idx * kRowExtent - 96)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _currentIndex(PlayerProvider player) {
    for (var i = 0; i < player.queue.length; i++) {
      if (player.isCurrent(player.queue[i])) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final queue = player.queue;

    return Container(
      width: widget.width,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
            child: Row(
              children: [
                Text('播放队列',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: queue.isEmpty
                ? const Center(child: Text('队列为空'))
                : RowList(
                    controller: _scroll,
                    count: queue.length,
                    itemBuilder: (c, i) {
                      final s = queue[i];
                      final isCurrent = player.isCurrent(s);
                      return SongTile(
                        song: s,
                        source: null,
                        playing: isCurrent,
                        onPlay: () => player.playAt(i),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
