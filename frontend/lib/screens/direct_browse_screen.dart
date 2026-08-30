import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';

/// 直连模式浏览/搜索页（阶段 3 验收核心：扫描 → 搜索 → 播放 → 收藏 → 缓存）。
class DirectBrowseScreen extends StatefulWidget {
  final String sourceKey;
  const DirectBrowseScreen({super.key, required this.sourceKey});

  @override
  State<DirectBrowseScreen> createState() => _DirectBrowseScreenState();
}

class _DirectBrowseScreenState extends State<DirectBrowseScreen> {
  String _query = '';
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final source = direct.sourceByKey(widget.sourceKey);
    if (source == null || !source.supportsDirect) {
      return const Center(child: Text('该源不可用或暂不支持直连（阶段 4）'));
    }
    final songs = direct.songsOf(widget.sourceKey, query: _query);
    final count = direct.countOf(widget.sourceKey);

    return Scaffold(
      appBar: AppBar(title: Text(source.key)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '搜索该源曲目（标题/歌手/专辑）',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _scanning ? null : () => _scan(source, direct),
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('扫描'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已索引 $count 首 · ${source.key}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const Divider(height: 16),
          if (direct.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(direct.error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
            ),
          Expanded(
            child: songs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.library_music_outlined,
                            size: 64,
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.4)),
                        const SizedBox(height: 12),
                        const Text('暂无索引曲目，点击"扫描"建立本地索引'),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (c, i) => _SongTile(
                      song: songs[i],
                      source: source,
                      onPlay: () => _play(c, source, songs, i),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _scan(MusicSource source, DirectSourceManager direct) async {
    setState(() => _scanning = true);
    try {
      final summary = await direct.scanSource(widget.sourceKey);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('扫描完成：新增 ${summary.added} 首，共 ${summary.total} 首')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('扫描失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _play(BuildContext c, MusicSource source, List<Song> songs, int i) {
    final player = c.read<PlayerProvider>();
    player.playQueue(songs, index: i, source: source);
    c.read<NavigationProvider>().openPlayer();
  }
}

class _SongTile extends StatelessWidget {
  final Song song;
  final MusicSource source;
  final VoidCallback onPlay;
  const _SongTile(
      {required this.song, required this.source, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    return ListTile(
      leading: song.coverPath != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(song.coverPath!),
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.music_note,
                    color: Theme.of(context).colorScheme.primary),
              ),
            )
          : Icon(Icons.music_note,
              color: Theme.of(context).colorScheme.primary),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${song.artist ?? "Unknown"} · ${song.albumName ?? ""}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              song.favorite ? Icons.favorite : Icons.favorite_border,
              color: song.favorite ? Colors.pink : null,
            ),
            onPressed: () => direct.setFavorite(song, !song.favorite),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '缓存以便离线播放',
            onPressed: () async {
              try {
                await direct.cacheSong(source, song);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('已缓存，可离线播放')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('缓存失败：$e')));
                }
              }
            },
          ),
          Text(song.duration != null ? '${song.duration}s' : ''),
        ],
      ),
      onTap: onPlay,
    );
  }
}
