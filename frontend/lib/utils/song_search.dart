import '../models/song.dart';

/// 歌曲搜索匹配（标题/歌手/专辑/专辑歌手，忽略大小写、去首尾空白）。
bool songMatchesQuery(Song s, String q) {
  final qq = q.trim().toLowerCase();
  if (qq.isEmpty) return true;
  if (s.title.toLowerCase().contains(qq)) return true;
  if (s.albumName?.toLowerCase().contains(qq) ?? false) return true;
  if (s.albumArtist?.toLowerCase().contains(qq) ?? false) return true;
  return s.artist?.toLowerCase().contains(qq) ?? false;
}

/// 歌曲搜索过滤（空白词返回原列表）；歌曲页/喜欢页/歌单详情共用同一匹配语义。
List<Song> filterSongs(List<Song> songs, String q) {
  if (q.trim().isEmpty) return songs;
  return songs.where((s) => songMatchesQuery(s, q)).toList();
}
