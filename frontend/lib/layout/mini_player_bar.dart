import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';
import '../utils/cover_thumb.dart';
import '../utils/song_title_format.dart';
import '../utils/zh_variant.dart';
import '../widgets/app_volume_control.dart';
import '../widgets/draggable_sheet.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_sheet_anim.dart';
import '../widgets/pressable.dart';
import 'queue_panel.dart';
import 'screen_metrics.dart';

/// 迷你条固定高度：竖屏/回退 72，横屏三列 88。
const double kMiniPlayerBarHeight = 72;
const double kMiniPlayerBarHeightWide = 88;

/// 宽屏三列迷你条的最低可用宽度：右侧 3 个 48 命中区 + 内边距。
/// 低于此值回退现有 72 条（手机横屏队列展开时约 224）。
const double kMiniWideMinWidth = 550;

/// 宽屏中列播控尺寸：随中列宽度自适应。
///
/// play 44~48、切歌图标 28~34、左右间隔 14~26。播放键上限 48 是为给
/// 底部 22 高进度行留出至少 8 的上下留白；间隔仍可继续随宽度增长。
@visibleForTesting
({double play, double skip, double gap}) miniTransportMetrics(
    double centerWidth) {
  final w = centerWidth.clamp(0.0, 560.0);
  return (
    play: (w * 0.115).clamp(44.0, 48.0).toDouble(),
    skip: (w * 0.08).clamp(28.0, 34.0).toDouble(),
    gap: (w * 0.06).clamp(14.0, 26.0).toDouble(),
  );
}

/// 队列按钮区上滑判定：向上速度或累计上移距离足够即视为「上滑打开播放队列」。
/// 与整条迷你条的上滑（打开播放页）阈值一致（velocity < -700）。
@visibleForTesting
bool isQueueUpSwipe(double? primaryVelocity, double startY, double lastY) =>
    (primaryVelocity ?? 0) < -700 || startY - lastY > 40;

/// 底部“正在播放”迷你条：点击进入全屏播放页；提供播放控制。
///
/// 宽度够且窗口为宽屏时走三列：左当前曲 / 中播控 + 进度 / 右模式·音量·队列；
/// 竖屏、窄窗或队列挤压到 [kMiniWideMinWidth] 以下时回退现有 72 高单行。
/// 两种形态都是固定高度，内容不反向撑高播放条。
class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  double _dragStartY = 0;
  double _dragStartP = 1;

  /// 队列按钮区域的上滑手势（子手势在竞技场胜过外层整条上滑 → 打开队列而非播放页）。
  ///
  /// 窄屏滑动启动：统一拖拽式窗口经 [AppSheetLauncher] 逐帧跟手指升起
  /// （与窗口本体同一函数，见 [beginQueueSheetSwipe]），松手按速度/位移
  /// 吸附；宽屏无底部弹层，退回旧路径（阈值判定后切换右侧面板）。
  double? _queueDragStartY;
  double? _queueDragLastY;

  /// 本次上滑是否已推入跟手窗口（悬浮层已插入时为真）。
  bool _queueSwiping = false;

  void _onQueueDragStart(DragStartDetails d) {
    _queueDragStartY = d.globalPosition.dy;
    _queueDragLastY = d.globalPosition.dy;
    // 滑动启动①：推入进度 0 的统一窗口；窗口已在展示则忽略本次手势。
    _queueSwiping = beginQueueSheetSwipe(context);
  }

  void _onQueueDragUpdate(DragUpdateDetails d) {
    final start = _queueDragStartY;
    _queueDragLastY = d.globalPosition.dy;
    if (start == null || !_queueSwiping) return;
    final h = MediaQuery.sizeOf(context).height;
    if (h <= 0) return;
    // 滑动启动②：上移 0.6 屏即拉满（与窗口静息高度对齐）。
    context.read<AppSheetLauncher>().swipeTo(
        (start - d.globalPosition.dy) / (h * kAppSheetSwipeTravelFactor));
  }

  void _onQueueDragEnd(DragEndDetails d) {
    final start = _queueDragStartY;
    final last = _queueDragLastY;
    final swiping = _queueSwiping;
    _queueDragStartY = null;
    _queueDragLastY = null;
    _queueSwiping = false;
    if (start == null || last == null || !mounted) return;
    final nav = context.read<NavigationProvider>();
    final size = MediaQuery.sizeOf(context);
    final wide = isWideWindow(size);
    final launcher = context.read<AppSheetLauncher>();
    if (wide) {
      // 宽屏无底部弹层：上滑（速度或累计位移）切右侧常驻面板，与旧行为一致。
      if (isQueueUpSwipe(d.primaryVelocity, start, last)) {
        nav.toggleQueue();
      }
      return;
    }
    if (!swiping) return;
    // 滑动启动③：上滑足够（速度或已拉开四成）→ 播完剩余行程打开，
    // 否则倒播收起（行程连续不跳变）。
    final v = d.primaryVelocity ?? 0;
    launcher.endSwipe(open: v < -700 || launcher.swipeValue > 0.4);
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
    final queueOpen =
        context.select<NavigationProvider, bool>((n) => n.queueOpen);
    final settings = context.watch<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    final wideWindow = isWideWindow(MediaQuery.sizeOf(context));

    // 队列为空（初次进入）时显示占位条：点按进入播放源页添加歌曲，
    // 保证内容页底部始终有迷你条（改进 B6-U9）。
    if (player.queue.isEmpty) {
      return _buildEmpty(nav, cs);
    }
    final song = player.current ?? player.queue.first;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 上滑跟手进入播放页（点按左侧信息同样进入）。
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: Material(
        color: cs.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 固定高度 + 实际宽度：队列/侧栏 300ms 伸缩期间按真实可用宽
            // 切三列/回退，不把宽布局硬塞进动画中的窄列。
            final wide =
                wideWindow && constraints.maxWidth >= kMiniWideMinWidth;
            return wide
                ? _buildWide(context, player, nav, song,
                    settings.songTitleFormat, cs, queueOpen)
                : _buildCompact(context, player, nav, song,
                    settings.songTitleFormat, cs, queueOpen);
          },
        ),
      ),
    );
  }

  Widget _buildEmpty(NavigationProvider nav, ColorScheme cs) {
    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: () => nav.select(NavSection.sources),
        child: Container(
          height: kMiniPlayerBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Row(
            children: [
              _coverPlaceholder(cs, 46),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '还没有播放队列，去播放源页添加歌曲',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
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

  /// 现有单行迷你条：固定 72 高，内容不撑高。
  Widget _buildCompact(
      BuildContext context,
      PlayerProvider player,
      NavigationProvider nav,
      Song song,
      SongTitleFormat titleFormat,
      ColorScheme cs,
      bool queueOpen) {
    return InkWell(
      onTap: () {
        if (!nav.playerView) nav.openPlayer();
      },
      child: Container(
        height: kMiniPlayerBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: Row(
          children: [
            _cover(context, song, cs, 46),
            const SizedBox(width: 12),
            Expanded(child: _trackText(context, song, titleFormat, cs)),
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
            _queueButton(context, queueOpen, cs, iconSize: 28),
          ],
        ),
      ),
    );
  }

  /// 横屏三列：左当前曲 / 中播控 + 进度 / 右模式·音量·队列。
  ///
  /// 列宽 2:3:2（等价 1:1.5:1），中列封顶 560；左侧封面按固定条高取大，
  /// 中列播控与间隔由 [miniTransportMetrics] 随中列宽自适应。
  Widget _buildWide(
      BuildContext context,
      PlayerProvider player,
      NavigationProvider nav,
      Song song,
      SongTitleFormat titleFormat,
      ColorScheme cs,
      bool queueOpen) {
    final coverSize =
        (kMiniPlayerBarHeightWide * 0.68).clamp(46.0, 60.0).toDouble();
    return Container(
      height: kMiniPlayerBarHeightWide,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () {
                  if (!nav.playerView) nav.openPlayer();
                },
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  children: [
                    _cover(context, song, cs, coverSize),
                    const SizedBox(width: 11),
                    Expanded(
                      child: _trackText(context, song, titleFormat, cs),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final m = miniTransportMetrics(constraints.maxWidth);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _skipButton(player.prev, '上一首', Icons.skip_previous,
                                m.skip, cs),
                            SizedBox(width: m.gap),
                            PlayPauseButton(
                              player: player,
                              cs: cs,
                              size: m.play,
                              padding: EdgeInsets.zero,
                            ),
                            SizedBox(width: m.gap),
                            _skipButton(player.next, '下一首', Icons.skip_next,
                                m.skip, cs),
                          ],
                        ),
                        const SizedBox(height: 2),
                        PlayerSeek(
                          player: player,
                          cs: cs,
                          compact: true,
                          inlineTime: true,
                          showTime: false,
                          scale: 0.75,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ModeButton(player: player, cs: cs),
                AppVolumeButton(player: player),
                _queueButton(context, queueOpen, cs, iconSize: 28),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _skipButton(VoidCallback onPressed, String tooltip, IconData icon,
      double iconSize, ColorScheme cs) {
    return Pressable(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(icon,
              size: iconSize, color: cs.onSurface.withValues(alpha: 0.78)),
        ),
      ),
    );
  }

  Widget _queueButton(BuildContext context, bool queueOpen, ColorScheme cs,
      {double iconSize = 28}) {
    return GestureDetector(
      // 队列按钮区上滑打开队列（子手势先命中即胜出，不触发外层播放页上滑）。
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onQueueDragStart,
      onVerticalDragUpdate: _onQueueDragUpdate,
      onVerticalDragEnd: _onQueueDragEnd,
      child: IconButton(
        icon: Icon(queueOpen ? Icons.queue_music : Icons.queue_music_outlined),
        iconSize: iconSize,
        color: queueOpen ? cs.primary : null,
        tooltip: '播放队列',
        onPressed: () => toggleQueuePanel(context),
      ),
    );
  }

  Widget _trackText(BuildContext context, Song song,
      SongTitleFormat titleFormat, ColorScheme cs) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatSongTitle(song, titleFormat),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          zhDisplay(song.artist ?? 'Unknown'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _cover(BuildContext context, Song song, ColorScheme cs, double size) {
    if (song.coverPath == null) return _coverPlaceholder(cs, size);
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.file(
          File(coverDisplayPath(song.coverPath!)),
          fit: BoxFit.cover,
          cacheWidth: px,
          cacheHeight: px,
          errorBuilder: (_, __, ___) => _coverPlaceholder(cs, size),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox(
        width: size,
        height: size,
        child: Container(
          color: cs.primary.withValues(alpha: 0.12),
          child: Icon(Icons.music_note, color: cs.primary, size: size * 0.5),
        ),
      ),
    );
  }
}
