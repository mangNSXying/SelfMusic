import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import 'add_to_playlist.dart';

/// 通用歌曲条目：封面缩略图 + 标题 + 歌手/专辑 + 时长时间器。
///
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
class SongTile extends StatelessWidget {
  final Song song;
  final MusicSource source;
  final VoidCallback onPlay;
  const SongTile({
    super.key,
    required this.song,
    required this.source,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final favorite = direct.weight.isFavorite(song);
    return ListTile(
      leading: CoverThumb(coverPath: song.coverPath),
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
            visualDensity: VisualDensity.compact,
            icon: Icon(
              favorite ? Icons.favorite : Icons.favorite_border,
              color: favorite ? Colors.pink : null,
            ),
            tooltip: favorite ? '取消喜欢' : '喜欢',
            onPressed: () => direct.setFavorite(song, !favorite),
          ),
          if (song.isDirect)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.download),
              tooltip: '缓存以便离线播放',
              onPressed: () async {
                try {
                  await direct.cacheSong(source, song);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已缓存，可离线播放')));
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
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'playlist') {
                showAddToPlaylistSheet(context, song);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'playlist', child: Text('加入歌单')),
            ],
          ),
        ],
      ),
      onTap: onPlay,
    );
  }
}

/// 封面缩略图（直连模式本地缓存封面）；无封面时回退音符图标。
class CoverThumb extends StatelessWidget {
  final String? coverPath;
  const CoverThumb({super.key, this.coverPath});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    if (coverPath == null) {
      return Icon(Icons.music_note, color: color);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(coverPath!),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: color),
      ),
    );
  }
}