import '../../models/song.dart';
import 'local_index.dart';

/// 歌单本地仓储（stage2.md §1.2 / §5）。
class PlaylistStore {
  final LocalIndex index;
  PlaylistStore(this.index);

  int create(String name, {String? description}) =>
      index.createPlaylist(name, description: description);

  void rename(int id, String name) => index.renamePlaylist(id, name);

  void delete(int id) => index.deletePlaylist(id);

  List<PlaylistRow> list() => index.listPlaylists();

  List<PlaylistItemRow> itemsOf(int playlistId) =>
      index.playlistItems(playlistId);

  /// 把歌曲快照加入歌单（供离线/源失效时展示）。
  void addSong(int playlistId, Song s) => index.addPlaylistItem(
        playlistId,
        sourceKey: s.sourceKey,
        songRef: s.sourceRef,
        title: s.title,
        artist: s.artist,
        album: s.albumName,
        coverPath: s.coverPath,
      );

  void removeSong(int playlistId, Song s) =>
      index.removePlaylistItem(playlistId, s.sourceKey, s.sourceRef);

  /// 歌单内条目托盘→转 Song（快照字段；sourceRef 即歌曲标识）。
  Song songOf(PlaylistItemRow item, {int id = 0}) => Song(
        id: id,
        sourceKey: item.sourceKey,
        title: item.title,
        artist: item.artist,
        albumName: item.album,
        sourceRef: item.songRef,
        source: item.sourceKey.contains(':')
            ? item.sourceKey.substring(0, item.sourceKey.indexOf(':'))
            : item.sourceKey,
        fileSize: 0,
        format: null,
        coverPath: item.coverPath,
      );

  void move(int playlistId, int itemId, int delta) =>
      index.movePlaylistItem(playlistId, itemId, delta);
}