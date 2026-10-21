/// 歌曲列表「分类方式」与分组缓存（纯函数 + 轻量缓存，可单测）：
///
/// - [SongGroupMode.none]：不分组，保持平铺；
/// - [SongGroupMode.folder]：按歌曲所在**直接父级文件夹**分组（多层路径只取
///   父级一段；源根歌曲归入「根目录」）；
/// - [SongGroupMode.album]：按 `Song.albumName` 分组，空专辑归入「未知专辑」。
///
/// 文件夹 key 的推导复用 `source_folders`：调用方按每首歌的源取
/// [stripPrefixForSource] 前缀（跨源列表可来自多个源），经 [displayRelRef]
/// 折成源内相对路径后再取父级。
///
/// 本文件只做「平铺分组」（组头 + 组内歌曲）；播放源页的逐级文件夹导航
/// 走 `source_folders.groupSourceSongs`，两者共用同一套行模型 [SongListRow]。
library;

import '../models/song.dart';
import 'source_folders.dart';

/// 歌曲列表分类方式（按页持久化，默认 [none]）。
enum SongGroupMode {
  none,
  folder,
  album,
}

extension SongGroupModeX on SongGroupMode {
  String get label => switch (this) {
        SongGroupMode.none => '无',
        SongGroupMode.folder => '文件夹',
        SongGroupMode.album => '专辑',
      };

  /// 显式标签（播放源页把「文件夹」写成「文件夹（逐级）」以区分钻取语义）。
  String labelFor({String? folderLabel}) =>
      this == SongGroupMode.folder && folderLabel != null ? folderLabel : label;

  static SongGroupMode parse(String? v) => v == null
      ? SongGroupMode.none
      : SongGroupMode.values
          .firstWhere((e) => e.name == v, orElse: () => SongGroupMode.none);
}

/// 源根歌曲的分组名（`sourceRef` 无 `/`，即直接位于源根）。
const String kRootFolderGroupName = '根目录';

/// 空专辑的分组名。
const String kUnknownAlbumGroupName = '未知专辑';

/// 单首歌的分组 key（[stripPrefix] 为该歌所属源的剥离前缀）。
String songGroupKeyOf(Song song, SongGroupMode mode,
    {String stripPrefix = ''}) {
  switch (mode) {
    case SongGroupMode.none:
      return '';
    case SongGroupMode.album:
      final album = song.albumName?.trim() ?? '';
      return album.isEmpty ? kUnknownAlbumGroupName : album;
    case SongGroupMode.folder:
      final rel = displayRelRef(song.sourceRef, stripPrefix: stripPrefix);
      final parts = splitSourceRef(rel);
      if (parts.length < 2) return kRootFolderGroupName;
      return parts[parts.length - 2];
  }
}

/// 一个平铺分组：组名 + 组内歌曲在输入列表中的下标（保输入顺序，
/// 即调用方已排好的「排列方式」顺序；默认排序时即原始顺序）。
class SongGroup {
  final String name;
  final List<int> songIndices;
  const SongGroup({required this.name, required this.songIndices});

  int get count => songIndices.length;
}

/// 分组入口：[songs] 为已按排列方式排好的列表，[stripPrefixOf] 按歌取源前缀。
/// 组按名称排序（大小写不敏感），组内保原序；[mode] 为 none 或空单时返回空。
List<SongGroup> buildSongGroups(
  List<Song> songs,
  SongGroupMode mode,
  String Function(Song) stripPrefixOf,
) {
  if (mode == SongGroupMode.none || songs.isEmpty) return const [];
  final buckets = <String, List<int>>{};
  final order = <String>[];
  for (var i = 0; i < songs.length; i++) {
    final key =
        songGroupKeyOf(songs[i], mode, stripPrefix: stripPrefixOf(songs[i]));
    if (!buckets.containsKey(key)) {
      buckets[key] = [];
      order.add(key);
    }
    buckets[key]!.add(i);
  }
  order.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final name in order)
      SongGroup(name: name, songIndices: buckets[name]!),
  ];
}

/// 平铺分组的缓存：仅当歌曲列表身份、分类方式或源配置版本变化时重算，
/// 避免每次 build 对整库做 O(n) 分组。
class SongGroupCache {
  Object? _songs;
  SongGroupMode _mode = SongGroupMode.none;
  int _sourcesRev = -1;
  List<SongGroup> _groups = const [];

  List<SongGroup> resolve({
    required List<Song> songs,
    required SongGroupMode mode,
    required int sourcesRev,
    required String Function(Song) stripPrefixOf,
  }) {
    if (identical(_songs, songs) &&
        _mode == mode &&
        _sourcesRev == sourcesRev) {
      return _groups;
    }
    _songs = songs;
    _mode = mode;
    _sourcesRev = sourcesRev;
    _groups = buildSongGroups(songs, mode, stripPrefixOf);
    return _groups;
  }
}

/// 列表展示行（平铺组头 / 逐级文件夹行 / 歌曲行三选一）。
///
/// - [group]：平铺分组头（折叠/组播）；
/// - [folder]：逐级文件夹行（进入/递归播）；
/// - [song]：歌曲在输入 `songs` 中的下标。
typedef SongListRow = ({String? group, SourceFolder? folder, int? song});

/// 平铺行：分组头 + 未折叠组的歌曲；分组为空时退化为纯歌曲行。
List<SongListRow> buildFlatRows(List<SongGroup> groups, Set<String> collapsed) {
  if (groups.isEmpty) return const [];
  final rows = <SongListRow>[];
  for (final g in groups) {
    rows.add((group: g.name, folder: null, song: null));
    if (collapsed.contains(g.name)) continue;
    for (final i in g.songIndices) {
      rows.add((group: null, folder: null, song: i));
    }
  }
  return rows;
}

/// 逐级行：当前目录的子文件夹行 + 本层歌曲行。
List<SongListRow> buildFolderRows({
  required List<SourceFolder> folders,
  required List<int> songIndices,
}) =>
    [
      for (final f in folders) (group: null, folder: f, song: null),
      for (final i in songIndices) (group: null, folder: null, song: i),
    ];
