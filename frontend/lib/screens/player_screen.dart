import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../widgets/add_to_playlist.dart';

/// 全屏播放页（ui-playpage.html v5）：作为「首页」整屏展示，替换整个壳层。
/// 左滑返回主页/右滑进歌词页暂以「收起箭头」代替；布局与配色对齐 v5 设计稿。
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final player = context.watch<PlayerProvider>();

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down),
                        iconSize: 30,
                        tooltip: '收起播放页',
                        onPressed: nav.closePlayer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!player.hasCurrent)
                      const _EmptyState()
                    else
                      _NowPlaying(player: player, direct: context.watch<DirectSourceManager>(), cs: Theme.of(context).colorScheme),
                    if (player.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          player.error!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 未在播放时的首页空态。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 48),
        Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(Icons.music_note, size: 120, color: cs.primary.withValues(alpha: 0.55)),
        ),
        const SizedBox(height: 32),
        Text('未在播放', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '从左侧导航选择歌曲开始播放',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 48),
      ],
    );
  }
}

/// v5 设计稿主体：封面 / 歌曲信息 / 工具行 / 进度 / 主控制行。
class _NowPlaying extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  const _NowPlaying({required this.player, required this.direct, required this.cs});

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    final favorite = direct.weight.isFavorite(s);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Cover(coverPath: s.coverPath, song: s, cs: cs),
        const SizedBox(height: 20),
        Text(
          s.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          s.artist ?? 'Unknown',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            Text(
              '${s.source} · ${s.format ?? ''} · ${s.duration ?? ''}s',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            if (direct.settings.playerShowWeight)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(const SnackBar(content: Text('当前曲目的播放权重'))),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.speed, size: 12, color: cs.onSurface.withValues(alpha: 0.6)),
                      const SizedBox(width: 4),
                      Text(
                        '权重 ${player.currentWeightFactor?.toStringAsFixed(1) ?? '—'}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        // 工具行（低频操作，颜色更浅）
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                iconSize: 22,
                tooltip: favorite ? '取消喜欢' : '喜欢',
                color: favorite ? Colors.pink : cs.onSurface.withValues(alpha: 0.55),
                icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
                onPressed: () => direct.setFavorite(s, !favorite),
              ),
              IconButton(
                iconSize: 22,
                tooltip: '不喜欢（降低权重）',
                color: cs.onSurface.withValues(alpha: 0.55),
                icon: const Icon(Icons.thumb_down_outlined),
                onPressed: () {
                  direct.dislikeSong(s);
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(const SnackBar(content: Text('已下调该曲权重')));
                },
              ),
              IconButton(
                iconSize: 22,
                tooltip: '加入歌单',
                color: cs.onSurface.withValues(alpha: 0.55),
                icon: const Icon(Icons.playlist_add),
                onPressed: () => showAddToPlaylistSheet(context, s),
              ),
              IconButton(
                iconSize: 22,
                tooltip: '缓存歌曲',
                color: cs.onSurface.withValues(alpha: 0.55),
                icon: const Icon(Icons.download),
                onPressed: () => _cache(context, s),
              ),
            ],
          ),
        ),
        _PlayerSeek(player: player, cs: cs),
        const SizedBox(height: 6),
        // 主控制区（定时 - 上一首 - 播放 - 下一首 - 播放模式）
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SleepButton(player: player, cs: cs),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 34),
              onPressed: player.prev,
            ),
            StreamBuilder<PlayerState>(
              stream: player.player.playerStateStream,
              builder: (c, snap) {
                final playing = snap.data?.playing ?? false;
                return IconButton(
                  iconSize: 74,
                  icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                  color: cs.primary,
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: player.toggle,
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 34),
              onPressed: player.next,
            ),
            const SizedBox(width: 8),
            _ModeButton(player: player, cs: cs),
          ],
        ),
      ],
    );
  }

  Future<void> _cache(BuildContext context, Song s) async {
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null || !s.isDirect) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('仅直连歌曲可缓存')));
      return;
    }
    await direct.cacheSong(src, s);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已开始缓存')));
    }
  }
}

/// 专辑封面：方形圆角 + 右上角更多操作。
class _Cover extends StatelessWidget {
  final String? coverPath;
  final Song song;
  final ColorScheme cs;

  const _Cover({required this.coverPath, required this.song, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: cs.primary.withValues(alpha: 0.10),
                  child: coverPath != null
                      ? Image.file(
                          File(coverPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.music_note,
                            size: 96,
                            color: cs.primary.withValues(alpha: 0.5),
                          ),
                        )
                      : Icon(Icons.music_note,
                          size: 96, color: cs.primary.withValues(alpha: 0.5)),
                ),
              ),
              Positioned(
                top: 10,
                right: 10,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: const CircleBorder(),
                  child: PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz, color: Colors.black87, size: 18),
                    padding: EdgeInsets.zero,
                    onSelected: (v) => _onSelected(context, v),
                    itemBuilder: (c) => [
                      const PopupMenuItem(value: 'playlist', child: Text('加入歌单')),
                      if (song.isDirect)
                        const PopupMenuItem(value: 'cache', child: Text('缓存')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onSelected(BuildContext context, String v) {
    if (v == 'playlist') {
      showAddToPlaylistSheet(context, song);
    } else if (v == 'cache') {
      final direct = context.read<DirectSourceManager>();
      final src = direct.sourceByKey(song.sourceKey);
      if (src == null || !song.isDirect) return;
      direct.cacheSong(src, song);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已开始缓存')));
    }
  }
}

/// 睡眠定时按钮：激活时高亮，点击弹出时长选择。
class _SleepButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  const _SleepButton({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    final active = player.sleepTimerActive;
    return IconButton(
      iconSize: 22,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '睡眠定时${active ? '：${player.sleepMinutes} 分钟后暂停' : ''}',
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      onPressed: () => _pick(context),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final sel = await showModalBottomSheet<int>(
      context: context,
      builder: (c) {
        final cs = Theme.of(c).colorScheme;
        Future<void> choose(int v) async {
          Navigator.of(c).pop(v);
        }

        Widget tile(int v, String label) {
          final isCurrent = player.sleepTimerActive && player.sleepMinutes == v;
          return ListTile(
            leading: Icon(isCurrent ? Icons.check_circle : Icons.timer_outlined,
                color: isCurrent ? cs.primary : null),
            title: Text(v <= 0 ? '关闭定时' : '$label 后暂停'),
            selected: isCurrent,
            onTap: () => choose(v),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('睡眠定时', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              tile(0, '—'),
              tile(15, '15 分钟'),
              tile(30, '30 分钟'),
              tile(60, '60 分钟'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (sel != null) {
      player.setSleepTimer(sel);
    }
  }
}

/// 播放模式：单击循环切换，非「顺序播放」时高亮。
class _ModeButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  const _ModeButton({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    final m = player.mode;
    final active = m != PlayMode.sequence;
    return IconButton(
      iconSize: 22,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '播放模式：${_label(m)}（点击切换）',
      icon: Icon(_icon(m)),
      onPressed: () {
        final next = PlayMode.values[(m.index + 1) % PlayMode.values.length];
        player.setMode(next);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('播放模式：${_label(next)}'),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ));
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
        PlayMode.weighted => '加权随机',
      };
}

/// 进度条（v5 设计稿：细进度 + 下方时间标签）。
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
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: widget.cs.primary,
                inactiveTrackColor: widget.cs.onSurface.withValues(alpha: 0.12),
                thumbColor: widget.cs.primary,
              ),
              child: Slider(
                min: 0,
                max: max == 0 ? 1 : max,
                value: cur,
                onChanged: (v) => widget.player.seek(Duration(milliseconds: v.toInt())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(pos), style: const TextStyle(fontFamily: 'monospace')),
                  Text(_fmt(dur), style: const TextStyle(fontFamily: 'monospace')),
                ],
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