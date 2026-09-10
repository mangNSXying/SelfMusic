import 'song.dart';

/// 歌手（客户端从所有源歌曲分组聚合，非后端实体）。
class Artist {
  final String name;
  final int songCount;
  final int albumCount;
  final String? coverPath;

  Artist({
    required this.name,
    required this.songCount,
    required this.albumCount,
    this.coverPath,
  });

  /// 从歌曲列表按歌手名分组聚合。
  static List<Artist> fromSongs(List<Song> songs) {
    final map = <String, List<Song>>{};
    for (final s in songs) {
      final artist = (s.artist == null || s.artist!.isEmpty)
          ? 'Unknown'
          : s.artist!;
      map.putIfAbsent(artist, () => []).add(s);
    }
    final list = map.entries.map((e) {
      final songs = e.value;
      final albumNames = songs.map((s) => s.albumName ?? 'Unknown').toSet();
      final coverSong = songs.where((s) => s.coverPath != null).firstOrNull;
      return Artist(
        name: e.key,
        songCount: songs.length,
        albumCount: albumNames.length,
        coverPath: coverSong?.coverPath,
      );
    }).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }
}