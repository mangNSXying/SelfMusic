import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';

/// 底部“正在播放”迷你条：点击进入播放页；提供播放控制。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final nav = context.watch<NavigationProvider>();
    final cs = Theme.of(context).colorScheme;

    if (!player.hasCurrent) {
      return const SizedBox.shrink();
    }
    final song = player.current!;

    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: () {
          if (!nav.playerView) nav.openPlayer();
        },
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Row(
            children: [
              Icon(Icons.music_note, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(song.artist ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(player.playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                color: cs.primary,
                iconSize: 32,
                onPressed: player.toggle,
              ),
              IconButton(icon: const Icon(Icons.skip_next), onPressed: player.next),
              IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: () => nav.openPlayer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
