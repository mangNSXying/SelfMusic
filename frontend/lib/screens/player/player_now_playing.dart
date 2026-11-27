import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../layout/player_metrics.dart';
import '../../models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/haptics.dart';
import '../../theme/app_metrics.dart';
import '../../utils/duration_format.dart';
import '../../utils/song_title_format.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/add_to_playlist.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/app_volume_control.dart';
import '../../widgets/lyrics_view.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/player_controls.dart';
import '../../widgets/pressable.dart';
import '../../widgets/sleep_timer_dialog.dart';
import 'player_cover.dart';

TextStyle? _scaleTextStyle(TextStyle? style, double scale) {
  final size = style?.fontSize;
  if (style == null || size == null) return style;
  return style.copyWith(fontSize: size * scale);
}

/// 播放页控件静置隐藏标记（改进.txt UI3）：下行控件据此淡出并停止响应。
/// 用 InheritedWidget 避免把状态穿过 NowPlaying/横屏两套玩家组件层层下传。
class PlayerControlsHidden extends InheritedWidget {
  final bool hidden;
  const PlayerControlsHidden({required this.hidden, required super.child});

  static bool isHidden(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PlayerControlsHidden>()
          ?.hidden ??
      false;

  @override
  bool updateShouldNotify(PlayerControlsHidden old) => hidden != old.hidden;
}

/// 歌词页（竖屏三页布局的整页歌词）：LRC 同步滚动歌词（右滑/按钮返回
/// 播放页）。高亮行略偏上（0.42），与横屏两页布局的内嵌歌词列（居中）区分。
class LyricsPage extends StatelessWidget {
  const LyricsPage();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;
    final s = player.current;
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.portrait(size);
    final scale = m.uiScale;
    final maxWidth = math.min(size.width, math.max(480.0, 720.0 * scale));
    final showCover = direct.settings.lyricsShowCover;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 封面尺寸同时受宽、高与缩放口径约束，矮屏不挤压歌词区。
            final coverSize = math.min(
              math.min(
                  constraints.maxWidth * 0.42, constraints.maxHeight * 0.24),
              180.0 * scale,
            );
            return Column(
              children: [
                if (s != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(24 * scale,
                        (showCover ? 16 : 28) * scale, 24 * scale, 0),
                    child: Column(
                      children: [
                        if (showCover) ...[
                          CoverArt(
                            coverPath: s.coverPath,
                            song: s,
                            cs: cs,
                            size: coverSize,
                            scale: scale,
                          ),
                          SizedBox(height: 12 * scale),
                        ],
                        TitleBlock(
                            player: player,
                            direct: direct,
                            compact: true,
                            scale: scale),
                      ],
                    ),
                  ),
                SizedBox(height: 6 * scale),
                Expanded(
                  child: s == null
                      ? Center(
                          child: Text('暂无歌曲',
                              style: TextStyle(
                                  fontSize: 14 * scale,
                                  color: cs.onSurface.withValues(alpha: 0.5))),
                        )
                      : LyricsView(player: player, scale: scale, align: 0.42),
                ),
                SizedBox(height: 8 * scale),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 未在播放时的首页空态。
class PlayerEmptyState extends StatelessWidget {
  final double coverSize;
  final double scale;

  const PlayerEmptyState({required this.coverSize, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: coverSize,
          height: coverSize,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(24 * scale),
          ),
          child: Icon(Icons.music_note,
              size: coverSize * 0.5, color: cs.primary.withValues(alpha: 0.55)),
        ),
        SizedBox(height: 32 * scale),
        Text('未在播放',
            style: _scaleTextStyle(
                Theme.of(context).textTheme.headlineMedium, scale)),
        SizedBox(height: 8 * scale),
        Text(
          '从左侧导航选择歌曲开始播放',
          style: TextStyle(
            fontSize: 14 * scale,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// v5 设计稿主体：封面 / 歌曲信息 / 工具行 / 进度 / 主控制行。
class NowPlaying extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final double coverSize;
  final double scale;

  const NowPlaying({
    required this.player,
    required this.direct,
    required this.cs,
    required this.coverSize,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Cover(
              coverPath: s.coverPath,
              song: s,
              cs: cs,
              size: coverSize,
              scale: scale),
        ),
        SizedBox(height: 20 * scale),
        TitleBlock(player: player, direct: direct, scale: scale),
        SizedBox(height: 8 * scale),
        MetaLine(player: player, direct: direct, cs: cs, song: s, scale: scale),
        ToolRow(player: player, direct: direct, cs: cs, song: s, scale: scale),
        PlayerSeek(player: player, cs: cs, scale: scale),
        SizedBox(height: 6 * scale),
        ControlRow(player: player, cs: cs, scale: scale),
      ],
    );
  }
}

/// 标题块（歌名跑马灯 + 歌手）：竖屏/横屏共用，[compact] 切紧凑字号；
/// [dense] 为横屏三列布局的更小字号（参照 ui-playpage-wide.html 15/11px）。
class TitleBlock extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final bool compact;
  final bool dense;
  final double scale;
  const TitleBlock(
      {required this.player,
      required this.direct,
      this.compact = false,
      this.dense = false,
      this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    final tt = Theme.of(context).textTheme;
    final titleStyle = _scaleTextStyle(
        dense
            ? tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)
            : (compact ? tt.titleLarge : tt.headlineSmall)
                ?.copyWith(fontWeight: FontWeight.w700),
        scale);
    final artistStyle = _scaleTextStyle(
        dense ? tt.bodySmall : (compact ? tt.titleSmall : tt.titleMedium),
        scale);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MarqueeText(
          formatSongTitle(s, direct.settings.songTitleFormat),
          style: titleStyle,
        ),
        SizedBox(height: (dense ? 2 : (compact ? 4 : 6)) * scale),
        MarqueeText(
          // 未读取的元数据标注「待读取」，避免与「读取后发现没有」的留白混淆。
          zhDisplay(s.metaDisplay(s.artist) ?? ''),
          style: artistStyle,
        ),
      ],
    );
  }
}

/// 元信息行（来源 · 格式 · 时长 + 权重徽标）：竖屏/横屏共用。
class MetaLine extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final double scale;
  const MetaLine(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final s = song;
    // 线路信息只在「该源配了备用」时出现：单线路源的「主源」是废话。
    // 取值是实际在用的线路（player.curLine），不是持久化的偏好。
    // [MetaLine] 的所有调用点传的都是当前曲，不需要再校验归属。
    final hasFallback = direct.fallbackCountOf(s.sourceKey) > 0;
    final lineText = !hasFallback
        ? null
        : player.curLine == 0
            ? '主源'
            : '备用${player.curLine}';
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10 * scale,
      runSpacing: 6 * scale,
      children: [
        Text(
          [
            s.source,
            if (s.format != null && s.format!.isNotEmpty) s.format!,
            if (formatDuration(s.duration).isNotEmpty)
              formatDuration(s.duration),
          ].join(' · '),
          style: _scaleTextStyle(
              Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
              scale),
        ),
        if (lineText != null)
          Tooltip(
            message: '当前播放线路（主源失败会自动切到备用）',
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale, vertical: 2 * scale),
              decoration: BoxDecoration(
                color: (player.curLine == 0 ? cs.surfaceContainerHighest : cs.tertiary)
                    .withValues(alpha: player.curLine == 0 ? 0.7 : 0.16),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    player.curLine == 0
                        ? Icons.check_circle_outline
                        : Icons.swap_horiz,
                    size: 12 * scale,
                    color: player.curLine == 0
                        ? cs.onSurface.withValues(alpha: 0.6)
                        : cs.tertiary,
                  ),
                  SizedBox(width: 4 * scale),
                  Text(
                    lineText,
                    style: _scaleTextStyle(
                        Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: player.curLine == 0
                                  ? cs.onSurface.withValues(alpha: 0.6)
                                  : cs.tertiary,
                            ),
                        scale),
                  ),
                ],
              ),
            ),
          ),
        if (direct.settings.playerShowWeight)
          InkWell(
            borderRadius: BorderRadius.circular(8 * scale),
            onTap: () => AppToast.show('当前曲目的播放权重', isError: false),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale, vertical: 2 * scale),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed,
                      size: 12 * scale,
                      color: cs.onSurface.withValues(alpha: 0.6)),
                  SizedBox(width: 4 * scale),
                  Text(
                    '权重 ${player.currentWeightFactor?.toStringAsFixed(1) ?? '—'}',
                    style: _scaleTextStyle(
                        Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                        scale),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 工具行（喜欢/不喜欢/编辑歌单/缓存/音量）：竖屏/横屏共用。
///
/// 每个按钮都按 [kPlayerSecondaryButtonSize] × scale 的命中区与
/// [kPlayerSecondaryIconSize] × scale 的图标落地，同一行不再混着固定 48
/// 与隐式「图标 + 内边距」两种命中区（4K 下曾出现 48/60 并存）。
///
/// 宽度与 [ControlRow] 同构：由内容定宽（`mainAxisSize.min` + 按钮之间
/// [kPlayerToolGap] × scale 的固定间距），不铺满容器。旧实现先定一条
/// 420×scale 的带子再 `spaceEvenly` 摊开，带宽比主控制行宽约 1/3，大屏下
/// 次级入口反而抢了播控行的视觉重心。
class ToolRow extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final double scale;
  const ToolRow(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.scale = 1.0});

  Future<void> _cache(BuildContext context, Song s) async {
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null || !s.isDirect) {
      AppToast.show('仅直连歌曲可缓存', isError: false);
      return;
    }
    try {
      await direct.cacheSong(src, s);
      if (context.mounted) {
        AppToast.show('已缓存，可离线播放', isError: false);
      }
    } catch (e) {
      AppToast.error(e, '缓存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = song;
    final favorite = direct.weight.isFavorite(s);
    final disliked = direct.weight.isDisliked(s);
    final cached = direct.isUserCached(s);
    final icon = kPlayerSecondaryIconSize * scale;
    final buttons = <Widget>[
      _toolButton(
        context,
        icon: favorite ? Icons.favorite : Icons.favorite_border,
        iconSize: icon,
        color: favorite ? Colors.pink : cs.onSurface.withValues(alpha: 0.55),
        tooltip: favorite ? '取消喜欢' : '喜欢',
        onPressed: () {
          Haptics.fire(HapticStrength.light);
          direct.setFavorite(s, !favorite);
          if (favorite) {
            context
                .read<PlayerProvider>()
                .onAnchorSongRemoved(PlayerProvider.anchorForLiked(), s);
          }
          AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢', isError: false);
        },
      ),
      _toolButton(
        context,
        icon: disliked ? Icons.thumb_down : Icons.thumb_down_outlined,
        iconSize: icon,
        color: disliked ? Colors.orange : cs.onSurface.withValues(alpha: 0.55),
        tooltip: disliked ? '取消不喜欢' : '不喜欢（权重降到 0.1）',
        onPressed: () {
          Haptics.fire(HapticStrength.light);
          direct.setDisliked(s, !disliked);
          AppToast.show(!disliked ? '已标记不喜欢，权重降到 0.1' : '已取消不喜欢',
              isError: false);
        },
      ),
      _toolButton(
        context,
        icon: Icons.playlist_add_check,
        iconSize: icon,
        color: cs.onSurface.withValues(alpha: 0.55),
        tooltip: '编辑歌单',
        onPressed: () {
          Haptics.fire(HapticStrength.light);
          showEditPlaylistsSheet(context, s);
        },
      ),
      _toolButton(
        context,
        icon: Icons.download_outlined,
        iconSize: icon,
        color: cached ? cs.primary : cs.onSurface.withValues(alpha: 0.55),
        tooltip: cached ? '已缓存（可离线播放）' : '缓存歌曲',
        onPressed: () {
          Haptics.fire(HapticStrength.light);
          _cache(context, s);
        },
      ),
      AppVolumeButton(
        player: player,
        scale: scale,
        iconSize: kPlayerSecondaryIconSize,
        buttonSize: kPlayerSecondaryButtonSize * scale,
        padding: EdgeInsets.zero,
      ),
    ];
    final gap = kPlayerToolGap * scale;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12 * scale),
      // 与主控制行同构：内容定宽、居中，宽度随按钮与间距自然得出
      // （[kPlayerToolRowWidth] × scale），窗口再宽也不外扩。
      // 放不下时（手机横屏左列等）等比收缩，同 [ControlRow]。
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                buttons[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 工具按钮统一形态：固定命中区 + 居中图标，与 [ModeButton] /
  /// [AppVolumeButton] 的「48×scale 命中区、22×scale 图标」口径一致。
  Widget _toolButton(
    BuildContext context, {
    required IconData icon,
    required double iconSize,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      iconSize: iconSize,
      tooltip: tooltip,
      color: color,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(
        width: kPlayerSecondaryButtonSize * scale,
        height: kPlayerSecondaryButtonSize * scale,
      ),
      style: IconButton.styleFrom(
        fixedSize: Size(
          kPlayerSecondaryButtonSize * scale,
          kPlayerSecondaryButtonSize * scale,
        ),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// 主控制区（定时 - 上一首 - 播放 - 下一首 - 播放模式）：竖屏/横屏共用。
///
/// 五枚控件统一口径：次级键（定时 / 模式）[kPlayerSecondaryButtonSize] ×
/// scale 命中区，切歌键 [kPlayerSkipButtonSize] × scale 命中区，播放键
/// [kPlayerPrimaryButtonSize] × scale。旧实现里定时/模式是固定 48，切歌键
/// 则是「图标 + 默认内边距」推出来的不定值，4K 下同一行出现 48/60 两种
/// 命中区，视觉上按键大小不一。
class ControlRow extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;
  const ControlRow({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final secondary = kPlayerSecondaryButtonSize * scale;
    final skip = kPlayerSkipButtonSize * scale;
    final skipIcon = kPlayerSkipIconSize * scale;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SleepButton(player: player, cs: cs, scale: scale),
        SizedBox(width: 8 * scale),
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: skip,
            height: skip,
            child: Center(
              child: Icon(Icons.skip_previous, size: skipIcon),
            ),
          ),
        ),
        PlayPauseButton(
          player: player,
          cs: cs,
          size: kPlayerPrimaryButtonSize * scale,
          // 内边距同样随 scale：本行宽度才能严格正比于 scale，
          // 与工具行的宽度比值在所有档位保持恒定。
          padding: EdgeInsets.all(kPlayerPrimaryButtonPadding * scale),
        ),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: skip,
            height: skip,
            child: Center(
              child: Icon(Icons.skip_next, size: skipIcon),
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        ModeButton(
            player: player,
            cs: cs,
            scale: scale,
            buttonSize: secondary,
            padding: EdgeInsets.zero),
      ],
    );
    // 极窄竖屏（如 360 宽、内容区 312）整行比内容区宽 2px：只在这种情况下
    // 等比收缩，正常宽度零影响。
    return Center(
      child: FittedBox(fit: BoxFit.scaleDown, child: row),
    );
  }
}

/// 睡眠定时按钮：激活时高亮，点击弹出四种模式对话框。
class SleepButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;

  const SleepButton({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final active = player.sleepTimerActive;
    final summary = player.sleepSummaryText;
    final size = kPlayerSecondaryButtonSize * scale;
    return IconButton(
      iconSize: kPlayerSecondaryIconSize * scale,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      style: IconButton.styleFrom(
        fixedSize: Size(size, size),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      tooltip: '睡眠定时${active && summary != null ? '：$summary' : ''}',
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      onPressed: () {
        Haptics.fire(HapticStrength.light);
        showSleepTimerDialog(context);
      },
    );
  }
}
