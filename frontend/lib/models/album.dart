import '../data/local/artist_names.dart';
import 'song.dart';

class Album {
  final int id;

  /// 主歌手：组内出现歌曲数最多者（并列按首次出现），UI 上正常显示。
  final String artist;

  /// 组内去重后的歌手列表，主歌手在首位，其余 UI 上淡化显示。
  final List<String> artists;
  final String album;
  final int? year;
  final String? genre;
  final int trackCount;
  final int totalDuration;

  /// 分组键：有名专辑为 `album\x00<trim 后专辑名>`（忽略歌手）；
  /// 未知专辑为 `unknown\x00<trim 后专辑歌手>\x00Unknown Album`（保持按歌手分）。
  /// [containsSong] 按此键判断，与 [fromSongs] 同口径。
  final String groupKey;

  /// 客户端聚合专辑时取首张有封面的歌（直连源封面缓存路径）。
  final String? coverPath;

  Album({
    required this.id,
    required this.artist,
    List<String>? artists,
    required this.album,
    required this.groupKey,
    this.year,
    this.genre,
    required this.trackCount,
    required this.totalDuration,
    this.coverPath,
  }) : artists = artists == null || artists.isEmpty ? [artist] : artists;

  factory Album.fromJson(Map<String, dynamic> j) {
    final artist = j['artist'] as String? ?? 'Unknown';
    final artists = (j['artists'] as List?)
            ?.whereType<String>()
            .where((e) => e.isNotEmpty)
            .toList() ??
        [artist];
    final album = j['album'] as String? ?? 'Unknown';
    return Album(
      id: j['id'] as int,
      artist: artist,
      artists: artists,
      album: album,
      groupKey: j['groupKey'] as String? ?? _groupKeyOfName(artist, album),
      year: j['year'] as int?,
      genre: j['genre'] as String?,
      trackCount: j['trackCount'] as int? ?? 0,
      totalDuration: j['totalDuration'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'artist': artist,
        'artists': artists,
        'album': album,
        'groupKey': groupKey,
        'year': year,
        'genre': genre,
        'trackCount': trackCount,
        'totalDuration': totalDuration,
      };

  /// 客户端从歌曲列表按专辑名分组聚合（含直连源）。
  /// 有名专辑只看专辑名（trim 后）：同名即同一张，不同歌手也合并；
  /// 歌手拆分只用于展示（见 [_orderedArtists]），不参与分组。
  /// 无专辑标签（空/null/纯空白 → 'Unknown Album'）保持按专辑歌手原串分组，
  /// 避免杂烩文件被强行并成一张。
  static List<Album> fromSongs(List<Song> songs) {
    final map = <String, List<Song>>{};
    final displayOf = <String, String>{};
    for (final s in songs) {
      final key = _groupKeyOfSong(s);
      map.putIfAbsent(key, () => []).add(s);
      if (!_isUnknownSong(s)) displayOf.putIfAbsent(key, () => s.albumName!.trim());
    }
    final list = map.entries.map((e) {
      final group = e.value;
      final first = group.first;
      final coverSong = group.where((s) => s.coverPath != null).firstOrNull;
      final ordered = _orderedArtists(group);
      final unknown = _isUnknownSong(first);
      return Album(
        id: e.key.hashCode & 0x7FFFFFFF,
        artist: ordered.first,
        artists: ordered,
        album: unknown ? 'Unknown Album' : displayOf[e.key]!,
        groupKey: e.key,
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

  /// 组内歌手排序：每首歌取 [_albumArtistOf] 经歌手管线
  /// `stripParens` → `artistCollabParts` 拆分后去重计数（每首歌一票），
  /// 按票数降序、并列按首次出现排序，首位即主歌手。
  static List<String> _orderedArtists(List<Song> group) {
    final counts = <String, int>{};
    final firstSeen = <String, int>{};
    var order = 0;
    for (final s in group) {
      final contrib = _contribOf(s);
      final parts = <String>{};
      for (final p in artistCollabParts(stripParens(contrib))) {
        final t = p.trim();
        if (t.isNotEmpty) parts.add(t);
      }
      // 剥括号掏空（如纯注明串）时回退原串，避免主歌手为空。
      if (parts.isEmpty) parts.add(contrib);
      for (final p in parts) {
        counts[p] = (counts[p] ?? 0) + 1;
        firstSeen.putIfAbsent(p, () => order++);
      }
    }
    final list = counts.keys.toList()
      ..sort((a, b) {
        final c = counts[b]!.compareTo(counts[a]!);
        if (c != 0) return c;
        return firstSeen[a]!.compareTo(firstSeen[b]!);
      });
    return list;
  }

  /// 专辑歌手：优先 albumArtist，缺失回退曲目 artist。
  static String _albumArtistOf(Song s) =>
      _blank(s.albumArtist, _blank(s.artist, 'Unknown'));

  /// 该歌是否属于本专辑（按与 [fromSongs] 相同的分组键判断）。
  bool containsSong(Song s) => _groupKeyOfSong(s) == groupKey;

  /// 单曲的分组键（与 [fromSongs] 同口径）。
  static String _groupKeyOfSong(Song s) {
    final norm = s.albumName?.trim() ?? '';
    if (norm.isEmpty) return 'unknown\x00${_contribOf(s)}\x00Unknown Album';
    return 'album\x00$norm';
  }

  /// 单曲的歌手贡献串：专辑歌手优先（缺失回退曲目歌手），trim 后兜底 'Unknown'。
  static String _contribOf(Song s) {
    final v = _albumArtistOf(s).trim();
    return v.isEmpty ? 'Unknown' : v;
  }

  /// 兼容旧快照/服务端行的分组键推导（无歌曲明细时用）。
  static String _groupKeyOfName(String artist, String album) {
    final norm = album.trim();
    if (norm.isEmpty || norm == 'Unknown Album' || norm == 'Unknown') {
      final a = artist.trim();
      return 'unknown\x00${a.isEmpty ? 'Unknown' : a}\x00Unknown Album';
    }
    return 'album\x00$norm';
  }

  static bool _isUnknownSong(Song s) => (s.albumName?.trim() ?? '').isEmpty;

  static String _blank(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;
}