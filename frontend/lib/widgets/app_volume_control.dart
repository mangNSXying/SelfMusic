import 'package:flutter/material.dart';

import '../providers/player_provider.dart';

IconData appVolumeIcon(int volume) {
  if (volume <= 0) return Icons.volume_off;
  if (volume < 50) return Icons.volume_down;
  return Icons.volume_up;
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
          icon: Icon(appVolumeIcon(volume)),
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
                  Text('应用内音量', style: textTheme.titleMedium),
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
                    icon: Icon(appVolumeIcon(volume)),
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
