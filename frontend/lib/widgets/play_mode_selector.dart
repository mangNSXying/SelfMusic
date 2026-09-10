import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';

/// 播放模式选择（stage2.md §3）：顺序 / 列表循环 / 单曲循环 / 加权随机。
class PlayModeSelector extends StatelessWidget {
  const PlayModeSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final m in PlayMode.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IconButton(
              iconSize: 22,
              icon: Icon(_iconOf(m)),
              tooltip: _labelOf(m),
              color: player.mode == m ? scheme.primary : null,
              onPressed: () => player.setMode(m),
            ),
          ),
      ],
    );
  }

  static IconData _iconOf(PlayMode m) => switch (m) {
        PlayMode.sequence => Icons.playlist_play_rounded,
        PlayMode.loopList => Icons.repeat_rounded,
        PlayMode.loopOne => Icons.repeat_one_rounded,
        PlayMode.weighted => Icons.shuffle_rounded,
      };

  static String _labelOf(PlayMode m) => switch (m) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '加权随机',
      };
}