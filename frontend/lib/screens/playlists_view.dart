import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/list_selection.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_tile.dart';

/// 歌单栏：列表页（新建 / 重命名 / 删除 / 长按多选删除）与详情原地子视图。
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({super.key});

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  final Selection<int> _sel = Selection<int>();

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

  void _toggleSelect(int id) => setState(() {
        _sel.active = true;
        _sel.toggle(id);
      });

  Future<void> _deleteSelected(PlaylistsProvider provider) async {
    final playlists = provider.playlists;
    final names = _sel
        .of(playlists.map((p) => p.id))
        .map((id) => playlists.firstWhere((p) => p.id == id).name)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除选中的 ${names.length} 个播放列表？'
            '（仅移除播放列表，其中歌曲不会被删除。）'),
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
    if (ok != true || !mounted) return;
    final nav = context.read<NavigationProvider>();
    for (final id in _sel.selected.toList()) {
      if (nav.browsingPlaylistId == id) nav.exitPlaylist();
      provider.delete(id);
    }
    setState(_sel.cancel);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaylistsProvider>();
    final playlists = provider.playlists;

    return SectionSwipe(
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_sel.active)
                SelectionBar(
                  total: playlists.length,
                  selectedCount: _sel.count,
                  onToggleAll: () =>
                      setState(() => _sel.setAll(playlists.map((p) => p.id))),
                  onCancel: () => setState(_sel.cancel),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.delete),
                      tooltip: '删除选中',
                      onPressed: _sel.isEmpty
                          ? null
                          : () => _deleteSelected(provider),
                    ),
                  ],
                ),
              if (_sel.active) const Divider(height: 1),
              Expanded(
                child: playlists.isEmpty
                    ? const Center(child: Text('暂无歌单，点右下角「+」创建'))
                    : ListView.separated(
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (c, i) {
                    final p = playlists[i];
                    return ListTile(
                      selected: _sel.active && _sel.contains(p.id),
                      leading: _sel.active
                          ? Checkbox(
                              value: _sel.contains(p.id),
                              onChanged: (_) => _toggleSelect(p.id),
                            )
                          : const Icon(Icons.queue_music),
                      title: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${provider.countOf(p.id)} 首'),
                      trailing: _sel.active
                          ? null
                          : PopupMenuButton<String>(
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
                                PopupMenuItem(
                                    value: 'rename', child: Text('重命名')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('删除')),
                              ],
                            ),
                      onTap: _sel.active
                          ? () => _toggleSelect(p.id)
                          : () => context
                              .read<NavigationProvider>()
                              .enterPlaylist(p.id),
                      onLongPress: _sel.active
                          ? () => _toggleSelect(p.id)
                          : () => setState(() => _sel.startWith(p.id)),
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: CornerAddButton(
              tooltip: '新建播放列表',
              onPressed: () => _createDialog(context, provider),
            ),
          ),
        ],
      ),
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
  final Selection<String> _sel = Selection<String>();

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

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  Future<void> _removeSelected(PlaylistsProvider provider) async {
    final songsNow = provider.songsOf(widget.playlistId);
    final itemsNow = provider.itemsOf(widget.playlistId);
    final count = _sel.of(songsNow.map((s) => songKey(s))).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('从歌单移除'),
        content: Text('确定从歌单中移除选中的 $count 首歌曲？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 从后往前移除，避免 store 序号移位问题。
    for (var i = itemsNow.length - 1; i >= 0; i--) {
      if (_sel.contains(songKey(songsNow[i]))) {
        provider.removeItemRow(widget.playlistId, itemsNow[i]);
      }
    }
    setState(_sel.cancel);
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
        if (_sel.active)
          SelectionBar(
            total: items.length,
            selectedCount: _sel.of(items.map((r) => songKey(provider.songOf(r))))
                .length,
            onToggleAll: () => setState(() {
              _sel.active = true;
              _sel.setAll(items.map((r) => songKey(provider.songOf(r))));
            }),
            onCancel: () => setState(_sel.cancel),
            actions: [
              IconButton(
                icon: const Icon(Icons.playlist_remove),
                tooltip: '从歌单移除',
                onPressed:
                    _sel.selected.isEmpty ? null : () => _removeSelected(provider),
              ),
            ],
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
                    final key = songKey(s);
                    return ListTile(
                      selected: _sel.active && _sel.contains(key),
                      leading: _sel.active
                          ? Checkbox(
                              value: _sel.contains(key),
                              onChanged: (_) => _toggle(key),
                            )
                          : CoverThumb(coverPath: s.coverPath),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${s.artist ?? "Unknown"} · ${s.albumName ?? ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _sel.active
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (v) {
                                switch (v) {
                                  case 'up':
                                    if (!isFirst) {
                                      provider.moveItemRow(
                                          widget.playlistId, row, -1);
                                    }
                                  case 'down':
                                    if (!isLast) {
                                      provider.moveItemRow(
                                          widget.playlistId, row, 1);
                                    }
                                  case 'remove':
                                    provider.removeItemRow(
                                        widget.playlistId, row);
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
                      onTap: _sel.active
                          ? () => _toggle(key)
                          : () {
                              player.playQueue(songs, index: i);
                              context.read<NavigationProvider>().openPlayer();
                            },
                      onLongPress: _sel.active
                          ? () => _toggle(key)
                          : () => setState(() => _sel.startWith(key)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}