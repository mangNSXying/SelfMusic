import 'song.dart';

class Album {
  final int id;
  final String artist;
  final String album;
  final int? year;
  final String? genre;
  final int trackCount;
  final int totalDuration;

  /// 客户端聚合专辑时取首张有封面的歌（直连源封面缓存路径）。
  final String? coverPath;

  Album({
    required this.id,
    required this.artist,
    required this.album,
    this.year,
    this.genre,
    required this.trackCount,
    required this.totalDuration,
    this.coverPath,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: j['id'] as int,
        artist: j['artist'] as String? ?? 'Unknown',
        album: j['album'] as String? ?? 'Unknown',
        year: j['year'] as int?,
        genre: j['genre'] as String?,
        trackCount: j['trackCount'] as int? ?? 0,
        totalDuration: j['totalDuration'] as int? ?? 0,
      );

  /// 客户端从歌曲列表按 (专辑歌手?, 专辑名) 分组聚合（含直连源）。
  /// 专辑歌手优先（缺失回退到曲目歌手），同名合辑/多歌手专辑可正确归组。
  static List<Album> fromSongs(List<Song> songs) {
    final map = <String, List<Song>>{};
    for (final s in songs) {
      final artist = _albumArtistOf(s);
      final albumName = _blank(s.albumName, 'Unknown Album');
      map.putIfAbsent('$artist\x00$albumName', () => []).add(s);
    }
    final list = map.entries.map((e) {
      final group = e.value;
      final first = group.first;
      final coverSong = group.where((s) => s.coverPath != null).firstOrNull;
      return Album(
        id: e.key.hashCode & 0x7FFFFFFF,
        artist: _albumArtistOf(first),
        album: _blank(first.albumName, 'Unknown Album'),
        year: first.year,
        genre: first.genre,
        trackCount: group.length,
        totalDuration:
            group.fold(0, (sum, s) => sum + (s.duration ?? 0)),
        coverPath: coverSong?.coverPath,
      );
    }).toList();
    list.sort((a, b) => a.album.compareTo(b.album));
    return list;
  }

  /// 专辑歌手：优先 albumArtist，缺失回退曲目 artist。
  static String _albumArtistOf(Song s) =>
      _blank(s.albumArtist, _blank(s.artist, 'Unknown'));

  /// 该歌是否属于本专辑（按与 [fromSongs] 相同的分组键判断）。
  bool containsSong(Song s) =>
      _albumArtistOf(s) == artist &&
      _blank(s.albumName, 'Unknown Album') == album;

  static String _blank(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;
}