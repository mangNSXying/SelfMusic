import 'dart:async';

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

  /// 数据版本号：任何改动置数据（歌单列表/条目/计数）的写路径都会自增。
  /// 详情页用它按版本缓存 `songsOf/itemsOf`，避免每次 provider 通知都重查 SQLite。
  int _dataRevision = 0;
  int get dataRevision => _dataRevision;

  List<PlaylistRow> get playlists => List.unmodifiable(_playlists);

  int countOf(int playlistId) => _counts[playlistId] ?? _countsOf(playlistId);

  /// 刷新歌单列表。[changedUuids] 为本次真正变更的歌单（同步回调携带）：
  /// 只对这些歌单重查条目计数，其余沿用缓存——避免同步一次就 N+1 全量重查
  /// （同步后台化：落库回调不再在 UI 线程放大成整表查询）。
  void refresh({Set<String>? changedUuids}) {
    _playlists = store.list();
    final changedIds = changedUuids == null
        ? null
        : {
            for (final p in _playlists)
              if (p.clientUuid != null && changedUuids.contains(p.clientUuid))
                p.id
          };
    final next = <int, int>{};
    for (final p in _playlists) {
      final cached = _counts[p.id];
      if (changedIds == null || cached == null || changedIds.contains(p.id)) {
        next[p.id] = _countsOf(p.id);
      } else {
        next[p.id] = cached;
      }
    }
    _counts = next;
    loaded = true;
    _dataRevision++;
    notifyListeners();
  }

  int _countsOf(int playlistId) => store.countItemsOf(playlistId);

  Future<int> create(String name, {String? description}) async {
    final id = await store.create(name, description: description);
    // 增量更新：只拉一次列表 + 新歌单计数归零，避免全量 refresh
    //（逐歌单查条目数的 N+1 查询曾导致建单卡顿）。
    _playlists = store.list();
    _counts[id] = 0;
    loaded = true;
    _dataRevision++;
    notifyListeners();
    return id;
  }

  void rename(int id, String name) {
    unawaited(store.rename(id, name));
    // 仅原地改名，不碰计数与其它行。
    _playlists = [
      for (final p in _playlists)
        if (p.id == id)
          PlaylistRow(
              id: p.id,
              name: name,
              description: p.description,
              createdAt: p.createdAt,
              clientUuid: p.clientUuid)
        else
          p,
    ];
    _dataRevision++;
    notifyListeners();
  }

  void delete(int id) {
    unawaited(store.delete(id));
    _playlists = [for (final p in _playlists) if (p.id != id) p];
    _counts.remove(id);
    _dataRevision++;
    notifyListeners();
  }

  /// 加入歌单（无则新建）。写入后台隔离完成后再刷新计数。
  Future<void> addSong(int playlistId, Song s) async {
    await store.addSong(playlistId, s);
    _recount(playlistId);
  }

  /// 批量加入歌单：落库后只重查一次计数、只通知一次，返回实际新增条数。
  Future<int> addSongs(int playlistId, List<Song> songs) async {
    final added = await store.addSongs(playlistId, songs);
    if (added > 0) _recount(playlistId);
    return added;
  }

  Future<void> removeSong(int playlistId, Song s) =>
      removeSongs(playlistId, [s]);

  /// 批量移除并等待落库；返回移除后的条目数（播放器容量/续播收口用）。
  ///
  /// 不再“逐首 unawaited 写库再读计数”：写没落库时 count 是旧值，深历史
  /// 容量会偏大，批量移除当前曲时续播定位也会错位。
  Future<int> removeSongs(int playlistId, List<Song> songs) async {
    for (final s in songs) {
      await store.removeSong(playlistId, s);
    }
    final count = _countsOf(playlistId);
    _counts[playlistId] = count;
    _dataRevision++;
    notifyListeners();
    return count;
  }

  /// 该歌是否已在指定歌单。
  bool containsSong(int playlistId, Song s) => store.contains(playlistId, s);

  /// 该歌所在的全部歌单 id（编辑歌单弹层一次查全）。
  Set<int> playlistsContaining(Song s) => store.containingPlaylists(s);

  /// 切换「在歌单中」；返回切换后是否在歌单中。
  Future<bool> toggleSong(int playlistId, Song s) async {
    final inPlaylist = await store.toggleSong(playlistId, s);
    _recount(playlistId);
    return inPlaylist;
  }

  void move(int playlistId, int itemId, int delta) {
    unawaited(store.move(playlistId, itemId, delta).then((_) => refresh()));
  }

  /// 歌单内条目行（含 itemId，供上移/下移/移除）。
  List<PlaylistItemRow> itemsOf(int playlistId) => store.itemsOf(playlistId);

  /// 条目行 → 对应歌曲快照。
  ///
  /// 注意：快照的 `id` 恒为 0，仅供**不参与选择键**的场合用（源定位、移除
  /// 目标行）；歌单详情的选择键一律取索引实时行（`LocalIndex.songByRef`），
  /// 否则两套 key 不同源（已选计数恒 0 / 全选变整单）。
  Song songOf(PlaylistItemRow r) => store.songOf(r);

  void moveItemRow(int playlistId, PlaylistItemRow r, int delta) {
    store.move(playlistId, r.id, delta);
    // 仅顺序变化：计数不动，只通知重排。
    _dataRevision++;
    notifyListeners();
  }

  /// 单歌单计数刷新（1 次查询）：替代全量 refresh 的 N+1 查询。
  void _recount(int playlistId) {
    _counts[playlistId] = _countsOf(playlistId);
    _dataRevision++;
    notifyListeners();
  }
}