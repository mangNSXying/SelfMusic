/// 播放源内目录树（纯函数，可单测）：
///
/// 各直连源的 `Song.sourceRef` 形态不一（本地/SFTP/SMB 已是源内相对路径，
/// WebDAV 是服务端全路径），调用方先经 [displayRelRef] 折成「源内相对路径」
/// （`/` 分隔、无前导斜杠，`''` 不会出现——歌曲必有文件名），再用
/// [SourceFolderTree] 建立目录树，供源页逐级/树形展开与递归选择使用。
library;

import '../data/sources/music_source.dart';
import '../data/sources/smb_direct_source.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/webdav_url.dart';

/// 该源的「源内相对路径」剥离前缀：WebDAV 以 base 路径为源根，
/// SMB 以 `rootPath` 为源根（兼容含 root 前缀的 legacy 行），
/// 本地/SFTP 本就是相对路径无需剥离。
///
/// 多源混排（如歌单）时按每首歌的源单独取前缀；源已删除时传 `''`。
String stripPrefixForSource(MusicSource source) {
  if (source is WebdavDirectSource) {
    return webdavPathOf(webdavNormalizeBase(source.baseUrl));
  }
  if (source is SmbDirectSource) return source.rootPath;
  return '';
}

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

/// 文件夹行数据：[name] 为单段名，[path] 为源内相对全路径，[total] 为其下
/// 递归歌曲总数（含深层，未拉取的空文件夹不出现——只从有歌的 ref 推导）。
class SourceFolder {
  final String name;
  final String path;
  final int total;

  /// 有可展开的子目录或直属歌曲；false 时源页不显示展开箭头。
  final bool hasChildren;
  const SourceFolder({
    required this.name,
    required this.path,
    required this.total,
    this.hasChildren = false,
  });
}

/// 源内目录树节点：children 为直属子目录（构建后按名排序），
/// directSongIndices 为直属歌曲下标，total 为子树歌曲总数（含直属）。
class SourceFolderNode {
  final String name;
  final String path;
  final Map<String, SourceFolderNode> children = {};
  final List<int> directSongIndices = [];
  int total = 0;

  SourceFolderNode({required this.name, required this.path});

  bool get hasChildren => children.isNotEmpty || directSongIndices.isNotEmpty;

  SourceFolder get folder => SourceFolder(
        name: name,
        path: path,
        total: total,
        hasChildren: hasChildren,
      );
}

/// 一次构建的源内目录树（根目录 path 为 `''`）：
/// 从 [relRefs] 插入每首歌的全部祖先目录，再补 [extraFolders] 的空文件夹。
class SourceFolderTree {
  final SourceFolderNode root;
  final Map<String, SourceFolderNode> _nodes;

  SourceFolderTree._(this.root, this._nodes);

  factory SourceFolderTree.build({
    required List<String> relRefs,
    Iterable<String> extraFolders = const [],
  }) {
    final root = SourceFolderNode(name: '', path: '');
    final nodes = <String, SourceFolderNode>{'': root};

    SourceFolderNode ensureDir(String path) {
      final existing = nodes[path];
      if (existing != null) return existing;
      final parent = ensureDir(parentDirOf(path));
      final node = SourceFolderNode(name: baseNameOf(path), path: path);
      parent.children[node.name] = node;
      nodes[path] = node;
      return node;
    }

    for (var i = 0; i < relRefs.length; i++) {
      final parts = splitSourceRef(relRefs[i]);
      if (parts.isEmpty) continue;
      var node = root;
      node.total++;
      var path = '';
      for (var p = 0; p < parts.length - 1; p++) {
        path = path.isEmpty ? parts[p] : '$path/${parts[p]}';
        node = ensureDir(path);
        node.total++;
      }
      node.directSongIndices.add(i);
    }
    for (final raw in extraFolders) {
      var path = '';
      for (final seg in splitSourceRef(raw)) {
        path = path.isEmpty ? seg : '$path/$seg';
        ensureDir(path);
      }
    }

    void sortChildren(SourceFolderNode node) {
      final sorted = node.children.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      node.children
        ..clear()
        ..addEntries(sorted.map((c) => MapEntry(c.name, c)));
      for (final child in sorted) {
        sortChildren(child);
      }
    }

    sortChildren(root);
    return SourceFolderTree._(root, nodes);
  }

  /// 目录节点；不存在（扫描后目录消失）返回 null。
  SourceFolderNode? nodeOf(String dir) => _nodes[normalizeDir(dir)];

  /// 当前目录下所有后代文件夹路径（先序、同级按名排序），供全部展开/折叠。
  List<String> descendantFolders(String dir) {
    final start = nodeOf(dir);
    if (start == null) return const [];
    final out = <String>[];
    void walk(SourceFolderNode node) {
      for (final child in node.children.values) {
        out.add(child.path);
        walk(child);
      }
    }

    walk(start);
    return out;
  }
}

/// 目录树缓存：路径列表身份或空文件夹集合变化时才重建。
class SourceFolderTreeCache {
  Object? _refs;
  List<String> _extra = const [];
  SourceFolderTree? _tree;

  SourceFolderTree resolve({
    required List<String> relRefs,
    Iterable<String> extraFolders = const [],
  }) {
    final extra = extraFolders.toList();
    final cached = _tree;
    if (cached != null &&
        identical(_refs, relRefs) &&
        _sameList(_extra, extra)) {
      return cached;
    }
    _refs = relRefs;
    _extra = extra;
    return _tree =
        SourceFolderTree.build(relRefs: relRefs, extraFolders: extra);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
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
