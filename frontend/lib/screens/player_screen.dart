import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/direct_source_manager.dart';
import '../widgets/play_mode_selector.dart';

/// 播放页（嵌入 AppShell 内容区，不再自带 Scaffold/AppBar）。
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;

    if (!player.hasCurrent) {
      return const Center(child: Text('未在播放'));
    }
    final s = player.current!;
    final favorite = direct.weight.isFavorite(s);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(Icons.music_note, size: 96, color: cs.primary),
              ),
              const SizedBox(height: 28),
              Text(s.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(s.artist ?? 'Unknown', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${s.source} · ${s.format ?? ""} · ${s.duration ?? ''}s',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 30,
                    icon: Icon(
                      favorite ? Icons.favorite : Icons.favorite_border,
                      color: favorite ? Colors.pink : null,
                    ),
                    tooltip: favorite ? '取消喜欢' : '喜欢',
                    onPressed: () => direct.setFavorite(s, !favorite),
                  ),
                  IconButton(
                    iconSize: 30,
                    icon: Icon(Icons.thumb_down_outlined,
                        color: cs.onSurface.withValues(alpha: 0.7)),
                    tooltip: '不喜欢（降低权重）',
                    onPressed: () {
                      direct.dislikeSong(s);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已下调该曲权重')));
                    },
                  ),
                  const SizedBox(width: 12),
                  Chip(
                    avatar: const Icon(Icons.speed, size: 16),
                    label: Text(
                        '权重 ${player.currentWeightFactor?.toStringAsFixed(1) ?? '—'}'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const PlayModeSelector(),
              const SizedBox(height: 16),
              _PlayerSeek(player: player, cs: cs),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(icon: const Icon(Icons.skip_previous, size: 36), onPressed: player.prev),
                  const SizedBox(width: 12),
                  StreamBuilder<PlayerState>(
                    stream: player.player.playerStateStream,
                    builder: (c, snap) {
                      final playing = snap.data?.playing ?? false;
                      return IconButton(
                        icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, size: 64),
                        color: cs.primary,
                        onPressed: player.toggle,
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  IconButton(icon: const Icon(Icons.skip_next, size: 36), onPressed: player.next),
                ],
              ),
              if (player.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(player.error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerSeek extends StatefulWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  const _PlayerSeek({required this.player, required this.cs});

  @override
  State<_PlayerSeek> createState() => _PlayerSeekState();
}

class _PlayerSeekState extends State<_PlayerSeek> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.player.positionStream,
      builder: (c, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = widget.player.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final cur = pos.inMilliseconds.toDouble().clamp(0, max == 0 ? 1 : max).toDouble();
        return Column(
          children: [
            Slider(
              min: 0,
              max: max == 0 ? 1 : max,
              value: cur,
              activeColor: widget.cs.primary,
              onChanged: (v) => widget.player.seek(Duration(milliseconds: v.toInt())),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text(_fmt(pos)), Text(_fmt(dur))],
              ),
            ),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
