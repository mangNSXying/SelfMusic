/// 歌单详情「分类方式」（纯函数，可单测）：
///
/// - [PlaylistGroup.none]：不分组，保持现有平铺逻辑；
/// - [PlaylistGroup.folder]：按歌曲所在**直接父级文件夹**分组（多层路径只取
///   父级一段；源根歌曲归入「根目录」）；
/// - [PlaylistGroup.album]：按 `Song.albumName` 分组，空专辑归入「未知专辑」。
///
/// 文件夹 key 的推导复用 `source_folders`：调用方按每首歌的源取
/// [stripPrefixForSource] 前缀（歌单内歌曲可来自多个源），经
/// [displayRelRef] 折成源内相对路径后再取父级。
library;

import '../models/song.dart';
import 'source_folders.dart';

/// 歌单详情分类方式（全局设置持久化，默认 [none]）。
enum PlaylistGroup {
  none,
  folder,
  album,
}

extension PlaylistGroupX on PlaylistGroup {
  String get label => switch (this) {
        PlaylistGroup.none => '无',
        PlaylistGroup.folder => '文件夹',
        PlaylistGroup.album => '专辑',
      };

  static PlaylistGroup parse(String? v) => v == null
      ? PlaylistGroup.none
      : PlaylistGroup.values.firstWhere((e) => e.name == v,
          orElse: () => PlaylistGroup.none);
}

/// 源根歌曲的分组名（`sourceRef` 无 `/`，即直接位于源根）。
const String kPlaylistRootFolderName = '根目录';

/// 空专辑的分组名。
const String kPlaylistUnknownAlbumName = '未知专辑';

/// 单首歌的分组 key（[stripPrefix] 为该歌所属源的剥离前缀）。
String playlistGroupKeyOf(Song song, PlaylistGroup mode,
    {String stripPrefix = ''}) {
  switch (mode) {
    case PlaylistGroup.none:
      return '';
    case PlaylistGroup.album:
      final album = song.albumName?.trim() ?? '';
      return album.isEmpty ? kPlaylistUnknownAlbumName : album;
    case PlaylistGroup.folder:
      final rel =
          displayRelRef(song.sourceRef, stripPrefix: stripPrefix);
      final parts = splitSourceRef(rel);
      if (parts.length < 2) return kPlaylistRootFolderName;
      return parts[parts.length - 2];
  }
}

/// 一个分组：组名 + 组内歌曲在输入列表中的下标（保输入顺序，
/// 即调用方已排好的「排列方式」顺序；默认排序时即歌单原序）。
class PlaylistSongGroup {
  final String name;
  final List<int> songIndices;
  const PlaylistSongGroup({required this.name, required this.songIndices});

  int get count => songIndices.length;
}

/// 分组入口：[songs] 为已按排列方式排好的歌单歌曲，[stripPrefixOf] 按歌取源前缀。
/// 组按名称排序（大小写不敏感），组内保原序；[mode] 为 none 或空单时返回空。
List<PlaylistSongGroup> groupPlaylistSongs(
  List<Song> songs,
  PlaylistGroup mode,
  String Function(Song) stripPrefixOf,
) {
  if (mode == PlaylistGroup.none || songs.isEmpty) return const [];
  final buckets = <String, List<int>>{};
  final order = <String>[];
  for (var i = 0; i < songs.length; i++) {
    final key =
        playlistGroupKeyOf(songs[i], mode, stripPrefix: stripPrefixOf(songs[i]));
    if (!buckets.containsKey(key)) {
      buckets[key] = [];
      order.add(key);
    }
    buckets[key]!.add(i);
  }
  order.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final name in order)
      PlaylistSongGroup(name: name, songIndices: buckets[name]!),
  ];
}
