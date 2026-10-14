/// 播放源内文件夹分组（纯函数，可单测）：
///
/// 各直连源的 `Song.sourceRef` 形态不一（本地/SFTP/SMB 已是源内相对路径，
/// WebDAV 是服务端全路径），调用方先经 [displayRelRef] 折成「源内相对路径」
/// （`/` 分隔、无前导斜杠，`''` 不会出现——歌曲必有文件名），再用
/// [groupSourceSongs] 按当前目录切出「直属子文件夹 + 本层歌曲」。
library;

/// 切分源内路径：`\` → `/`、去首尾空白，按 `/` 切分并丢弃空段与 `.`。
List<String> splitSourceRef(String ref) => ref
    .replaceAll('\\', '/')
    .trim()
    .split('/')
    .where((s) => s.isNotEmpty && s != '.')
    .toList();

/// 目录归一化（`''` = 源根）：统一分隔符、去前导/尾部斜杠。
String normalizeDir(String dir) => splitSourceRef(dir).join('/');

/// 取目录名（`''` 返回 `''`，调用方在根目录时展示源名）。
String baseNameOf(String dir) {
  final parts = splitSourceRef(dir);
  return parts.isEmpty ? '' : parts.last;
}

/// 取父目录（根的父仍是根 `''`）。
String parentDirOf(String dir) {
  final parts = splitSourceRef(dir);
  if (parts.isEmpty) return '';
  return parts.sublist(0, parts.length - 1).join('/');
}

/// 把存储态 `ref` 折成源内相对路径：归一化 + 可选剥离源根前缀
/// （WebDAV 传 base 路径如 `/dav/music`，SMB 传 `rootPath`，本地/SFTP 传空）。
///
/// 前缀按路径段比对（含 `root` 本身的 legacy 行一并兼容）；对不上则原样返回。
/// 结果为空（ref 恰等于前缀，歌曲不可能出现）时回落到原 basename，避免丢歌。
String displayRelRef(String ref, {String stripPrefix = ''}) {
  var parts = splitSourceRef(ref);
  final prefix = splitSourceRef(stripPrefix);
  if (prefix.isNotEmpty &&
      parts.length >= prefix.length &&
      _startsWith(parts, prefix)) {
    parts = parts.sublist(prefix.length);
  }
  if (parts.isEmpty) {
    final raw = splitSourceRef(ref);
    return raw.isEmpty ? '' : raw.last;
  }
  return parts.join('/');
}

bool _startsWith(List<String> parts, List<String> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (parts[i] != prefix[i]) return false;
  }
  return true;
}

/// 直属子文件夹：[name] 为单段名，[path] 为源内相对全路径，[total] 为其下
/// 递归歌曲总数（含深层，umpulled 空文件夹不出现——只从有歌的 ref 推导）。
class SourceFolder {
  final String name;
  final String path;
  final int total;
  const SourceFolder({
    required this.name,
    required this.path,
    required this.total,
  });
}

/// 按当前目录分组：[relRefs] 为已折叠的源内相对路径（与歌曲列表等长），
/// [dir] 为当前目录（`''` = 源根）。
///
/// 返回直属子文件夹（按名排序）与直属歌曲在原列表中的下标（保原顺序，
/// 即 `songsOf` 的歌手/专辑/曲目序）。
({List<SourceFolder> folders, List<int> songIndices}) groupSourceSongs(
  List<String> relRefs,
  String dir,
) {
  final current = normalizeDir(dir);
  final prefix = current.isEmpty ? '' : '$current/';
  final counts = <String, int>{};
  final indices = <int>[];
  for (var i = 0; i < relRefs.length; i++) {
    final rel = normalizeDir(relRefs[i]);
    if (rel.isEmpty || rel == current) continue;
    if (prefix.isNotEmpty && !rel.startsWith(prefix)) continue;
    final rest = prefix.isEmpty ? rel : rel.substring(prefix.length);
    if (rest.isEmpty) continue;
    final slash = rest.indexOf('/');
    if (slash < 0) {
      indices.add(i);
    } else {
      final child = prefix.isEmpty
          ? rest.substring(0, slash)
          : '$current/${rest.substring(0, slash)}';
      counts[child] = (counts[child] ?? 0) + 1;
    }
  }
  final folders = counts.entries
      .map((e) => SourceFolder(
            name: baseNameOf(e.key),
            path: e.key,
            total: e.value,
          ))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return (folders: folders, songIndices: indices);
}

/// 当前目录切片（含深层）的原下标：文件夹「播放该文件夹」用（递归范围）。
List<int> indicesUnder(List<String> relRefs, String dir) {
  final current = normalizeDir(dir);
  if (current.isEmpty) {
    return [for (var i = 0; i < relRefs.length; i++) i];
  }
  final prefix = '$current/';
  final out = <int>[];
  for (var i = 0; i < relRefs.length; i++) {
    if (normalizeDir(relRefs[i]).startsWith(prefix)) out.add(i);
  }
  return out;
}
