import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';

import '../../layout/player_metrics.dart';
import '../../models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../widgets/lyrics_view.dart';
import '../../widgets/player_controls.dart';
import '../../widgets/pressable.dart';
import '../../widgets/song_list.dart';

import 'player_band.dart';
import 'player_cover.dart';
import 'player_now_playing.dart';
import 'queue_page.dart';

/// 横竖屏切换时把旧布局按原尺寸等比缩放后淡出，避免直接吃新约束被拉伸。
///
/// 旧子树的 frameSize/mediaSize 是它上一帧作为当前朝向时捕获的；新子树用
/// 当前尺寸，FittedBox 保持 1:1。切换动画结束后旧子树销毁。
class PlayerOrientationFrame extends StatelessWidget {
  final Size frameSize;
  final Size mediaSize;
  final Widget child;

  const PlayerOrientationFrame({
    super.key,
    required this.frameSize,
    required this.mediaSize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: frameSize.width,
        height: frameSize.height,
        child: MediaQuery(
          data: media.copyWith(size: mediaSize),
          child: child,
        ),
      ),
    );
  }
}

/// 手机横屏三列（参照更新版 ui-playpage-wide.html，UI10）：
/// 左列 34% 封面/信息/进度，中列歌词（上下渐隐），右列 22% 竖向控制
/// （定时 / 上一首·播放·下一首 / 模式）。只在窄屏横屏（手机）使用；
/// 桌面/超宽屏走 [DesktopLandscapePlayer]，避免被大窗口拉散。
///
/// 公开（去掉下划线）供布局回归测试直接渲染：桌面测试宿主上
/// `Platform.isLinux` 为真，经 [PlayerScreen] 永远走桌面双栏分支，
/// 手机三列的溢出问题只能直接挂载本组件覆盖（test/player_landscape_test.dart）。
/// 播放列竖向下拖跟手（横屏手机三列 page1 用）：中列歌词窗不包，避免与歌词
/// 纵滚同一竞技场打架；回调全空时原样返回，零行为变化。
Widget _withPlayerDrag({
  required Widget child,
  required GestureDragStartCallback? onVerticalDragStart,
  required GestureDragUpdateCallback? onVerticalDragUpdate,
  required GestureDragEndCallback? onVerticalDragEnd,
}) {
  if (onVerticalDragStart == null &&
      onVerticalDragUpdate == null &&
      onVerticalDragEnd == null) {
    return child;
  }
  return GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragStart: onVerticalDragStart,
    onVerticalDragUpdate: onVerticalDragUpdate,
    onVerticalDragEnd: onVerticalDragEnd,
    child: child,
  );
}

class LandscapePlayer extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 播放列（左播放列 + 右竖向控制列，不含中列歌词）的竖向下拖跟手：
  /// page1 传入竖屏同套 `_onPlayerDrag*` 以下滑返回内容页；分栏歌单页等
  /// 非播放页保持 null（仅播放页，避免手势混乱）。
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const LandscapePlayer(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (!player.hasCurrent) {
      return Center(
          child: PlayerEmptyState(
              coverSize: (size.height * 0.3).clamp(96.0, 150.0)));
    }
    final s = player.current!;
    final leftW = (size.width * 0.42).clamp(220.0, 420.0);
    final rightW = (size.width * 0.16).clamp(70.0, 96.0);
    // 桌面宽屏限宽居中（参照稿 max-width: 820），避免三列被拉得过散。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Row(
          children: [
            // 第一列：封面、信息、进度条（与分栏右窗共用 LandscapePlayerMain，
            // 不定自身宽度，由外层 SizedBox 给宽）。
            SizedBox(
              width: leftW,
              child: LandscapePlayerMain(
                  player: player,
                  direct: direct,
                  cs: cs,
                  song: s,
                  onVerticalDragStart: onVerticalDragStart,
                  onVerticalDragUpdate: onVerticalDragUpdate,
                  onVerticalDragEnd: onVerticalDragEnd),
            ),
            // 第二列：歌词区，上下边缘渐隐（参照稿 mask-image）；横屏两页
            // 布局里歌词内嵌在播放页，高亮行居中。
            Expanded(
              child: EdgeFade(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: LyricsView(player: player, align: 0.47),
              ),
            ),
            // 第三列：竖向主控制区（顶部定时 / 中部切歌播放 / 底部模式，
            // 与分栏右窗共用 LandscapePlayerSide）。
            SizedBox(
              width: rightW,
              child: LandscapePlayerSide(
                  player: player,
                  cs: cs,
                  onVerticalDragStart: onVerticalDragStart,
                  onVerticalDragUpdate: onVerticalDragUpdate,
                  onVerticalDragEnd: onVerticalDragEnd),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏左播放列（封面/信息/工具/进度）：三列整页与「左歌单右播放」分栏
/// 右窗共用。不定自身宽度，由父级 SizedBox 给宽（整页按全屏宽算，分栏按栏宽
/// 算——直接复用整页会导致 MediaQuery 全屏宽撑爆半栏）。
/// 不滚动：封面吃掉固定行之外的剩余高度，矮屏由 Flexible 自动收缩。
class LandscapePlayerMain extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const LandscapePlayerMain(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    final s = song;
    return _withPlayerDrag(
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Center(
                heightFactor: 1,
                child: LayoutBuilder(
                  builder: (context, c) => Cover(
                    coverPath: s.coverPath,
                    song: s,
                    cs: cs,
                    size: math.max(0, math.min(c.maxWidth - 24, c.maxHeight)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TitleBlock(
                player: player, direct: direct, compact: true, dense: true),
            const SizedBox(height: 4),
            ToolRow(
                player: player, direct: direct, cs: cs, song: s, center: true),
            PlayerSeek(player: player, cs: cs, showTime: false),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏右竖向控制列（顶部定时 / 中部切歌播放 / 底部模式）：三列整页与
/// 分栏右窗共用，不定自身宽度。
class LandscapePlayerSide extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const LandscapePlayerSide(
      {required this.player,
      required this.cs,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    return _withPlayerDrag(
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SleepButton(player: player, cs: cs),
            VerticalControls(player: player, cs: cs),
            ModeButton(player: player, cs: cs),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏「左歌单右播放」分栏（PageView 首页的横屏形态）：
/// 左栏为歌单（绑定歌单 [SongList] / 兜底嵌入式 [QueuePage]，搜索/排序/多选等
/// 完整功能），右窗复用当前三列播放布局的左右列（播放列 + 竖向控制列，
/// 不含中列歌词——歌词仍在滑动后的整页播放页中列，避免双 LyricsView 跟焦与
/// 半栏拥挤）。
///
/// 公开（去掉下划线）供布局回归测试直接渲染，理由同 [LandscapePlayer]。
class LandscapePlaylistSplit extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 重进歌单页的追焦信号（透传给左栏歌单/队列列表）。
  final ValueListenable<int>? focusTick;
  const LandscapePlaylistSplit(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.focusTick});

  @override
  Widget build(BuildContext context) {
    if (!player.hasCurrent) {
      return Row(
        children: [
          Expanded(child: BandSongPage(embedded: true, focusTick: focusTick)),
          SizedBox(
            width: 300,
            child: Center(
                child: PlayerEmptyState(
                    coverSize: (MediaQuery.sizeOf(context).height * 0.3)
                        .clamp(96.0, 150.0))),
          ),
        ],
      );
    }
    final s = player.current!;
    // 右窗按栏内约束定宽（不用 MediaQuery 全屏宽，否则撑爆半栏）；
    // 55:45 左右开，右窗钳在手机横屏可用区间。
    return LayoutBuilder(
      builder: (context, c) {
        final rightW = (c.maxWidth * 0.45).clamp(280.0, 400.0);
        final sideW = (c.maxWidth * 0.09).clamp(56.0, 72.0);
        return Row(
          children: [
            Expanded(child: BandSongPage(embedded: true, focusTick: focusTick)),
            SizedBox(
              width: rightW,
              child: Row(
                children: [
                  Expanded(
                    child: LandscapePlayerMain(
                        player: player, direct: direct, cs: cs, song: s),
                  ),
                  SizedBox(
                    width: sideW,
                    child: LandscapePlayerSide(player: player, cs: cs),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 桌面横屏双栏（Linux/Windows/macOS 或超宽屏）：
/// 左栏封面/信息/控制整体垂直居中的一列（横排控制键，不被窗口高度拉散），
/// 右栏整幅歌词限宽居中。手机版三列在大窗口下会显得内容碎、留白多，
/// 故按平台/宽度分流（UI10 平台差异化）。
class DesktopLandscapePlayer extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  const DesktopLandscapePlayer(
      {required this.player, required this.direct, required this.cs});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.desktop(size);
    if (!player.hasCurrent) {
      return Center(
          child:
              PlayerEmptyState(coverSize: m.emptyCoverSize, scale: m.uiScale));
    }
    final s = player.current!;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.contentMaxWidth),
        child: Row(
          children: [
            // 左栏：与分栏右窗共用 DesktopPlayerColumn（不定自身宽度，由调用方给宽）。
            DesktopPlayerColumn(
                player: player,
                direct: direct,
                cs: cs,
                song: s,
                width: m.leftColumnWidth,
                metrics: m),
            // 右栏：歌词限宽居中 + 上下边缘渐隐（改进.txt：去掉两栏中间分割线）。
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: m.lyricsMaxWidth + m.lyricsPadding * 2),
                  child: EdgeFade(
                    padding: EdgeInsets.symmetric(
                        horizontal: m.lyricsPadding, vertical: 12 * m.uiScale),
                    child: LyricsView(
                        player: player, scale: m.uiScale, align: 0.47),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌面横屏左播放列（封面/信息/工具/进度/横排控制）：双栏整页左栏与「左歌单
/// 右播放」分栏右窗共用。宽度由调用方按上下文给定（整页按全屏算，分栏按栏内
/// 约束算）；矮窗口可滚动，内容不足一屏高时垂直居中。
class DesktopPlayerColumn extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final double width;
  final PlayerMetrics metrics;
  const DesktopPlayerColumn(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      required this.width,
      required this.metrics});

  @override
  Widget build(BuildContext context) {
    final s = song;
    final scale = metrics.uiScale;
    final horizontal = metrics.columnPadding;
    final vertical = 16 * scale;
    return SizedBox(
      width: width,
      child: LayoutBuilder(
        builder: (context, c) {
          final innerWidth = math.max(0.0, width - horizontal * 2);
          final byHeight =
              c.maxHeight - vertical * 2 - metrics.fixedContentHeight;
          final cover = math.min(
            metrics.targetCover,
            math.min(
              innerWidth,
              math.max(160 * scale, byHeight),
            ),
          );
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: horizontal, vertical: vertical),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: c.maxHeight - vertical * 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Cover(
                        coverPath: s.coverPath,
                        song: s,
                        cs: cs,
                        size: cover,
                        scale: scale),
                  ),
                  SizedBox(height: 16 * scale),
                  TitleBlock(
                      player: player,
                      direct: direct,
                      compact: true,
                      scale: scale),
                  SizedBox(height: 6 * scale),
                  MetaLine(
                      player: player,
                      direct: direct,
                      cs: cs,
                      song: s,
                      scale: scale),
                  ToolRow(
                      player: player,
                      direct: direct,
                      cs: cs,
                      song: s,
                      center: true,
                      scale: scale),
                  PlayerSeek(player: player, cs: cs, scale: scale),
                  // 左栏宽会被钳到最小 320×uiScale（内容区随比例缩放），
                  // 控制行约 302×uiScale；窄桌面窗口会横向溢出，scaleDown
                  // 只在放不下时整体等比收缩，宽窗口零影响。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ControlRow(player: player, cs: cs, scale: scale),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 桌面横屏「左歌单右播放」分栏（PageView 首页的横屏形态）：
/// 左栏为歌单（完整功能），右窗复用当前双栏播放布局的左播放列（不含歌词栏——
/// 歌词仍在滑动后的整页播放页右栏）。公开供布局回归测试直接渲染。
class DesktopPlaylistSplit extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 重进歌单页的追焦信号（透传给左栏歌单/队列列表）。
  final ValueListenable<int>? focusTick;
  const DesktopPlaylistSplit(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.focusTick});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.desktop(size);
    if (!player.hasCurrent) {
      return Row(
        children: [
          Expanded(child: BandSongPage(embedded: true, focusTick: focusTick)),
          SizedBox(
            width: m.rightPaneWidth(size.width),
            child: Center(
                child: PlayerEmptyState(
                    coverSize: m.emptyCoverSize, scale: m.uiScale)),
          ),
        ],
      );
    }
    final s = player.current!;
    // 右窗按栏内约束定宽（不用全屏宽直算）；封面仍按全屏高算（栏与页同高）。
    return LayoutBuilder(
      builder: (context, c) {
        final rightW = m.rightPaneWidth(c.maxWidth);
        return Row(
          children: [
            Expanded(child: BandSongPage(embedded: true, focusTick: focusTick)),
            DesktopPlayerColumn(
                player: player,
                direct: direct,
                cs: cs,
                song: s,
                width: rightW,
                metrics: m),
          ],
        );
      },
    );
  }
}

/// 歌词区上下边缘渐隐（参照稿 mask-image）。
class EdgeFade extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const EdgeFade({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0.0, 0.12, 0.88, 1.0],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 横屏右列中部的竖向播放控制：上一首 / 播放暂停 / 下一首。
class VerticalControls extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  const VerticalControls({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          child: const Icon(Icons.skip_previous, size: 28),
        ),
        const SizedBox(height: 6),
        PlayPauseButton(player: player, cs: cs, size: 56),
        const SizedBox(height: 6),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          child: const Icon(Icons.skip_next, size: 28),
        ),
      ],
    );
  }
}
