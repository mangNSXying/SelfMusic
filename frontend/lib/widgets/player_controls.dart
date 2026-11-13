import 'package:flutter/material.dart';

import '../providers/player_provider.dart';
import '../utils/duration_format.dart';
import 'app_toast.dart';
import 'pressable.dart';

/// 播放模式：单击循环切换，非「顺序播放」时高亮。
class ModeButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;

  const ModeButton({
    super.key,
    required this.player,
    required this.cs,
    this.scale = 1.0,
  });

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
///
/// [inlineTime] 为迷你条紧凑用法：时间在轨道两端上方、轨道铺满宽度，
/// 隐藏断网提示；[compact] 与播放页共用同一 Slider，只套紧凑主题
/// （5px 轨 / 10 thumb / overlay 0），供固定高度横屏条使用。
class PlayerSeek extends StatefulWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  /// 进度条下方是否显示时间（横屏三列页隐藏，把空间留给封面）。
  final bool showTime;

  /// 时间是否内联：位于轨道两端上方；迷你条使用。
  final bool inlineTime;

  /// inlineTime 时进度区的固定高度；迷你条按 56 - play 传入。
  final double inlineHeight;

  /// 紧凑轨道/滑块/高度；播放页使用默认值。
  final bool compact;

  /// 进度条/时间字号缩放。
  final double scale;

  const PlayerSeek({
    super.key,
    required this.player,
    required this.cs,
    this.showTime = true,
    this.inlineTime = false,
    this.inlineHeight = 16,
    this.compact = false,
    this.scale = 1.0,
  });

  @override
  State<PlayerSeek> createState() => _PlayerSeekState();
}

/// 播放/暂停主键（竖屏控制行与横屏竖向控制共用）。
class PlayPauseButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double size;

  /// 按压缩放外的内边距；迷你条固定高度时传 EdgeInsets.zero。
  final EdgeInsetsGeometry padding;

  const PlayPauseButton({
    super.key,
    required this.player,
    required this.cs,
    required this.size,
    this.padding = const EdgeInsets.all(8),
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (c, _) {
        // 目标态（provider.playing）：点击后一帧内翻转，不等音频淡出完成。
        final playing = player.playing;
        return Pressable(
          onPressed: player.toggle,
          tooltip: playing ? '暂停' : '播放',
          pressedScale: 0.85,
          padding: padding,
          child: Icon(
            playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: size,
            color: cs.primary,
          ),
        );
      },
    );
  }
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

        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: widget.compact ? 5 : 4 * widget.scale,
            thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: widget.compact ? 5 : 6 * widget.scale),
            overlayShape: RoundSliderOverlayShape(
                overlayRadius: widget.compact ? 0 : 14 * widget.scale),
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
        );

        if (widget.inlineTime) {
          final timeStyle = TextStyle(
            fontFamily: 'monospace',
            fontSize: 14 * widget.scale,
            color: widget.cs.onSurface.withValues(alpha: 0.62),
          );
          return SizedBox(
            height: widget.inlineHeight,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: slider,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Row(
                    children: [
                      Text(
                        formatClock(Duration(milliseconds: shown.toInt())),
                        maxLines: 1,
                        style: timeStyle,
                      ),
                      const Spacer(),
                      Text(
                        formatClock(dur),
                        maxLines: 1,
                        style: timeStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.compact && widget.player.reconnecting)
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
            slider,
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
