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

  int create(String name, {String? description}) {
    final id = index.createPlaylist(name, description: description);
    final uuid = index.ensurePlaylistUuid(id);
    index.enqueueOutbox(SyncEventTypes.playlistCreate, {
      'client_uuid': uuid,
      'name': name,
      if (description != null) 'description': description,
    });
    return id;
  }

  void rename(int id, String name) {
    final uuid = index.ensurePlaylistUuid(id);
    index.renamePlaylist(id, name);
    index.enqueueOutbox(SyncEventTypes.playlistUpdate, {
      'client_uuid': uuid,
      'name': name,
    });
  }

  void delete(int id) {
    // 先取 uuid：本地是硬删，墓碑只活在服务端。
    final uuid = index.ensurePlaylistUuid(id);
    index.enqueueOutbox(SyncEventTypes.playlistDelete, {
      'client_uuid': uuid,
    });
    index.deletePlaylist(id);
  }

  List<PlaylistRow> list() => index.listPlaylists();

  List<PlaylistItemRow> itemsOf(int playlistId) =>
      index.playlistItems(playlistId);

  /// 把歌曲快照加入歌单（供离线/源失效时展示）。
  void addSong(int playlistId, Song s) {
    index.addPlaylistItem(
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
    final uuid = index.ensurePlaylistUuid(playlistId);
    index.enqueueOutbox(SyncEventTypes.playlistItemAdd, {
      'playlist_uuid': uuid,
      'source': s.source,
      'source_ref': s.sourceRef,
      if (index.sourceUuidOf(s.sourceKey) != null)
        'source_id': index.sourceUuidOf(s.sourceKey),
      // 影子行展示字段（服务端无此歌时建行用；已有行忽略）。
      'title': s.title,
      if (s.artist != null) 'artist': s.artist,
      if (s.albumName != null) 'album': s.albumName,
      'sort_order': _sortOrderOf(playlistId, s),
    });
  }

  void removeSong(int playlistId, Song s) {
    index.removePlaylistItem(playlistId, s.sourceKey, s.sourceRef);
    if (!_syncable(s)) return;
    final uuid = index.ensurePlaylistUuid(playlistId);
    index.enqueueOutbox(SyncEventTypes.playlistItemRemove, {
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
  bool toggleSong(int playlistId, Song s) {
    if (contains(playlistId, s)) {
      removeSong(playlistId, s);
      return false;
    }
    addSong(playlistId, s);
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

  void move(int playlistId, int itemId, int delta) {
    PlaylistItemRow? before;
    for (final it in index.playlistItems(playlistId)) {
      if (it.id == itemId) {
        before = it;
        break;
      }
    }
    index.movePlaylistItem(playlistId, itemId, delta);
    final b = before;
    if (b == null || b.songRef.isEmpty) return;
    // 服务器模式行恒上报；直连行需连着服务器。
    if (b.sourceKey != 'server' && !(serverAvailable?.call() ?? false)) {
      return;
    }
    final uuid = index.ensurePlaylistUuid(playlistId);
    index.enqueueOutbox(SyncEventTypes.playlistItemMove, {
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