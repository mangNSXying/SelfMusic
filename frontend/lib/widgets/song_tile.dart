import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import 'add_to_playlist.dart';
import 'app_toast.dart';

/// 通用歌曲条目：封面缩略图 + 标题 + 歌手/专辑/专辑歌手 + 时长时间器。
///
/// 收藏/不喜欢/缓存等操作统一收进右侧三点菜单（列表保持清爽，方便多选）。
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
///
/// 多选模式：当 [selectionMode] 为 true 时，leading 变为选择框，
/// 点击条目切换勾选，[onSelect] 负责切换 [selected]。
class SongTile extends StatelessWidget {
  final Song song;
  final MusicSource source;
  final VoidCallback onPlay;

  /// 多选模式：true 时显示勾选框并以选中态渲染。
  final bool selectionMode;

  /// 当前条目是否被选中（多选模式下）。
  final bool selected;

  /// 多选模式下切换本条目选中状态；非多选时为空。
  final VoidCallback? onSelect;

  /// 长按进入多选模式并选中本条目（非多选模式下生效）。
  final VoidCallback? onStartSelect;

  const SongTile({
    super.key,
    required this.song,
    required this.source,
    required this.onPlay,
    this.selectionMode = false,
    this.selected = false,
    this.onSelect,
    this.onStartSelect,
  });

  /// 副标题：歌手 · 专辑（· 专辑歌手，仅当与歌手不同时展示，避免冗余）。
  String get _subtitle {
    final artist = song.artist ?? 'Unknown';
    final parts = <String>[artist];
    final album = song.albumName;
    if (album != null && album.isNotEmpty) parts.add(album);
    final albumArtist = song.albumArtist;
    if (albumArtist != null && albumArtist.isNotEmpty && albumArtist != artist) {
      parts.add('专辑歌手：$albumArtist');
    }
    return parts.join(' · ');
  }

  Future<void> _cacheSong(BuildContext context, DirectSourceManager direct) async {
    try {
      await direct.cacheSong(source, song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已缓存，可离线播放')));
      }
    } catch (e) {
      AppToast.error(e, '缓存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final favorite = direct.weight.isFavorite(song);
    final disliked = direct.weight.isDisliked(song);
    return ListTile(
      selected: selectionMode && selected,
      leading: selectionMode
          ? Checkbox(
              value: selected,
              onChanged: (_) => onSelect?.call(),
            )
          : CoverThumb(coverPath: song.coverPath),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: selectionMode && selected
            ? TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      subtitle: Text(
        _subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: selectionMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(song.duration != null ? '${song.duration}s' : ''),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    switch (v) {
                      case 'favorite':
                        direct.setFavorite(song, !favorite);
                        AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢',
                            isError: false);
                        break;
                      case 'dislike':
                        direct.setDisliked(song, !disliked);
                        AppToast.show(
                            !disliked ? '已标记不喜欢，权重降到最低' : '已取消不喜欢',
                            isError: false);
                        break;
                      case 'cache':
                        unawaited(_cacheSong(context, direct));
                        break;
                      case 'playlist':
                        showAddToPlaylistSheet(context, song);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'favorite',
                      child: Row(
                        children: [
                          Icon(
                            favorite ? Icons.favorite : Icons.favorite_border,
                            color: favorite ? Colors.pink : null,
                          ),
                          const SizedBox(width: 12),
                          Text(favorite ? '取消喜欢' : '喜欢'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'dislike',
                      child: Row(
                        children: [
                          Icon(
                            disliked
                                ? Icons.thumb_down
                                : Icons.thumb_down_outlined,
                            color: disliked ? Colors.orange : null,
                          ),
                          const SizedBox(width: 12),
                          Text(disliked ? '取消不喜欢' : '不喜欢（权重降到最低）'),
                        ],
                      ),
                    ),
                    if (song.isDirect)
                      const PopupMenuItem(
                        value: 'cache',
                        child: Row(
                          children: [
                            Icon(Icons.download),
                            SizedBox(width: 12),
                            Text('缓存以便离线播放'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'playlist',
                      child: Row(
                        children: [
                          Icon(Icons.playlist_add),
                          SizedBox(width: 12),
                          Text('加入歌单'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
      onTap: selectionMode ? onSelect : onPlay,
      onLongPress: selectionMode ? onSelect : onStartSelect,
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