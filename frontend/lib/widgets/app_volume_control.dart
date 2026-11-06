import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../providers/player_provider.dart';

/// 音量声波档位（0~3）：0=静音（无声波，带斜杠），1~3=声波数量。
///
/// 播放页/设置页图标共用：>70% 满三格，低音量一格，中音量两格。
int appVolumeWaveCount(int volume) {
  if (volume <= 0) return 0;
  if (volume <= 35) return 1;
  if (volume <= 70) return 2;
  return 3;
}

/// 应用内音量图标：喇叭固定，声波数量随 [volume] 变化。
class AppVolumeIcon extends StatelessWidget {
  const AppVolumeIcon({
    super.key,
    required this.volume,
    this.size,
    this.color,
  });

  final int volume;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor =
        color ?? iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: resolvedSize,
      height: resolvedSize,
      child: CustomPaint(
        painter: _VolumeIconPainter(volume: volume, color: resolvedColor),
      ),
    );
  }
}

/// 喇叭 + 声波/静音斜杠。24×24 坐标系，矢量绘制保证 0~3 格声波间距一致。
class _VolumeIconPainter extends CustomPainter {
  const _VolumeIconPainter({required this.volume, required this.color});

  final int volume;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    if (scale <= 0) return;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.scale(scale);

    // 喇叭本体（与 Material volume 图标同形的实心轮廓）。
    final speaker = Path()
      ..moveTo(3, 9)
      ..lineTo(7, 9)
      ..lineTo(12, 4)
      ..lineTo(12, 20)
      ..lineTo(7, 15)
      ..lineTo(3, 15)
      ..close();
    canvas.drawPath(speaker, fill);

    final waves = appVolumeWaveCount(volume);
    if (waves == 0) {
      // 静音：无声波 + 斜杠。
      final slash = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(3.5, 3), const Offset(21, 20.5), slash);
    } else {
      const center = Offset(12, 12);
      const radii = [3.1, 6.1, 9.1];
      const startAngle = -math.pi / 4;
      const sweepAngle = math.pi / 2;
      for (var i = 0; i < waves && i < radii.length; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radii[i]),
          startAngle,
          sweepAngle,
          false,
          stroke,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VolumeIconPainter oldDelegate) =>
      oldDelegate.volume != volume || oldDelegate.color != color;
}

Future<void> showAppVolumeSheet(
  BuildContext context,
  PlayerProvider player,
) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (_) => _AppVolumeSheet(player: player),
  );
}

class AppVolumeButton extends StatelessWidget {
  const AppVolumeButton({
    super.key,
    required this.player,
    this.scale = 1.0,
    this.iconSize = 22,
  });

  final PlayerProvider player;
  final double scale;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final volume = player.appVolume;
        return IconButton(
          iconSize: iconSize * scale,
          tooltip: volume == 0 ? '取消静音' : '音量 $volume%',
          color:
              volume == 0 ? cs.primary : cs.onSurface.withValues(alpha: 0.55),
          icon: AppVolumeIcon(volume: volume),
          onPressed: () => showAppVolumeSheet(context, player),
        );
      },
    );
  }
}

class _AppVolumeSheet extends StatelessWidget {
  const _AppVolumeSheet({required this.player});

  final PlayerProvider player;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final volume = player.appVolume;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('应用音量', style: textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    '$volume%',
                    style: textTheme.titleMedium?.copyWith(color: cs.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: volume == 0 ? '取消静音' : '静音',
                    icon: AppVolumeIcon(volume: volume),
                    onPressed: player.toggleAppVolumeMute,
                  ),
                  Expanded(
                    child: Slider(
                      value: volume.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      label: '$volume%',
                      onChanged: (v) => player.setAppVolume(v.round()),
                    ),
                  ),
                ],
              ),
              Text(
                '独立于系统音量；0% 静音但播放继续',
                style: textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
