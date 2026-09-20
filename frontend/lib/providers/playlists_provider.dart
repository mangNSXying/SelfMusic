import 'package:flutter/foundation.dart';

import '../data/local/local_index.dart';
import '../data/local/playlist_store.dart';
import '../models/song.dart';

/// 歌单视图状态（stage2.md §5）：持有歌单列表，包装增删改并驱动 UI 刷新。
class PlaylistsProvider extends ChangeNotifier {
  final PlaylistStore store;
  PlaylistsProvider(this.store);

  List<PlaylistRow> _playlists = [];
  Map<int, int> _counts = {};
  bool loaded = false;

  List<PlaylistRow> get playlists => List.unmodifiable(_playlists);

  int countOf(int playlistId) => _counts[playlistId] ?? _countsOf(playlistId);

  void refresh() {
    _playlists = store.list();
    _counts = {
      for (final p in _playlists) p.id: _countsOf(p.id),
    };
    loaded = true;
    notifyListeners();
  }

  int _countsOf(int playlistId) => store.itemsOf(playlistId).length;

  int create(String name, {String? description}) {
    final id = store.create(name, description: description);
    refresh();
    return id;
  }

  void rename(int id, String name) {
    store.rename(id, name);
    refresh();
  }

  void delete(int id) {
    store.delete(id);
    refresh();
  }

  /// 加入歌单（无则新建）。
  void addSong(int playlistId, Song s) {
    store.addSong(playlistId, s);
    refresh();
  }

  void removeSong(int playlistId, Song s) {
    store.removeSong(playlistId, s);
    refresh();
  }

  /// 该歌是否已在指定歌单。
  bool containsSong(int playlistId, Song s) => store.contains(playlistId, s);

  /// 该歌所在的全部歌单 id（编辑歌单弹层一次查全）。
  Set<int> playlistsContaining(Song s) => store.containingPlaylists(s);

  /// 切换「在歌单中」；返回切换后是否在歌单中。
  bool toggleSong(int playlistId, Song s) {
    final inPlaylist = store.toggleSong(playlistId, s);
    refresh();
    return inPlaylist;
  }

  void move(int playlistId, int itemId, int delta) {
    store.move(playlistId, itemId, delta);
    refresh();
  }

  /// 歌单内条目快照 → Song。
  List<Song> songsOf(int playlistId) =>
      store.itemsOf(playlistId).map((r) => store.songOf(r)).toList();

  /// 歌单内条目行（含 itemId，供上移/下移/移除）。
  List<PlaylistItemRow> itemsOf(int playlistId) => store.itemsOf(playlistId);

  /// 条目行 → 对应歌曲（多选去重键用）。
  Song songOf(PlaylistItemRow r) => store.songOf(r);

  void removeItemRow(int playlistId, PlaylistItemRow r) {
    store.removeSong(playlistId, store.songOf(r));
    refresh();
  }

  void moveItemRow(int playlistId, PlaylistItemRow r, int delta) {
    store.move(playlistId, r.id, delta);
    refresh();
  }
}