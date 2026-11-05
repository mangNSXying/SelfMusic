import 'package:flutter/material.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import 'song_row_view.dart';
import 'song_tile.dart';

/// 播放队列共用行（整页队列 / 窄屏弹层 / 宽屏面板）。
///
/// 行数据统一走 [SongRowCache]；是否多选、是否带「移除」菜单由调用方决定。
class QueueSongTile extends StatelessWidget {
  final Song song;

  /// 行在展示序列中的下标（用于 [SongRowCache] 缓存键）。
  final int index;
  final bool playing;
  final SongRowCache cache;
  final DirectSourceManager direct;
  final bool wide;
  final VoidCallback onEnsureMeta;
  final VoidCallback onPlay;

  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelect;
  final VoidCallback? onStartSelect;

  final bool showRemove;
  final VoidCallback? onRemove;

  const QueueSongTile({
    super.key,
    required this.song,
    required this.index,
    required this.playing,
    required this.cache,
    required this.direct,
    required this.wide,
    required this.onEnsureMeta,
    required this.onPlay,
    this.selectionMode = false,
    this.selected = false,
    this.onSelect,
    this.onStartSelect,
    this.showRemove = false,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return SongTile(
      song: song,
      source: null,
      playing: playing,
      row: cache.rowAt(index, () {
        onEnsureMeta();
        final meta = direct.weight.metaOf(song);
        return SongRowView.of(
          song: song,
          titleFormat: direct.settings.songTitleFormat,
          sourceName: direct.sourceByKey(song.sourceKey)?.name,
          favorite: meta.favorite,
          disliked: meta.frozen,
          wide: wide,
        );
      }),
      selectionMode: selectionMode,
      selected: selected,
      onSelect: onSelect,
      onStartSelect: onStartSelect,
      onPlay: onPlay,
      extraMenuItems: showRemove
          ? const [PopupMenuItem(value: 'row:remove', child: Text('移除'))]
          : null,
      onExtraMenu: showRemove
          ? (v) {
              if (v == 'row:remove') onRemove?.call();
            }
          : null,
    );
  }
}
