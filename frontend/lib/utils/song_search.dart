import '../models/song.dart';
import 'zh_variant.dart';

/// 歌曲搜索匹配（标题/歌手/专辑/专辑歌手，忽略大小写、去首尾空白）。
///
/// 显示为简体/繁体时，两侧都先做简繁折叠：输入简体也能搜到繁体存储的歌，
/// 反之亦然；设置「原文」时折叠为空操作，行为与旧版一致。
bool songMatchesQuery(Song s, String q) {
  final qq = zhSearchFold(q).trim().toLowerCase();
  if (qq.isEmpty) return true;
  if (zhSearchFold(s.title).toLowerCase().contains(qq)) return true;
  final album = s.albumName;
  if (album != null && zhSearchFold(album).toLowerCase().contains(qq)) {
    return true;
  }
  final albumArtist = s.albumArtist;
  if (albumArtist != null &&
      zhSearchFold(albumArtist).toLowerCase().contains(qq)) {
    return true;
  }
  final artist = s.artist;
  return artist != null && zhSearchFold(artist).toLowerCase().contains(qq);
}

/// 歌曲搜索过滤（空白词返回原列表）；歌曲页/喜欢页/歌单详情共用同一匹配语义。
List<Song> filterSongs(List<Song> songs, String q) {
  if (q.trim().isEmpty) return songs;
  return songs.where((s) => songMatchesQuery(s, q)).toList();
}
