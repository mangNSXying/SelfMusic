import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'selection_bar.dart';

enum FavoriteAction { like, unlike }

List<SelectionAction> songSelectionActions(
  BuildContext context,
  List<Song> selected,
  VoidCallback clear, {
  FavoriteAction favorite = FavoriteAction.like,
  void Function(List<Song> deleted)? onDeleted,
}) {
  final direct = context.read<DirectSourceManager>();
  final player = context.read<PlayerProvider>();
  final cacheable = <Song>[];
  final deletable = <Song>[];
  for (final s in selected) {
    if (!s.isDirect) continue;
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null) continue;
    cacheable.add(s);
    if (src.supportsWrite) deletable.add(s);
  }

  return [
    SelectionAction(
      icon: favorite == FavoriteAction.unlike
          ? Icons.favorite
          : Icons.favorite_border,
      label: favorite == FavoriteAction.unlike ? '取消喜欢' : '喜欢',
      onPressed: selected.isEmpty
          ? null
          : () => _setFavorite(
                direct,
                player,
                selected,
                clear,
                like: favorite == FavoriteAction.like,
              ),
    ),
    SelectionAction(
      icon: Icons.thumb_down_outlined,
      label: '不喜欢',
      onPressed:
          selected.isEmpty ? null : () => _setDisliked(direct, selected, clear),
    ),
    SelectionAction(
      icon: Icons.download,
      label: '缓存',
      onPressed: cacheable.isEmpty
          ? null
          : () => _cache(
                direct,
                cacheable,
                clear,
                skipped: selected.length - cacheable.length,
              ),
    ),
    SelectionAction(
      icon: Icons.delete_outline,
      label: '删除',
      onPressed: deletable.isEmpty
          ? null
          : () => _delete(
                context,
                direct,
                player,
                deletable,
                clear,
                total: selected.length,
                onDeleted: onDeleted,
              ),
    ),
  ];
}

void _setFavorite(
  DirectSourceManager direct,
  PlayerProvider player,
  List<Song> selected,
  VoidCallback clear, {
  required bool like,
}) {
  clear();
  for (final s in selected) {
    unawaited(direct.setFavorite(s, like));
    if (!like) {
      unawaited(player.onAnchorSongRemoved(PlayerProvider.anchorForLiked(), s));
    }
  }
  AppToast.show(
    like ? '已加入喜欢 ${selected.length} 首' : '已取消喜欢 ${selected.length} 首',
    isError: false,
  );
}

void _setDisliked(
    DirectSourceManager direct, List<Song> selected, VoidCallback clear) {
  clear();
  for (final s in selected) {
    unawaited(direct.setDisliked(s, true));
  }
  AppToast.show(
    '已标记不喜欢 ${selected.length} 首，权重降到 0.1',
    isError: false,
  );
}

Future<void> _cache(
  DirectSourceManager direct,
  List<Song> songs,
  VoidCallback clear, {
  required int skipped,
}) async {
  clear();
  var ok = 0;
  var failed = 0;
  Object? firstError;
  for (var i = 0; i < songs.length; i++) {
    final s = songs[i];
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null) {
      failed++;
      continue;
    }
    try {
      await direct.cacheSong(src, s);
      ok++;
    } catch (e) {
      failed++;
      firstError ??= e;
    }
    if (songs.length > 1) {
      AppToast.show('缓存中 ${i + 1}/${songs.length}…', isError: false);
    }
  }
  final skipText = skipped > 0 ? '，跳过 $skipped 首' : '';
  if (failed == 0) {
    AppToast.show('已缓存 $ok 首$skipText', isError: false);
  } else if (ok == 0) {
    AppToast.error(firstError ?? '缓存失败', '缓存失败');
  } else {
    AppToast.show(
      '缓存完成：成功 $ok 首，失败 $failed 首$skipText',
      isError: true,
    );
  }
}

Future<void> _delete(
  BuildContext context,
  DirectSourceManager direct,
  PlayerProvider player,
  List<Song> songs,
  VoidCallback clear, {
  required int total,
  void Function(List<Song> deleted)? onDeleted,
}) async {
  if (songs.isEmpty) return;
  final skipped = total - songs.length;
  final skipText = skipped > 0 ? '另有 $skipped 首为非直连或只读源，将跳过。\n' : '';
  final ok1 = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('删除歌曲文件？'),
      content: Text('将从对应播放源永久删除选中的 ${songs.length} 首歌曲，\n'
          '并清除本地索引、收藏权重、歌词、歌单条目与离线缓存。\n'
          '$skipText此操作不可恢复。'),
      actions: appDialogActions(
        c,
        confirmLabel: '继续删除',
        destructive: true,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok1 != true || !context.mounted) return;
  final ok2 = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('再次确认删除'),
      content: Text('确认永久删除这 ${songs.length} 首歌曲？'),
      actions: appDialogActions(
        c,
        confirmLabel: '确认删除',
        destructive: true,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok2 != true || !context.mounted) return;

  clear();
  final deleted = <Song>[];
  Object? firstError;
  for (final s in songs) {
    try {
      await direct.deleteSong(s);
      deleted.add(s);
      for (final anchor in [
        PlayerProvider.anchorForSource(s.sourceKey),
        PlayerProvider.anchorForSongs(),
        PlayerProvider.anchorForLiked(),
      ]) {
        unawaited(player.onAnchorSongRemoved(anchor, s));
      }
    } catch (e) {
      firstError ??= e;
    }
  }
  if (deleted.isNotEmpty) onDeleted?.call(deleted);
  if (deleted.length == songs.length) {
    AppToast.show('已删除 ${deleted.length} 首', isError: false);
  } else if (deleted.isEmpty) {
    AppToast.error(firstError ?? '删除失败', '删除失败');
  } else {
    AppToast.show(
      '删除完成：成功 ${deleted.length} 首，失败 ${songs.length - deleted.length} 首',
      isError: true,
    );
  }
}
