import 'song.dart';

/// 歌手（客户端分组聚合，非后端实体）。
///
/// identity 模式（歌手处理.txt：歌曲身份聚合开关开启）：[identityKey] 为
/// artist_song_map 关联的艺术家身份键，歌曲列表走映射（含别名/角色合并）；
/// [status]/[mbid] 供「待确认/已解析」徽标与人工绑定决策。
class Artist {
  final String name;
  final int songCount;
  final int albumCount;
  final String? coverPath;

  /// identity 模式下的身份键（null=普通字符串分组）。
  final String? identityKey;

  /// 身份状态：resolved / local / pending / ambiguous（仅 identity 模式）。
  final String status;
  final String? mbid;

  const Artist({
    required this.name,
    required this.songCount,
    required this.albumCount,
    this.coverPath,
    this.identityKey,
    this.status = '',
    this.mbid,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'songCount': songCount,
        'albumCount': albumCount,
        'coverPath': coverPath,
        if (identityKey != null) 'identityKey': identityKey,
        if (status.isNotEmpty) 'status': status,
        if (mbid != null) 'mbid': mbid,
      };

  /// 序列化/反序列化保持身份字段（restoreCache 用）。
  factory Artist.fromJson(Map<String, dynamic> j) => Artist(
        name: j['name'] as String,
        songCount: j['songCount'] as int? ?? 0,
        albumCount: j['albumCount'] as int? ?? 0,
        coverPath: j['coverPath'] as String?,
        identityKey: j['identityKey'] as String?,
        status: j['status'] as String? ?? '',
        mbid: j['mbid'] as String?,
      );

  /// 从歌曲列表按歌手名分组聚合（非 identity 模式）。
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