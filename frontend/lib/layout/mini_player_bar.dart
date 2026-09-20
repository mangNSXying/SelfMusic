import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../utils/song_title_format.dart';
import '../widgets/player_sheet_anim.dart';
import 'queue_panel.dart';

/// 底部“正在播放”迷你条：点击进入全屏播放页；提供播放控制。
/// 尺寸较大（72 高 + 封面缩略图），便于移动端点击。
class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  double _dragStartY = 0;
  double _dragStartP = 1;

  /// 上滑跟手：播放页从底部随手指升起；松手按位移/速度吸附或落回。
  void _onDragStart(DragStartDetails d) {
    final sheet = context.read<PlayerSheetAnimator>();
    _dragStartY = d.globalPosition.dy;
    _dragStartP = sheet.value;
    sheet.dragStart();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final h = MediaQuery.of(context).size.height;
    if (h <= 0) return;
    context
        .read<PlayerSheetAnimator>()
        .dragTo(_dragStartP + (d.globalPosition.dy - _dragStartY) / h);
  }

  void _onDragEnd(DragEndDetails d) {
    final sheet = context.read<PlayerSheetAnimator>();
    final v = d.primaryVelocity ?? 0;
    final p = sheet.value;
    if (v < -700 || p < 0.6) {
      sheet.settle(0, onDone: () {
        if (!mounted) return;
        context.read<NavigationProvider>().openPlayer();
      });
    } else {
      sheet.settle(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final nav = context.watch<NavigationProvider>();
    final settings = context.watch<DirectSourceManager>().settings;
    final gestureOn = settings.playerGestureSwipe;
    final cs = Theme.of(context).colorScheme;

    // 队列有内容即展示（即使当前曲加载失败也保留入口），无队列才隐藏。
    if (player.queue.isEmpty) {
      return const SizedBox.shrink();
    }
    final song = player.current ?? player.queue.first;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 上滑跟手进入播放页（点按同样进入）；受「播放页滑动手势」开关控制。
      onVerticalDragStart: gestureOn ? _onDragStart : null,
      onVerticalDragUpdate: gestureOn ? _onDragUpdate : null,
      onVerticalDragEnd: gestureOn ? _onDragEnd : null,
      child: Material(
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
                      formatSongTitle(song, settings.songTitleFormat),
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
                icon: Icon(nav.queueOpen
                    ? Icons.queue_music
                    : Icons.queue_music_outlined),
                iconSize: 28,
                color: nav.queueOpen ? cs.primary : null,
                tooltip: '播放队列',
                onPressed: () => toggleQueuePanel(context),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}