import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../widgets/song_tile.dart';

/// 歌单栏：列表页（新建 / 重命名 / 删除）与详情原地子视图。
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({super.key});

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  @override
  void initState() {
    super.initState();
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaylistsProvider>();
    final playlists = provider.playlists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text('播放列表',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('新建'),
                onPressed: () => _createDialog(context, provider),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: playlists.isEmpty
              ? const Center(child: Text('暂无歌单，点右上角「新建」创建'))
              : ListView.separated(
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (c, i) {
                    final p = playlists[i];
                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${provider.countOf(p.id)} 首'),
                      trailing: PopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: (v) {
                          switch (v) {
                            case 'rename':
                              _renameDialog(context, provider, p);
                            case 'delete':
                              _confirmDelete(context, provider, p);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('重命名')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () =>
                          context.read<NavigationProvider>().enterPlaylist(p.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static Future<void> _createDialog(
      BuildContext context, PlaylistsProvider provider) async {
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      provider.create(name);
    }
  }

  static Future<void> _renameDialog(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名播放列表'),
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) provider.rename(p.id, name);
  }

  static Future<void> _confirmDelete(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除「${p.name}」？其中歌曲不会被删除，仅移除播放列表。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final nav = context.read<NavigationProvider>();
      if (nav.browsingPlaylistId == p.id) nav.exitPlaylist();
      provider.delete(p.id);
    }
  }
}

/// 歌单详情（原地子视图，仿源内浏览）：播放全部 / 移除 / 上移 / 下移。
class PlaylistDetailView extends StatefulWidget {
  final int playlistId;
  const PlaylistDetailView({super.key, required this.playlistId});

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  @override
  void initState() {
    super.initState();
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final provider = context.watch<PlaylistsProvider>();
    final player = context.read<PlayerProvider>();

    PlaylistRow? playlist;
    for (final p in provider.playlists) {
      if (p.id == widget.playlistId) playlist = p;
    }
    final songs = provider.songsOf(widget.playlistId);
    final items = provider.itemsOf(widget.playlistId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                onPressed: () => nav.exitPlaylist(),
              ),
              Expanded(
                child: Text(
                  playlist?.name ?? '播放列表',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (songs.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放全部'),
                  onPressed: () {
                    player.playQueue(songs);
                    context.read<NavigationProvider>().openPlayer();
                  },
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: songs.isEmpty
              ? const Center(child: Text('歌单为空'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 56),
                  itemBuilder: (c, i) {
                    final row = items[i];
                    final s = songs[i];
                    final isFirst = i == 0;
                    final isLast = i == items.length - 1;
                    return ListTile(
                      leading: CoverThumb(coverPath: s.coverPath),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${s.artist ?? "Unknown"} · ${s.albumName ?? ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: (v) {
                          switch (v) {
                            case 'up':
                              if (!isFirst) {
                                provider.moveItemRow(widget.playlistId, row, -1);
                              }
                            case 'down':
                              if (!isLast) {
                                provider.moveItemRow(widget.playlistId, row, 1);
                              }
                            case 'remove':
                              provider.removeItemRow(widget.playlistId, row);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'up',
                            enabled: !isFirst,
                            child: const Text('上移'),
                          ),
                          PopupMenuItem(
                            value: 'down',
                            enabled: !isLast,
                            child: const Text('下移'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('移除'),
                          ),
                        ],
                      ),
                      onTap: () {
                        player.playQueue(songs, index: i);
                        context.read<NavigationProvider>().openPlayer();
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}