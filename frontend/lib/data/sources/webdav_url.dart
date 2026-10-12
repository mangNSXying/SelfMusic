/// WebDAV URL 路径解析（纯函数，供扫描 / 播放 / 缓存共用，可单元测试）。
library;

import 'dart:convert' show utf8;

/// 归一化 base：补 scheme、去尾斜杠。缺 scheme 时默认补 `https://`（需明文 HTTP
/// 必须显式写 `http://`）。如 `192.168.1.10:5005/media` → `https://.../media`。
/// 二重保险的最后一道：大小写 scheme（`HTTP://`）视为已有 scheme，不重复补前缀。
String webdavNormalizeBase(String url) {
  var u = url.trim();
  if (u.isEmpty) return u;
  if (!_hasScheme(u)) u = 'https://$u';
  return u.replaceAll(RegExp(r'/+$'), '');
}

/// 是否带有 scheme（含 `://` 且 scheme 段无空白；大小写不敏感）。
bool _hasScheme(String s) {
  final i = s.indexOf('://');
  if (i <= 0) return false;
  if (s.substring(0, i).contains(RegExp(r'\s'))) return false;
  return true;
}

/// 从（可能带 query / fragment 的）URL 中取出路径段（以 / 开头）。
String webdavPathOf(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return Uri.parse(url).path;
  }
  return url.startsWith('/') ? url : '/$url';
}

/// 把 PROPFIND 返回的编码路径解码为人类可读路径（ref / 标题使用）。
String webdavDecodePath(String path) {
  try {
    return Uri.decodeFull(path);
  } catch (_) {
    return path;
  }
}

/// 把解码后的 ref 重新按路径段编码，供实际网络请求使用。
String webdavEncodePath(String ref) {
  final parts = ref.split('/').where((s) => s.isNotEmpty);
  return '/${parts.map(Uri.encodeComponent).join('/')}';
}

/// ref 的新旧多种形态（原样 / 解码态 / 宽松编码 / 严格编码）去重列表。
///
/// 历史版本曾在 idx_songs.ref / play_meta.song_ref 里存 ENCODE 文本，且不同
/// 服务器对子界定符（`!` 等）的编码风格不一（`!` vs `%21`）；按 ref 回查
/// （喜欢列表、歌单快照回填）时逐一尝试，兼容各种入库形态。
List<String> webdavRefVariants(String ref) {
  final out = <String>[ref];
  void add(String v) {
    if (!out.contains(v)) out.add(v);
  }

  try {
    add(Uri.decodeComponent(ref));
  } catch (_) {}
  try {
    final d = Uri.decodeComponent(ref);
    add(webdavEncodePath(d));
    add(_webdavEncodePathStrict(d));
  } catch (_) {
    // ref 本身就是 Unicode（decodeComponent 拒收）：直接产出两种编码形态。
    add(webdavEncodePath(ref));
    add(_webdavEncodePathStrict(ref));
  }
  return out;
}

/// 严格编码：除 unreserved（A-Za-z0-9 `-_.~`）与 `/` 分隔符外全部百分号编码，
/// 兼容把 `!` 等子界定符也编码的服务器/历史入库风格（`!` → `%21`）。
String _webdavEncodePathStrict(String ref) {
  const keep = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/';
  final buf = StringBuffer();
  for (final rune in ref.runes) {
    final c = String.fromCharCode(rune);
    if (c.length == 1 && keep.contains(c)) {
      buf.write(c);
      continue;
    }
    for (final b in utf8.encode(c)) {
      buf.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return '/${buf.toString().replaceAll(RegExp(r'^/+'), '')}';
}

/// 由已解码的 ref 生成完整请求 URL（base 为去尾斜杠的源根）。
String webdavResolveRef(String ref, String base) =>
    webdavResolve(webdavEncodePath(ref), base);

/// 播放期重建（兼容历史 ENCODE 行）。
///
/// 历史版本曾在 idx_songs.ref 里存 ENCODE 文本（如 `/dav/%E4%BD%90…%21.flac`），
/// 若直接 `webdavEncodePath` 会二次编码（`%` → `%25`），WebDAV 返回 404 → Android
/// ExoPlayer 报 `Source error`。这里先把 ref 解码一层（已是 Unicode 则无副作用），
/// 再按路径段重编码，编解码/Unicode/历史 ENCODE 三种输入均收敛为单层编码 URL。
String webdavResolveRefForPlay(String ref, String base) {
  String decoded;
  try {
    decoded = Uri.decodeComponent(ref);
  } catch (_) {
    decoded = ref;
  }
  return webdavResolve(webdavEncodePath(decoded), base);
}

/// 把 PROPFIND 返回的 href 解析为可请求的完整 URL（相对路径以 [dirUrl] 目录为基准）。
///
/// 兼容三种服务器回报风格：
///  - 根绝对路径且位于 base 之下：`/media/song.mp3`（最常见，NAS 普遍如此）；
///  - 相对 base 目录的绝对路径：如 base=`http://h/media` 时回报 `/song.mp3`；
///  - 相对请求目录的文件名：如请求 `/media/` 时回报 `song.mp3`；
///  - 绝对 URL：`http://host/media/song.mp3`，原样返回。
///
/// 均按 [dirUrl] 所在目录为基准解析，扫描期算出的 fullUrl 与播放期重建一致。
String webdavResolve(String href, String dirUrl) {
  if (href.startsWith('http://') || href.startsWith('https://')) return href;
  final base = Uri.parse(dirUrl);
  final origin =
      '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}';
  final rootPath = base.path.endsWith('/') ? base.path : '${base.path}/';
  if (href.startsWith(rootPath)) {
    return '$origin$href';
  }
  if (href.startsWith('/')) {
    final dir = dirUrl.endsWith('/')
        ? dirUrl.substring(0, dirUrl.length - 1)
        : dirUrl;
    return '$dir$href';
  }
  final sep = dirUrl.endsWith('/') ? '' : '/';
  return '$dirUrl$sep$href';
}

/// 把任意来源的完整 URL（历史行 ENCODE 的 ref 再重建、服务器直出 Unicode、
/// 或已正确编码的扫描期 URL）规范化为「单层百分号编码」的可请求 URL。
///
/// 历史数据：idx_songs.ref 曾存过 ENCODE 文本（`%E4%BD%90…%21`），回退重建会产生
/// `%25` 双重编码 → WebDAV 404 → Android ExoPlayer 报 `Source error`。此处统一
/// 「解码一层 → 按路径段重编码」：编码/Unicode/双重编码三种输入均收敛成单层编码。
String webdavCanonicalUrl(String raw) {
  Uri u;
  try {
    u = Uri.parse(raw);
  } catch (_) {
    return raw;
  }
  final hostPart =
      '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
  String path;
  try {
    path = webdavEncodePath(Uri.decodeComponent(u.path));
  } catch (_) {
    path = webdavEncodePath(u.path.trimLeft());
  }
  final query = u.query.isEmpty ? '' : '?${u.query}';
  return '$hostPart$path$query';
}