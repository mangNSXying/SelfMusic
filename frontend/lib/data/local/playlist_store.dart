import '../../models/song.dart';
import 'local_index.dart';
import 'sync_event_types.dart';

/// 歌单本地仓储（stage2.md §1.2 / §5）。
///
/// 阶段5：create/rename/delete 恒进 outbox；条目增删改有歌曲身份即进 outbox，
/// 直连歌曲需连着服务器（[serverAvailable] 门控），服务端无行则建影子行
///（DESIGN §7.2）。
class PlaylistStore {
  final LocalIndex index;

  /// 服务器可达性门控（DirectSourceManager 注入 `isServerAvailable`），
  /// 语义同 SongWeightStore.serverAvailable。
  final bool Function()? serverAvailable;

  PlaylistStore(this.index, {this.serverAvailable});

  /// 建单 → 取跨设备 uuid → 入 outbox（写落库后再继续，uuid 必已存在）。
  Future<int> create(String name, {String? description}) async {
    final id = await index.createPlaylist(name, description: description);
    final uuid = await index.ensurePlaylistUuid(id);
    await index.enqueueOutbox(SyncEventTypes.playlistCreate, {
      'client_uuid': uuid,
      'name': name,
      if (description != null) 'description': description,
    });
    return id;
  }

  Future<void> rename(int id, String name) async {
    final uuid = await index.ensurePlaylistUuid(id);
    await index.renamePlaylist(id, name);
    await index.enqueueOutbox(SyncEventTypes.playlistUpdate, {
      'client_uuid': uuid,
      'name': name,
    });
  }

  Future<void> delete(int id) async {
    // 先取 uuid：本地是硬删，墓碑只活在服务端。
    final uuid = await index.ensurePlaylistUuid(id);
    await index.enqueueOutbox(SyncEventTypes.playlistDelete, {
      'client_uuid': uuid,
    });
    await index.deletePlaylist(id);
  }

  List<PlaylistRow> list() => index.listPlaylists();

  List<PlaylistItemRow> itemsOf(int playlistId) =>
      index.playlistItems(playlistId);

  /// 条目计数（E）：只计数不取行，供列表计数刷新。
  int countItemsOf(int playlistId) => index.playlistItemCount(playlistId);

  /// 把歌曲快照加入歌单（供离线/源失效时展示）。
  Future<void> addSong(int playlistId, Song s) async {
    await index.addPlaylistItem(
      playlistId,
      sourceKey: s.sourceKey,
      songRef: s.sourceRef,
      title: s.title,
      artist: s.artist,
      album: s.albumName,
      coverPath: s.coverPath,
      source: s.source,
    );
    if (!_syncable(s)) return;
    final uuid = await index.ensurePlaylistUuid(playlistId);
    await _enqueueItemAdd(
        uuid, s, _sortOrderOf(playlistId, s), index.sourceUuidOf(s.sourceKey));
  }

  Future<void> _enqueueItemAdd(
      String playlistUuid, Song s, int sortOrder, String? sourceId) async {
    await index.enqueueOutbox(SyncEventTypes.playlistItemAdd, {
      'playlist_uuid': playlistUuid,
      'source': s.source,
      'source_ref': s.sourceRef,
      if (sourceId != null) 'source_id': sourceId,
      // 影子行展示字段（服务端无此歌时建行用；已有行忽略）。
      'title': s.title,
      if (s.artist != null) 'artist': s.artist,
      if (s.albumName != null) 'album': s.albumName,
      'sort_order': sortOrder,
    });
  }

  /// 补推存量歌单（配对前建单无事件用）：为本地已有歌单补 playlist.create，
  /// 为其中非 'server' 条目（直连歌，配对前门控跳过未进事件）补 item_add。
  /// 'server' 行走常规 outbox（恒进事件），跳过。语义以本机为准
  ///（occurred_at=now，服务端 LWW 胜出）。返回 {playlists, items}。
  Future<Map<String, int>> backfill() async {
    var playlists = 0;
    var items = 0;
    for (final p in index.listPlaylists()) {
      final uuid = await index.ensurePlaylistUuid(p.id);
      await index.enqueueOutbox(SyncEventTypes.playlistCreate, {
        'client_uuid': uuid,
        'name': p.name,
        if (p.description != null) 'description': p.description,
      });
      playlists++;
      for (final it in index.playlistItems(p.id)) {
        if (it.sourceKey == 'server') continue;
        final s = songOf(it);
        if (!_syncable(s)) continue;
        await _enqueueItemAdd(
            uuid, s, it.sortOrder, index.sourceUuidOf(s.sourceKey));
        items++;
      }
    }
    return {'playlists': playlists, 'items': items};
  }

  Future<void> removeSong(int playlistId, Song s) async {
    await index.removePlaylistItem(playlistId, s.sourceKey, s.sourceRef);
    if (!_syncable(s)) return;
    final uuid = await index.ensurePlaylistUuid(playlistId);
    await index.enqueueOutbox(SyncEventTypes.playlistItemRemove, {
      'playlist_uuid': uuid,
      'source': s.source,
      'source_ref': s.sourceRef,
      if (index.sourceUuidOf(s.sourceKey) != null)
        'source_id': index.sourceUuidOf(s.sourceKey),
    });
  }

  /// 该歌是否已在指定歌单（兼容历史 ref 形态）。
  bool contains(int playlistId, Song s) =>
      index
          .playlistIdsContaining(s.sourceKey, s.sourceRef)
          .contains(playlistId);

  /// 该歌所在的全部歌单 id（弹层一次查全）。
  Set<int> containingPlaylists(Song s) =>
      index.playlistIdsContaining(s.sourceKey, s.sourceRef);

  /// 切换「在歌单中」状态；返回切换后是否在歌单中。
  Future<bool> toggleSong(int playlistId, Song s) async {
    if (contains(playlistId, s)) {
      await removeSong(playlistId, s);
      return false;
    }
    await addSong(playlistId, s);
    return true;
  }

  /// 歌单内条目托盘→转 Song（快照字段；sourceRef 即歌曲标识）。
  Song songOf(PlaylistItemRow item, {int id = 0}) => Song(
        id: id,
        sourceKey: item.sourceKey,
        title: item.title,
        artist: item.artist,
        albumName: item.album,
        sourceRef: item.songRef,
        source: item.source ??
            (item.sourceKey.contains(':')
                ? item.sourceKey.substring(0, item.sourceKey.indexOf(':'))
                : item.sourceKey),
        fileSize: 0,
        format: null,
        coverPath: item.coverPath,
      );

  Future<void> move(int playlistId, int itemId, int delta) async {
    PlaylistItemRow? before;
    for (final it in index.playlistItems(playlistId)) {
      if (it.id == itemId) {
        before = it;
        break;
      }
    }
    await index.movePlaylistItem(playlistId, itemId, delta);
    final b = before;
    if (b == null || b.songRef.isEmpty) return;
    // 服务器模式行恒上报；直连行需连着服务器。
    if (b.sourceKey != 'server' && !(serverAvailable?.call() ?? false)) {
      return;
    }
    final uuid = await index.ensurePlaylistUuid(playlistId);
    await index.enqueueOutbox(SyncEventTypes.playlistItemMove, {
      'playlist_uuid': uuid,
      // legacy 行 source 列为空时透传占位，服务端按 source_ref 兜底解析。
      'source': b.source ?? 'server',
      'source_ref': b.songRef,
      if (index.sourceUuidOf(b.sourceKey) != null)
        'source_id': index.sourceUuidOf(b.sourceKey),
      'sort_order': _sortOrderOfId(playlistId, itemId),
    });
  }

  /// 有歌曲身份即参与条目同步（直连歌曲需连着服务器，见 [serverAvailable]）。
  /// source=='server' 占位（归属源未知）仍跳过，避免跨源误归属。
  bool _syncable(Song s) =>
      s.source.isNotEmpty &&
      s.source != 'server' &&
      s.sourceRef.isNotEmpty &&
      (s.sourceKey == 'server' || (serverAvailable?.call() ?? false));

  int _sortOrderOf(int playlistId, Song s) {
    for (final it in index.playlistItems(playlistId)) {
      if (it.sourceKey == s.sourceKey && it.songRef == s.sourceRef) {
        return it.sortOrder;
      }
    }
    return 0;
  }

  int _sortOrderOfId(int playlistId, int itemId) {
    for (final it in index.playlistItems(playlistId)) {
      if (it.id == itemId) return it.sortOrder;
    }
    return 0;
  }
}