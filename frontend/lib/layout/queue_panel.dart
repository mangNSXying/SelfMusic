import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';

/// 切换播放队列面板：窄屏底部弹层（0.7 高），宽屏右侧常驻面板开关。
///
/// 顶栏队列按钮已移除，统一由迷你播放栏进入；AppShell 与迷你栏共用此入口。
void toggleQueuePanel(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  if (MediaQuery.of(context).size.width < 900) {
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
class QueuePanel extends StatelessWidget {
  final VoidCallback onClose;

  /// 面板宽度（null 时撑满可用宽度，供窄屏底部弹层使用）。
  final double? width;
  const QueuePanel({super.key, required this.onClose, this.width});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: width,
      color: colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
            child: Row(
              children: [
                Text('播放队列', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close), onPressed: onClose),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: player.queue.isEmpty
                ? const Center(child: Text('队列为空'))
                : ListView.separated(
                    itemCount: player.queue.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                    itemBuilder: (c, i) {
                      final s = player.queue[i];
                      final isCurrent = player.current?.id == s.id;
                      return ListTile(
                        leading: Icon(isCurrent ? Icons.graphic_eq : Icons.music_note,
                            color: isCurrent ? colorScheme.primary : null),
                        title: Text(s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isCurrent ? TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w600) : null),
                        subtitle: Text(s.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => player.playAt(i),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
