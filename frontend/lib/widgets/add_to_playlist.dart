import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/playlists_provider.dart';

/// 弹出「加入歌单」选择器（stage2.md §5）：底部弹层列出歌单，无歌单可现场新建。
Future<void> showAddToPlaylistSheet(BuildContext context, Song song) async {
  final provider = context.read<PlaylistsProvider>();
  if (!provider.loaded) provider.refresh();

  final result = await showModalBottomSheet<int>(
    context: context,
    builder: (c) => _AddToPlaylistSheet(song: song),
  );
  if (result != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入歌单「${_nameById(context, result)}」')));
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
  final Song song;
  const _AddToPlaylistSheet({required this.song});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaylistsProvider>();
    final playlists = provider.playlists;

    Future<void> pick(int id) async {
      provider.addSong(id, song);
      Navigator.of(context).pop(id);
    }

    Future<void> createAndAdd() async {
      final ctrl = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('新建播放列表'),
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
            child: Text('加入歌单：${song.title}',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
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
                          label: const Text('新建播放列表'),
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
                          leading: const Icon(Icons.queue_music),
                          title: Text(p.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${provider.countOf(p.id)} 首'),
                          onTap: () => pick(p.id),
                        ),
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('新建播放列表'),
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