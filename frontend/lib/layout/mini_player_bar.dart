import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';

/// 底部“正在播放”迷你条：点击进入全屏播放页；提供播放控制。
/// 尺寸较大（72 高 + 封面缩略图），便于移动端点击。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final nav = context.watch<NavigationProvider>();
    final cs = Theme.of(context).colorScheme;

    // 队列有内容即展示（即使当前曲加载失败也保留入口），无队列才隐藏。
    if (player.queue.isEmpty) {
      return const SizedBox.shrink();
    }
    final song = player.current ?? player.queue.first;

    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: () {
          if (!nav.playerView) nav.openPlayer();
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: song.coverPath != null
                      ? Image.file(
                          File(song.coverPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: cs.primary.withValues(alpha: 0.12),
                            child: Icon(Icons.music_note, color: cs.primary),
                          ),
                        )
                      : Container(
                          color: cs.primary.withValues(alpha: 0.12),
                          child: Icon(Icons.music_note, color: cs.primary),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      song.artist ?? 'Unknown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(player.playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                color: cs.primary,
                iconSize: 42,
                tooltip: player.playing ? '暂停' : '播放',
                onPressed: player.toggle,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 30,
                tooltip: '下一首',
                onPressed: player.next,
              ),
              IconButton(
                icon: const Icon(Icons.queue_music),
                iconSize: 28,
                tooltip: '打开播放页',
                onPressed: () => nav.openPlayer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}