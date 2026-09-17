import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../widgets/play_mode_selector.dart';

/// 右侧播放队列面板：展示当前队列 + 播放控制，可折叠。
class QueuePanel extends StatelessWidget {
  final VoidCallback onClose;
  const QueuePanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 300,
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
          Flexible(
            child: SingleChildScrollView(
              child: _MiniControls(player: player),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniControls extends StatelessWidget {
  final PlayerProvider player;
  const _MiniControls({required this.player});

  @override
  Widget build(BuildContext context) {
    if (!player.hasCurrent) {
      return const SizedBox(height: 8);
    }
    final s = player.current!;
    return Column(
      children: [
        const Divider(height: 1),
        const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 2), child: PlayModeSelector())),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(s.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              _Progress(player: player),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: player.prev),
                  IconButton(
                    iconSize: 38,
                    icon: Icon(player.playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                    onPressed: player.toggle,
                  ),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: player.next),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Progress extends StatefulWidget {
  final PlayerProvider player;
  const _Progress({required this.player});

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.player.positionStream,
      builder: (c, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = widget.player.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final cur = pos.inMilliseconds.toDouble().clamp(0, max == 0 ? 1 : max).toDouble();
        return Row(
          children: [
            Text(_fmt(pos), style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Slider(
                min: 0,
                max: max == 0 ? 1 : max,
                value: cur,
                onChanged: (v) => widget.player.seek(Duration(milliseconds: v.toInt())),
              ),
            ),
            Text(_fmt(dur), style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
