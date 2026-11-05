import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../layout/player_metrics.dart';
import '../../models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../utils/duration_format.dart';
import '../../utils/song_title_format.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/add_to_playlist.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/app_volume_control.dart';
import '../../widgets/lyrics_view.dart';
import '../../widgets/marquee_text.dart';
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

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          children: [
            if (s != null)
              Padding(
                padding:
                    EdgeInsets.fromLTRB(24 * scale, 28 * scale, 24 * scale, 0),
                child: TitleBlock(
                    player: player,
                    direct: direct,
                    compact: true,
                    scale: scale),
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

/// 工具行（喜欢/不喜欢/编辑歌单/缓存）：竖屏/横屏共用。
class ToolRow extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;

  /// 横屏用：按钮紧凑成组居中（列宽较大时 spaceEvenly 会把按钮摊到列两缘，
  /// 与封面/标题的居中感不齐）；竖屏保持铺满一行均分。
  final bool center;
  final double scale;
  const ToolRow(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.center = false,
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
    final row = Row(
      mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment:
          center ? MainAxisAlignment.center : MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 22 * scale,
          tooltip: favorite ? '取消喜欢' : '喜欢',
          color: favorite ? Colors.pink : cs.onSurface.withValues(alpha: 0.55),
          icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
          onPressed: () {
            direct.setFavorite(s, !favorite);
            if (favorite) {
              context
                  .read<PlayerProvider>()
                  .onAnchorSongRemoved(PlayerProvider.anchorForLiked(), s);
            }
            AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢', isError: false);
          },
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: disliked ? '取消不喜欢' : '不喜欢（权重降到 0.1）',
          color:
              disliked ? Colors.orange : cs.onSurface.withValues(alpha: 0.55),
          icon: Icon(disliked ? Icons.thumb_down : Icons.thumb_down_outlined),
          onPressed: () {
            direct.setDisliked(s, !disliked);
            AppToast.show(!disliked ? '已标记不喜欢，权重降到 0.1' : '已取消不喜欢',
                isError: false);
          },
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: '编辑歌单',
          color: cs.onSurface.withValues(alpha: 0.55),
          icon: const Icon(Icons.playlist_add_check),
          onPressed: () => showEditPlaylistsSheet(context, s),
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: cached ? '已缓存（可离线播放）' : '缓存歌曲',
          color: cached ? cs.primary : cs.onSurface.withValues(alpha: 0.55),
          icon: const Icon(Icons.download_outlined),
          onPressed: () => _cache(context, s),
        ),
        AppVolumeButton(player: player, scale: scale),
      ],
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12 * scale),
      // 窄横屏左列放不下 5 个工具按钮时整体等比缩小，避免溢出。
      child: center
          ? Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: row),
            )
          : row,
    );
  }
}

/// 主控制区（定时 - 上一首 - 播放 - 下一首 - 播放模式）：竖屏/横屏共用。
class ControlRow extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;
  const ControlRow({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SleepButton(player: player, cs: cs, scale: scale),
        SizedBox(width: 8 * scale),
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          child: Icon(Icons.skip_previous, size: 34 * scale),
        ),
        ListenableBuilder(
          listenable: player,
          builder: (c, _) {
            // 目标态（provider.playing）：点击后一帧内翻转，不等音频淡出完成。
            final playing = player.playing;
            return Pressable(
              onPressed: player.toggle,
              tooltip: playing ? '暂停' : '播放',
              pressedScale: 0.85,
              child: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 74 * scale,
                  color: cs.primary),
            );
          },
        ),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          child: Icon(Icons.skip_next, size: 34 * scale),
        ),
        SizedBox(width: 8 * scale),
        ModeButton(player: player, cs: cs, scale: scale),
      ],
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
    return IconButton(
      iconSize: 22 * scale,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '睡眠定时${active && summary != null ? '：$summary' : ''}',
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      onPressed: () => showSleepTimerDialog(context),
    );
  }
}

/// 播放模式：单击循环切换，非「顺序播放」时高亮。
class ModeButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;

  const ModeButton({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final m = player.mode;
    final active = m != PlayMode.sequence;
    return IconButton(
      iconSize: 22 * scale,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '播放模式：${_label(m)}（点击切换）',
      icon: Icon(_icon(m)),
      onPressed: () {
        final next = PlayMode.values[(m.index + 1) % PlayMode.values.length];
        player.setMode(next);
        AppToast.show('播放模式：${_label(next)}', isError: false);
      },
    );
  }

  static IconData _icon(PlayMode m) => switch (m) {
        PlayMode.sequence => Icons.playlist_play_rounded,
        PlayMode.loopList => Icons.repeat_rounded,
        PlayMode.loopOne => Icons.repeat_one_rounded,
        PlayMode.weighted => Icons.shuffle_rounded,
      };

  static String _label(PlayMode m) => switch (m) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '随机播放',
      };
}

/// 进度条（v5 设计稿：细进度 + 下方时间标签）。
class PlayerSeek extends StatefulWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  /// 横屏三列页隐藏进度条下方时间，把空间留给封面。
  final bool showTime;

  /// 进度条/时间字号缩放。
  final double scale;
  const PlayerSeek(
      {required this.player,
      required this.cs,
      this.showTime = true,
      this.scale = 1.0});

  @override
  State<PlayerSeek> createState() => _PlayerSeekState();
}

class _PlayerSeekState extends State<PlayerSeek> {
  /// 拖动中的 thumb 位置（毫秒）：拖动过程只更新本地，松手才 seek 一次——
  /// 直播转码态每次 seek 都重开一条服务端流，逐 tick 发 seek 等于连续重启。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.player.positionStream,
      builder: (c, _) {
        // 位置/时长走 provider：断点恢复装载期返回乐观断点值（首帧进度即对），
        // 真实 seek 完成后自动切真实值；StreamBuilder 照常逐 tick 刷新播放进度。
        final pos = widget.player.position;
        final dur = widget.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final cur = pos.inMilliseconds
            .toDouble()
            .clamp(0, max == 0 ? 1 : max)
            .toDouble();
        final shown =
            _dragValue?.clamp(0, max == 0 ? 1 : max).toDouble() ?? cur;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.player.reconnecting)
              Padding(
                padding: EdgeInsets.only(bottom: 6 * widget.scale),
                child: Text(
                  '网络已断开，恢复后自动继续播放…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12 * widget.scale,
                    color: widget.cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4 * widget.scale,
                thumbShape:
                    RoundSliderThumbShape(enabledThumbRadius: 6 * widget.scale),
                overlayShape:
                    RoundSliderOverlayShape(overlayRadius: 14 * widget.scale),
                activeTrackColor: widget.cs.primary,
                inactiveTrackColor: widget.cs.onSurface.withValues(alpha: 0.12),
                thumbColor: widget.cs.primary,
              ),
              child: Slider(
                min: 0,
                max: max == 0 ? 1 : max,
                value: shown,
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  setState(() => _dragValue = null);
                  widget.player.seek(Duration(milliseconds: v.toInt()));
                },
              ),
            ),
            if (widget.showTime)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8 * widget.scale),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatClock(Duration(milliseconds: shown.toInt())),
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14 * widget.scale)),
                    Text(formatClock(dur),
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14 * widget.scale)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
