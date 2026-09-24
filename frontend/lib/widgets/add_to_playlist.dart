import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/playlists_provider.dart';
import '../utils/song_title_format.dart';
import 'app_toast.dart';

/// 弹出「加入歌单」选择器（stage2.md §5）：底部弹层列出歌单，无歌单可现场新建。
Future<void> showAddToPlaylistSheet(BuildContext context, Song song) =>
    _showAddToPlaylist(context, [song]);

/// 多选批量加入：把多首歌曲一次加入目标歌单。
Future<void> showAddToPlaylistSheetForSongs(
        BuildContext context, List<Song> songs) =>
    _showAddToPlaylist(context, songs);

/// 播放页「编辑歌单」：列出全部歌单，点按行即加入/移出（不关闭弹层）。
Future<void> showEditPlaylistsSheet(BuildContext context, Song song) async {
  final provider = context.read<PlaylistsProvider>();
  if (!provider.loaded) provider.refresh();
  await showModalBottomSheet<void>(
    context: context,
    builder: (c) => _AddToPlaylistSheet(songs: [song], editMode: true),
  );
}

Future<void> _showAddToPlaylist(BuildContext context, List<Song> songs) async {
  final provider = context.read<PlaylistsProvider>();
  if (!provider.loaded) provider.refresh();

  final result = await showModalBottomSheet<int>(
    context: context,
    builder: (c) => _AddToPlaylistSheet(songs: songs),
  );
  if (result != null && context.mounted) {
    AppToast.show('已加入歌单「${_nameById(context, result)}」', isError: false);
  }
}

String _nameById(BuildContext context, int id) {
  final list = context.read<PlaylistsProvider>().playlists;
  for (final p in list) {
    if (p.id == id) return p.name;
  }
  return '';
}

class _AddToPlaylistSheet extends StatelessWidget {
  final List<Song> songs;
  final bool editMode;
  const _AddToPlaylistSheet({required this.songs, this.editMode = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaylistsProvider>();
    final titleFormat =
        context.watch<DirectSourceManager>().settings.songTitleFormat;
    final playlists = provider.playlists;
    // 编辑模式（单曲）显示已加入状态。
    final containing = editMode && songs.isNotEmpty
        ? provider.playlistsContaining(songs.first)
        : const <int>{};

    Future<void> pick(int id) async {
      if (editMode) {
        provider.toggleSong(id, songs.first);
        return;
      }
      for (final s in songs) {
        provider.addSong(id, s);
      }
      Navigator.of(context).pop(id);
    }

    Future<void> createAndAdd() async {
      final ctrl = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('新建歌单'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '名称'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
            TextButton(
                onPressed: () {
                  final t = ctrl.text.trim();
                  if (t.isEmpty) return;
                  Navigator.of(c).pop(t);
                },
                child: const Text('创建')),
          ],
        ),
      );
      if (name != null && name.isNotEmpty && context.mounted) {
        final id = provider.create(name);
        await pick(id);
      }
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              songs.isEmpty
                  ? '编辑歌单'
                  : editMode
                      ? '编辑歌单：${formatSongTitle(songs.first, titleFormat)}'
                      : songs.length == 1
                          ? '加入歌单：${formatSongTitle(songs.first, titleFormat)}'
                          : '加入歌单（${songs.length} 首）',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text('还没有歌单',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('新建歌单'),
                          onPressed: createAndAdd,
                        ),
                      ],
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in playlists)
                        ListTile(
                          leading: Icon(
                            editMode && containing.contains(p.id)
                                ? Icons.check_circle
                                : Icons.queue_music,
                            color: editMode && containing.contains(p.id)
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(p.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${provider.countOf(p.id)} 首'),
                          trailing: editMode
                              ? Checkbox(
                                  value: containing.contains(p.id),
                                  onChanged: (_) => pick(p.id),
                                )
                              : null,
                          onTap: () => pick(p.id),
                        ),
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('新建歌单'),
                        onTap: createAndAdd,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}