import '../../models/song.dart';
import 'local_index.dart';
import 'sync_event_types.dart';

/// 歌单本地仓储（stage2.md §1.2 / §5）。
///
/// 阶段5：create/rename/delete 恒进 outbox；条目增删改仅服务器模式歌曲进
/// outbox（直连歌曲服务端无法解析，见 DESIGN §7.2）。
class PlaylistStore {
  final LocalIndex index;
  PlaylistStore(this.index);

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
    if (b == null || b.sourceKey != 'server') return;
    final uuid = index.ensurePlaylistUuid(playlistId);
    index.enqueueOutbox(SyncEventTypes.playlistItemMove, {
      'playlist_uuid': uuid,
      // legacy 行 source 列为空时透传占位，服务端按 source_ref 兜底解析。
      'source': b.source ?? 'server',
      'source_ref': b.songRef,
      'sort_order': _sortOrderOfId(playlistId, itemId),
    });
  }

  /// 仅服务器模式且归属源可解析的歌曲参与条目同步。
  static bool _syncable(Song s) =>
      s.sourceKey == 'server' && s.source.isNotEmpty && s.source != 'server';

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