import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/sources/webdav_url.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/song_search.dart';
import '../utils/song_title_format.dart';
import 'app_toast.dart';
import 'corner_add_button.dart';
import 'draggable_sheet.dart';
import 'list_selection.dart';
import 'row_list.dart';
import 'song_row_view.dart';
import 'song_tile.dart';

/// 从曲库挑歌加进指定歌单。返回选中的歌曲（按曲库顺序），取消返回 null。
///
/// 候选池为 [LibraryProvider.songs]（全部直连源）；已在歌单的歌曲展示但禁用。
Future<List<Song>?> showPlaylistSongPicker(
  BuildContext context, {
  required int playlistId,
  required String playlistName,
}) {
  return showAppDraggableSheet<List<Song>>(
    context,
    config: const AppSheetConfig(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 1.0,
    ),
    builder: (c, scrollCtrl) => _PlaylistSongPicker(
      playlistId: playlistId,
      playlistName: playlistName,
      scrollCtrl: scrollCtrl,
    ),
  );
}

/// 歌单页右下角「添加歌曲」悬浮入口。
class PlaylistAddSongsButton extends StatelessWidget {
  final int playlistId;
  const PlaylistAddSongsButton({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return CornerAddButton(
      icon: Icons.playlist_add,
      label: '添加歌曲',
      tooltip: '添加歌曲',
      onPressed: () => addSongsToPlaylist(context, playlistId),
    );
  }
}

/// 打开选歌弹层并把选中的歌曲批量加入歌单；弹层关闭后再落库。
Future<void> addSongsToPlaylist(BuildContext context, int playlistId) async {
  final provider = context.read<PlaylistsProvider>();
  final name = _playlistNameOf(provider, playlistId);
  final picked = await showPlaylistSongPicker(
    context,
    playlistId: playlistId,
    playlistName: name,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;
  try {
    final added = await provider.addSongs(playlistId, picked);
    if (!context.mounted) return;
    AppToast.show(
      added > 0 ? '已添加 $added 首到「$name」' : '所选歌曲已在该歌单中',
      isError: false,
    );
  } catch (e) {
    if (context.mounted) AppToast.error(e, '添加失败');
  }
}

String _playlistNameOf(PlaylistsProvider provider, int playlistId) {
  for (final p in provider.playlists) {
    if (p.id == playlistId) return p.name;
  }
  return '歌单';
}

class _PlaylistSongPicker extends StatefulWidget {
  final int playlistId;
  final String playlistName;

  /// 统一拖拽窗口下发的共享滚动轴。
  final ScrollController scrollCtrl;

  const _PlaylistSongPicker({
    required this.playlistId,
    required this.playlistName,
    required this.scrollCtrl,
  });

  @override
  State<_PlaylistSongPicker> createState() => _PlaylistSongPickerState();
}

class _PlaylistSongPickerState extends State<_PlaylistSongPicker> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Selection<String> _sel = Selection<String>();

  /// 歌单现有条目的 `sourceKey\0ref` 集合（含 WebDAV 历史 ref 变体）。
  Set<String>? _existingRefs;

  List<Song> _base = const [];
  String _query = '';
  String? _cachedQuery;
  List<Song> _display = const [];

  /// 当前展示列表里已在歌单的歌曲 key。
  Set<String> _added = const {};

  @override
  void initState() {
    super.initState();
    // 歌单页可能比歌曲页先打开：曲库尚未加载时补一次启动加载。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.songs.isEmpty && !lib.loading) lib.startup();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _existingRefs ??= _loadExisting(context.read<PlaylistsProvider>());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Set<String> _loadExisting(PlaylistsProvider provider) {
    final out = <String>{};
    for (final item in provider.itemsOf(widget.playlistId)) {
      for (final ref in webdavRefVariants(item.songRef)) {
        out.add('${item.sourceKey}\u0000$ref');
      }
    }
    return out;
  }

  bool _isAdded(Song s) {
    final refs = _existingRefs;
    if (refs == null || refs.isEmpty) return false;
    for (final ref in webdavRefVariants(s.sourceRef)) {
      if (refs.contains('${s.sourceKey}\u0000$ref')) return true;
    }
    return false;
  }

  /// 按曲库身份/搜索词缓存展示列表与「已在歌单」标记。
  void _syncDisplay(LibraryProvider lib) {
    if (identical(_base, lib.songs) && _cachedQuery == _query) return;
    _base = lib.songs;
    _cachedQuery = _query;
    _display = filterSongs(lib.songs, _query);
    _added = {
      for (final s in _display)
        if (_isAdded(s)) songKey(s),
    };
  }

  List<Song> get _selectable => [
        for (final s in _display)
          if (!_added.contains(songKey(s))) s,
      ];

  bool get _allSelected {
    final list = _selectable;
    return list.isNotEmpty && list.every((s) => _sel.contains(songKey(s)));
  }

  void _toggle(Song s) {
    final key = songKey(s);
    if (_added.contains(key)) return;
    setState(() => _sel.toggle(key));
  }

  void _toggleSelectAll() {
    final list = _selectable;
    if (list.isEmpty) return;
    setState(() {
      if (_allSelected) {
        _sel.clearAll();
      } else {
        _sel.addAll([for (final s in list) songKey(s)]);
      }
    });
  }

  void _submit() {
    final picked = selectedSongs(_sel, context.read<LibraryProvider>().songs);
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    // 订阅收窄：弹层只依赖标题显示格式，扫描/权重等通知不牵连重建。
    final format = context.select<DirectSourceManager, SongTitleFormat>(
        (d) => d.settings.songTitleFormat);
    _syncDisplay(lib);
    final display = _display;

    return Padding(
      // 搜索时键盘抬起：把内容整体抬到键盘上方（弹层高度不变）。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          AppSheetTitleBar(
            title: '添加歌曲到「${widget.playlistName}」',
            count: display.length,
          ),
          if (lib.loading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索曲库添加歌曲',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Expanded(child: _body(lib, display, format)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _selectable.isEmpty ? null : _toggleSelectAll,
                    icon:
                        Icon(_allSelected ? Icons.deselect : Icons.select_all),
                    label: Text(_allSelected ? '全不选' : '全选'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _sel.count == 0 ? null : _submit,
                    child: Text(_sel.count == 0 ? '添加' : '添加 ${_sel.count} 首'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
      LibraryProvider lib, List<Song> display, SongTitleFormat format) {
    if (lib.songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: lib.loading
              ? const CircularProgressIndicator()
              : Text(
                  '曲库暂无歌曲\n请先在「歌曲」页扫描/刷新',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
        ),
      );
    }
    if (display.isEmpty) {
      return const Center(child: Text('无匹配歌曲'));
    }
    return RowList(
      controller: widget.scrollCtrl,
      count: display.length,
      itemBuilder: (c, i) => _row(c, display[i], format),
    );
  }

  Widget _row(BuildContext c, Song s, SongTitleFormat format) {
    final key = songKey(s);
    final added = _added.contains(key);
    final selected = _sel.contains(key);
    final cs = Theme.of(c).colorScheme;
    return ListTile(
      enabled: !added,
      leading: CoverThumb(coverPath: s.coverPath),
      title: Text(
        formatSongTitle(s, format),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        SongRowView.subtitleOf(s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: added
          ? Text('已在歌单', style: TextStyle(color: cs.onSurfaceVariant))
          : Checkbox(
              value: selected,
              onChanged: (_) => _toggle(s),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
      onTap: added ? null : () => _toggle(s),
    );
  }
}
