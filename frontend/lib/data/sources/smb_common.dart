/// SMB 直连的共享纯逻辑（双后端共用，与平台无关，可单测）：
///
/// - 路径：`ref` 为源内相对引用（`/` 分隔、相对 `rootPath`）；远端共享相对
///   路径为 `rootPath/ref`（BACKSLASH 不出现在任何一层，对外统一 `/`，
///   两后端各自转义）；
/// - 后端选择：非 ohos 走 `dart_smb2`（FFI libsmb2，SMB2/3），ohos 走 vendored
///   `smb_connect`（纯 Dart，最高 SMB 2.1），见 DEVELOPER.md「客户端播放源」。
library;

import 'dart:convert';

/// 单次范围读块（喂播放器/缓存的粒度，与 DEVELOPER.md「客户端播放源」「单次读 256KB」一致）。
const int kSmbReadChunkBytes = 256 * 1024;

/// 单源歌曲上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护，与 WebDAV/SFTP 同口径）。
const int kSmbMaxEntries = 20000;

/// SMB 非 2xx 语义外的连接/协议错误：toString 面向用户直接展示。
class SmbStatusException implements Exception {
  final String message;
  const SmbStatusException(this.message);

  @override
  String toString() => message;
}

/// 扫描枚举到的原始条目（落库前形态；`mtime` 为秒级 epoch，与本地/SFTP 同口径）。
class SmbScanEntry {
  final String ref;
  final int size;
  final int mtime;
  const SmbScanEntry({required this.ref, required this.size, required this.mtime});
}

/// 源内相对引用 → 共享内相对远端路径（过滤 `.`/`..` 防越界；空串=共享根）。
/// 纯函数，可单测。
String smbRemotePath(String rootPath, String ref) {
  final parts = <String>[
    ...rootPath.split('/'),
    ...ref.split('/'),
  ].where((s) => s.isNotEmpty && s != '.' && s != '..').toList();
  return parts.join('/');
}

/// 共享内路径 → 源内相对引用（相对 `rootPath` 的后缀；对不上时原样返回）。
/// 纯函数，可单测（枚举递归用）。
String smbRelRef(String rootPath, String remote) {
  final rootParts = rootPath
      .split('/')
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  final remoteParts = remote
      .split('/')
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  if (rootParts.isEmpty) return remoteParts.join('/');
  if (remoteParts.length < rootParts.length) return remoteParts.join('/');
  for (var i = 0; i < rootParts.length; i++) {
    if (remoteParts[i] != rootParts[i]) return remoteParts.join('/');
  }
  return remoteParts.sublist(rootParts.length).join('/');
}

/// 音频后缀判定（与 WebDAV/SFTP 同集合）。
bool isSmbAudioFile(String path) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$', caseSensitive: false)
        .hasMatch(path);

String smbExtOf(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 ? path.substring(i + 1).toLowerCase() : '';
}

String smbMimeOf(String ext) {
  switch (ext) {
    case 'flac':
      return 'audio/flac';
    case 'm4a':
    case 'aac':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    case 'wav':
      return 'audio/wav';
    case 'aif':
    case 'aiff':
    case 'aifc':
      return 'audio/aiff';
    default:
      return 'audio/mpeg';
  }
}

/// X-Origin-Smb 信封体（base64url(JSON)：`{u, p?}`），供服务端代理回源鉴权
/// （内存态单次使用；匿名源只有 `u` 空串）。纯函数，可单测。
String buildSmbEnvelope({required String username, String? password}) {
  final m = <String, String>{'u': username};
  if (password != null && password.isNotEmpty) m['p'] = password;
  return base64Url.encode(utf8.encode(jsonEncode(m)));
}

/// 代理 origin（`smb://host/share/逐段编码路径`，无 userinfo；凭据走信封）。
/// 纯函数，可单测。IPv6 主机自动加方括号。
String smbOriginUrl({
  required String host,
  required String share,
  required String remote,
}) {
  var h = host.trim();
  if (h.contains(':') && !(h.startsWith('[') && h.endsWith(']'))) {
    h = '[$h]';
  }
  final segs = <String>[
    ...share.split('/').where((s) => s.isNotEmpty),
    ...remote.split('/').where((s) => s.isNotEmpty),
  ].map(Uri.encodeComponent).join('/');
  return 'smb://$h/$segs';
}

/// 错误文本截断（超长原生错误只保留标题，避免把 NTSTATUS 堆栈糊到 UI）。
String smbShortErr(Object e, String what) {
  final s = e.toString().replaceFirst(
      RegExp(r'^(Bad state: |StateError: |Smb2Exception\([^)]*\): )'), '');
  return s.length > 160 ? what : '$what：$s';
}
