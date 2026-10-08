import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';
import '../utils/cover_thumb.dart';
import '../utils/song_title_format.dart';
import '../widgets/player_sheet_anim.dart';
import '../widgets/pressable.dart';
import 'queue_panel.dart';

/// 队列按钮区上滑判定：向上速度或累计上移距离足够即视为「上滑打开播放队列」。
/// 与整条迷你条的上滑（打开播放页）阈值一致（velocity < -700）。
@visibleForTesting
bool isQueueUpSwipe(double? primaryVelocity, double startY, double lastY) =>
    (primaryVelocity ?? 0) < -700 || startY - lastY > 40;

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

  /// 队列按钮区域的上滑手势（子手势在竞技场胜过外层整条上滑 → 打开队列而非播放页）。
  double? _queueDragStartY;
  double? _queueDragLastY;

  void _onQueueDragStart(DragStartDetails d) {
    _queueDragStartY = d.globalPosition.dy;
    _queueDragLastY = d.globalPosition.dy;
  }

  void _onQueueDragUpdate(DragUpdateDetails d) {
    _queueDragLastY = d.globalPosition.dy;
  }

  void _onQueueDragEnd(DragEndDetails d) {
    final start = _queueDragStartY;
    final last = _queueDragLastY;
    _queueDragStartY = null;
    _queueDragLastY = null;
    if (start == null || last == null || !mounted) return;
    // 上滑（速度或累计位移）→ 打开播放队列；点按仍由 IconButton 原样处理开关。
    if (isQueueUpSwipe(d.primaryVelocity, start, last)) {
      toggleQueuePanel(context);
    }
  }

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
    // 订阅收窄（T007）：迷你条只关注队列面板开合（按钮高亮）；播放页可见性、
    // 区段、搜索等变更不再重建迷你条。
    final nav = context.read<NavigationProvider>();
    final queueOpen = context.select<NavigationProvider, bool>((n) => n.queueOpen);
    final settings = context.watch<DirectSourceManager>().settings;
    final gestureOn = settings.playerGestureSwipe;
    final cs = Theme.of(context).colorScheme;

    // 队列为空（初次进入）时显示占位条：点按进入播放源页添加歌曲，
    // 保证内容页底部始终有迷你条（改进 B6-U9）。
    if (player.queue.isEmpty) {
      return Material(
        color: cs.surface,
        child: InkWell(
          onTap: () => nav.select(NavSection.sources),
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
                    child: Container(
                      color: cs.primary.withValues(alpha: 0.12),
                      child: Icon(Icons.music_note, color: cs.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '还没有播放队列，去播放源页添加歌曲',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6)),
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: cs.onSurface.withValues(alpha: 0.4)),
              ],
            ),
          ),
        ),
      );
    }
    final song = player.current ?? player.queue.first;
    // 封面按实际显示尺寸 ×DPR 降解码（缩略图优先）。
    final coverPx = (46 * MediaQuery.devicePixelRatioOf(context)).round();

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
                          File(coverDisplayPath(song.coverPath!)),
                          fit: BoxFit.cover,
                          cacheWidth: coverPx,
                          cacheHeight: coverPx,
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
              Pressable(
                onPressed: player.toggle,
                tooltip: player.playing ? '暂停' : '播放',
                pressedScale: 0.85,
                child: Icon(
                    player.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    size: 42,
                    color: cs.primary),
              ),
              Pressable(
                onPressed: player.next,
                tooltip: '下一首',
                child: const Icon(Icons.skip_next, size: 30),
              ),
              GestureDetector(
                // 队列按钮区上滑打开队列（子手势先命中即胜出，不触发外层播放页上滑）。
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: _onQueueDragStart,
                onVerticalDragUpdate: _onQueueDragUpdate,
                onVerticalDragEnd: _onQueueDragEnd,
                child: IconButton(
                  icon: Icon(queueOpen
                      ? Icons.queue_music
                      : Icons.queue_music_outlined),
                  iconSize: 28,
                  color: queueOpen ? cs.primary : null,
                  tooltip: '播放队列',
                  onPressed: () => toggleQueuePanel(context),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}