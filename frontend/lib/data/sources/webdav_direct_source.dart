import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/song.dart';
import '../../models/album.dart';
import 'music_source.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// WebDAV 直连源完整实现（阶段 3）。
///
/// - 扫描：Isolate 内递归 PROPFIND + Range 读头部 + 纯 Dart 解析元数据，
///   产出 [DirectSongRow] 列表，主 isolate 落库到 [LocalIndex]（增量）。
/// - 播放：dart:io HTTP Range GET，支持 seek/断点。
/// - 封面：提取嵌入图存本地 `covers/<hash>.jpg`，DB 记路径。
class WebdavDirectSource implements MusicSource {
  final String name;
  final String baseUrl;
  final String username;
  final String password;
  final LocalIndex index;

  WebdavDirectSource({
    required this.name,
    required this.baseUrl,
    this.username = '',
    this.password = '',
    required this.index,
  }) : _base = _normalizeBase(baseUrl);

  final String _base;

  @override
  String get key => 'webdav:$name';

  @override
  SourceKind get kind => SourceKind.webdav;

  @override
  bool get supportsDirect => true;

  // ---------- 服务器模式接口（直连源不提供） ----------

  @override
  String? streamUrl(int songId) => null;

  @override
  Map<String, String>? streamHeaders() => null;

  @override
  Future<List<Song>> fetchSongs(
          {String? query, int page = 1, int size = 50}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  @override
  Future<List<Album>> fetchAlbums(
          {String? query, int page = 1, int size = 50}) async =>
      const [];

  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async => const [];

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan() async {
    // 先复制出可跨 isolate 发送的原始值，再闭包引用（避免捕获 this）。
    final srcKey = key;
    final base = _base;
    final user = username;
    final pass = password;
    final coversDir = p.join(index.dir, 'covers');
    final out = await Isolate.run(
      () => _webdavWalk(
        key: srcKey,
        baseUrl: base,
        username: user,
        password: pass,
      ),
    );
    final alive = <String>[];
    for (final item in out) {
      alive.add(item.row.ref);
      final coverPath = (item.cover == null || item.cover!.isEmpty)
          ? null
          : _persistCoverToDir(item.cover!, item.row.ref, coversDir);
      index.upsertSong(DirectSongRow(
        sourceKey: srcKey,
        ref: item.row.ref,
        title: item.row.title,
        artist: item.row.artist,
        album: item.row.album,
        trackNo: item.row.trackNo,
        year: item.row.year,
        genre: item.row.genre,
        duration: item.row.duration,
        format: item.row.format,
        size: item.row.size,
        mtime: item.row.mtime,
        coverPath: coverPath,
      ));
    }
    index.markMissingExcept(srcKey, alive);
    index.clearMissing(srcKey);
    return ScanSummary(added: out.length, updated: 0, total: out.length);
  }

  // 扫描相关网络/解析辅助逻辑已下沉为文件底部顶层函数，供 Isolate.run 使用。

  // ---------- 直连播放 ----------

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final url = _resolve(song.sourceRef, _base);
    final client = _newClient();
    final req = await client.getUrl(Uri.parse(url));
    _auth(req, username, password);
    if (range != null) {
      req.headers.set(
          HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end ?? ''}');
    }
    final resp = await req.close();
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      await resp.drain<void>();
      client.close(force: true);
      throw HttpException('WebDAV 播放失败: HTTP ${resp.statusCode}',
          uri: Uri.parse(url));
    }
    final contentType =
        resp.headers.contentType?.mimeType ?? 'application/octet-stream';
    int contentLength;
    if (range == null) {
      contentLength = resp.contentLength;
    } else {
      contentLength =
          (range.length ?? (resp.contentLength > 0 ? resp.contentLength : 0));
    }
    final broadcast = resp.map((b) => b).asBroadcastStream();
    // 流结束后释放 HttpClient 连接（避免跨 request 累积）。
    broadcast.listen(
      null,
      onDone: () => client.close(force: true),
      onError: (_) => client.close(force: true),
      cancelOnError: true,
    );
    return OpenedStream(
      contentLength: contentLength,
      contentType: contentType,
      stream: broadcast,
    );
  }

  @override
  Future<void> close() async {}

  // ---------- 离线缓存（DESIGN §6.5） ----------

  String _cacheKey(Song song) =>
      md5.convert(utf8.encode('$key|${song.sourceRef}')).toString();

  @override
  Future<String?> cachedFilePath(Song song) async =>
      index.cachedPath(_cacheKey(song));

  @override
  Future<void> cacheSong(Song song) async {
    final cacheKey = _cacheKey(song);
    if (index.isCached(cacheKey)) return;
    final client = _newClient();
    try {
      final tmp = File('${p.join(index.dir, 'cache')}/.tmp-$cacheKey');
      final req =
          await client.getUrl(Uri.parse(_resolve(song.sourceRef, _base)));
      _auth(req, username, password);
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        await resp.drain<void>();
        throw HttpException('WebDAV 缓存失败: HTTP ${resp.statusCode}');
      }
      final sink = tmp.openSync(mode: FileMode.write);
      int total = 0;
      await for (final chunk in resp) {
        sink.writeFromSync(chunk);
        total += chunk.length;
      }
      sink.closeSync();
      index.cacheCommit(cacheKey, tmp.path, total);
    } finally {
      client.close(force: true);
    }
  }

  // ---------- config ----------

  Map<String, String> get configJ => {
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
      };

  String get configJson => jsonEncode(configJ);
}

// ---------- helpers ----------

class _WebdavEntry {
  final bool isDir;
  final String href;
  final int size;
  final String fullUrl;
  int mtime = 0;
  _WebdavEntry({
    required this.isDir,
    required this.href,
    this.size = 0,
    this.fullUrl = '',
  });

  String get ext {
    final i = href.lastIndexOf('.');
    return i >= 0 ? href.substring(i + 1).toLowerCase() : '';
  }
}

/// 进入 isolate：递归 PROPFIND + Range 读头部元数据，返回可落库行与封面字节。
///
/// 只接收可跨 isolate 发送的原始值（不使用实例字段），因此可用 [Isolate.run]。
Future<List<_WebdavWalkOut>> _webdavWalk({
  required String key,
  required String baseUrl,
  required String username,
  required String password,
}) async {
  final client = _newClient();
  final files = <_WebdavEntry>[];
  final out = <_WebdavWalkOut>[];
  try {
    await _listRecursive(client, baseUrl, files, username, password)
        .timeout(const Duration(seconds: 300));
    for (final f in files) {
      final meta = await _probe(client, f, username, password);
      out.add(_WebdavWalkOut(
        DirectSongRow(
          sourceKey: key,
          ref: f.href,
          title: meta?.title?.isNotEmpty == true
              ? meta!.title!
              : fallbackTitle(f.href),
          artist: meta?.artist,
          album: meta?.album,
          trackNo: meta?.trackNo,
          year: meta?.year,
          genre: meta?.genre,
          duration: meta?.duration,
          format: f.ext,
          size: f.size,
          mtime: f.mtime,
          coverPath: null,
        ),
        meta?.cover,
      ));
    }
  } finally {
    client.close(force: true);
  }
  return out;
}

/// isolate 产出：一行歌曲数据 + 可选封面字节（封面落盘在主 isolate 完成）。
class _WebdavWalkOut {
  final DirectSongRow row;
  final Uint8List? cover;
  const _WebdavWalkOut(this.row, this.cover);
}

HttpClient _newClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'SelfMusic';

void _auth(HttpClientRequest req, String username, String password) {
  if (username.isEmpty) return;
  final cred = base64Encode(utf8.encode('$username:$password'));
  req.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
}

Future<Uint8List> _getHead(
    HttpClient client, String url, String username, String password) async {
  final req = await client.getUrl(Uri.parse(url));
  _auth(req, username, password);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${262144 - 1}');
  final resp = await req.close();
  if (resp.statusCode != 200 && resp.statusCode != 206) {
    await resp.drain<void>();
    return Uint8List(0);
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    builder.add(chunk);
    if (builder.length >= 262144) break;
  }
  return builder.takeBytes();
}

Future<void> _listRecursive(HttpClient client, String url,
    List<_WebdavEntry> out, String username, String password) async {
  final entries = await _propfind(client, url, username, password);
  for (final e in entries) {
    if (!e.isDir && _audioExt(e.href)) {
      out.add(e);
    }
    if (out.length >= 20000) {
      throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
    }
  }
  for (final e in entries) {
    if (e.isDir) {
      await _listRecursive(client, e.fullUrl, out, username, password);
    }
  }
}

Future<List<_WebdavEntry>> _propfind(
    HttpClient client, String url, String username, String password) async {
  final req = await client.openUrl('PROPFIND', Uri.parse(url));
  req.headers.set('Depth', '1');
  _auth(req, username, password);
  final resp = await req.close();
  if (resp.statusCode != 207 && resp.statusCode != 200) {
    await resp.drain<void>();
    return const [];
  }
  final body = await utf8.decodeStream(resp);
  return _parsePropfind(body, url);
}

List<_WebdavEntry> _parsePropfind(String xml, String dirUrl) {
  final out = <_WebdavEntry>[];
  final dirPath = _pathOf(dirUrl);
  final doc = XmlDocument.parse(xml);
  for (final resp in doc.findAllElements('response', namespace: '*')) {
    final hrefEl = resp.getElement('href', namespace: '*');
    if (hrefEl == null) continue;
    final raw = hrefEl.innerText.trim();
    if (raw.isEmpty) continue;
    final pathOnly = _pathOf(raw);
    if (pathOnly == dirPath || pathOnly == '$dirPath/') continue;
    // resourcetype/getcontentlength 位于 propstat/prop 内，需在整棵子树按 local name 找。
    final rt = _firstByName(resp, 'resourcetype');
    final isDir = rt != null &&
        rt.children.any((c) => c is XmlElement && c.name.local == 'collection');
    var size = 0;
    final sizeEl = _firstByName(resp, 'getcontentlength');
    if (sizeEl != null) size = int.tryParse(sizeEl.innerText.trim()) ?? 0;
    out.add(_WebdavEntry(
      isDir: isDir,
      href: pathOnly.trimLeft(),
      size: size,
      fullUrl: _resolve(raw, dirUrl),
    ));
  }
  return out;
}

/// 在 [node] 整棵子树里按 local name 找第一个匹配元素（无视 DAV: 命名空间前缀）。
XmlElement? _firstByName(XmlNode node, String name) {
  for (final c in node.descendants) {
    if (c is XmlElement && c.name.local == name) return c;
  }
  return null;
}

Future<AudioMeta?> _probe(
    HttpClient client, _WebdavEntry f, String username, String password) async {
  try {
    final head = await _getHead(client, f.fullUrl, username, password);
    if (head.isEmpty) return null;
    return parseAudioHead(head, f.ext, f.size);
  } catch (_) {
    return null;
  }
}

/// 把封面字节写入 [coversDir]（主 isolate 执行，需访问本地目录）。
String? _persistCoverToDir(Uint8List cover, String ref, String coversDir) {
  try {
    final h = md5.convert(utf8.encode(ref)).toString();
    Directory(coversDir).createSync(recursive: true);
    final filePath = p.join(coversDir, '$h.jpg');
    File(filePath).writeAsBytesSync(cover, flush: true);
    return filePath;
  } catch (_) {
    return null;
  }
}

bool _audioExt(String href) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav)$', caseSensitive: false)
        .hasMatch(href);

String _normalizeBase(String url) {
  var u = url.trim();
  if (!u.contains('://')) u = 'http://$u';
  if (u.endsWith('/')) u = u.substring(0, u.length - 1);
  return u;
}

String _pathOf(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    final uri = Uri.parse(url);
    return uri.path;
  }
  return url.startsWith('/') ? url : '/$url';
}

/// 把 PROPFIND 返回的 href 解析为可请求的完整 URL（相对路径以 [dirUrl] 目录为基准）。
String _resolve(String href, String dirUrl) {
  if (href.startsWith('http://') || href.startsWith('https://')) return href;
  final base = Uri.parse(dirUrl);
  final origin =
      '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}';
  // PROJECT design: webdav root path is `_base`'s path; href is usually server-root-relative.
  final rootPath = base.path.endsWith('/') ? base.path : '${base.path}/';
  if (href.startsWith(rootPath)) {
    return '$origin$href';
  }
  return '$origin${href.startsWith('/') ? href : '/$href'}';
}
