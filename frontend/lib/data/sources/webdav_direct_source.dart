import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/song.dart';
import '../../utils/url_display.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import 'sibling_cover.dart';
import 'webdav_url.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// WebDAV 直连源完整实现（阶段 3）。
///
/// - 扫描：Isolate 内递归 PROPFIND + Range 读头部 + 纯 Dart 解析元数据，
///   [runScan] 驱动（可汇报进度 / 可取消），产出 [_WebdavWalkOut] 列表，
///   主 isolate 批量落库到 [LocalIndex]。
/// - 增量：比对 `(size, mtime, etag)` 指纹，未变化直接跳过读头（零音频下载）。
/// - 只读必要参数：非 fullMeta 时仅解析 标题/歌手/专辑（[parseMinimalHead]），
///   时长/封面等留待播放时懒补全。
/// - 播放：dart:io HTTP Range GET，支持 seek/断点；或直接交给原生播放器。
class WebdavDirectSource implements MusicSource {
  @override
  final String name;
  final String baseUrl;
  final String username;
  final String password;
  final LocalIndex index;

  /// 信任自签名证书（settings.md §3.3 服务端）：扫描/播放/缓存的 dart:io 请求
  /// 跳过证书校验；播放器层（ExoPlayer/mpv 原生起流）不受此开关影响。
  final bool allowSelfSigned;

  WebdavDirectSource({
    required this.name,
    required this.baseUrl,
    this.username = '',
    this.password = '',
    required this.index,
    this.allowSelfSigned = false,
  }) : _base = webdavNormalizeBase(baseUrl);

  final String _base;

  @override
  String get key => 'webdav:$name';

  @override
  SourceKind get kind => SourceKind.webdav;

  @override
  bool get supportsDirect => true;

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions.none(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    // 只传可跨 isolate 发送的原始值（不含 this）。
    final out = await runScan<List<_WebdavWalkOut>>(
      entry: _webdavWalkEntry,
      params: <String, Object?>{
        'key': key,
        'baseUrl': _base,
        'username': username,
        'password': password,
        'allowSelfSigned': allowSelfSigned,
        'minSizeBytes': options.minSizeBytes,
        'minDurationSec': options.minDurationSec,
        'headBytes': options.headBytes,
        'fullMeta': options.fullMeta,
        'fast': options.fast,
        'collectCover': options.collectCover,
        'known': index.scanFingerprint(key),
      },
      token: token,
      onProgress: onProgress,
    );

    final alive = <String>[];
    final toWrite = <DirectSongRow>[];
    var added = 0, updated = 0, unchanged = 0;
    for (final item in out) {
      alive.add(item.row.ref);
      switch (item.kind) {
        case _OutKind.unchanged:
          unchanged++;
          continue;
        case _OutKind.added:
          added++;
        case _OutKind.updated:
          updated++;
      }
      final coverPath = (item.cover == null || item.cover!.isEmpty ||
              !options.collectCover)
          ? null
          : index.persistCover(item.cover!, item.row.ref);
      toWrite.add(DirectSongRow(
        sourceKey: item.row.sourceKey,
        ref: item.row.ref,
        url: item.row.url,
        title: item.row.title,
        titleFromMeta: item.row.titleFromMeta,
        artist: item.row.artist,
        album: item.row.album,
        albumArtist: item.row.albumArtist,
        trackNo: item.row.trackNo,
        year: item.row.year,
        genre: item.row.genre,
        duration: item.row.duration,
        format: item.row.format,
        size: item.row.size,
        mtime: item.row.mtime,
        etag: item.row.etag,
        coverPath: coverPath ?? item.row.coverPath,
      ));
    }
    index.upsertSongs(toWrite);
    index.markMissingExcept(key, alive);
    // 删除不再存在的行（保留收藏）。
    index.clearMissing(key);
    return ScanSummary(
        added: added,
        updated: updated,
        unchanged: unchanged,
        total: alive.length);
  }

  // ---------- 直连播放 ----------

  /// 播放/缓存用完整 URL：优先扫描期持久化的 [Song.sourceUrl]，历史行回落到
  /// base+ref（先解码一层防双重编码），最后统一做「单层编码」规范化。
  String? _playUrl(Song song) {
    final raw = song.sourceUrl ?? webdavResolveRefForPlay(song.sourceRef, _base);
    return webdavCanonicalUrl(raw);
  }

  @override
  String displayPath(Song song) =>
      decodeUrlForDisplay(_playUrl(song) ?? song.sourceRef);

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final url = _playUrl(song)!;
    final client = _newClient(allowSelfSigned);
    final req = await client.getUrl(Uri.parse(url));
    _auth(req, username, password);
    if (range != null) {
      req.headers.set(HttpHeaders.rangeHeader,
          'bytes=${range.start}-${range.end ?? ''}');
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
      contentLength = (range.length ??
          (resp.contentLength > 0 ? resp.contentLength : 0));
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

  /// 直接把 WebDAV URL 交给 just_audio 原生播放（ExoPlayer Range/seek 更可靠）。
  @override
  DirectStream? directStream(Song song) {
    final headers = username.isEmpty
        ? null
        : {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$username:$password'))}',
          };
    return DirectStream(_playUrl(song)!, headers: headers);
  }

  // ---------- 离线缓存（DESIGN §6.5） ----------

  /// 该歌的缓存 key（供 CacheManager 跟踪 LRU / 跳过正在播放）。
  String cacheKeyFor(Song song) =>
      md5.convert(utf8.encode('$key|${song.sourceRef}')).toString();

  @override
  Future<String?> cachedFilePath(Song song) async =>
      index.cachedPath(cacheKeyFor(song));

  @override
  Future<void> cacheSong(Song song) async {
    final cacheKey = cacheKeyFor(song);
    if (index.isCached(cacheKey)) return;
    final client = _newClient(allowSelfSigned);
    try {
      final tmp = File('${p.join(index.dir, 'cache')}/.tmp-$cacheKey');
      final req =
          await client.getUrl(Uri.parse(_playUrl(song)!));
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

// ---------- isolate worker（runScan entry） ----------

void _webdavWalkEntry(Map<String, Object?> msg) async {
  final params = msg['params']! as Map<String, Object?>;
  final send = msg['send']! as SendPort;
  final progress = msg['progress']! as SendPort;
  final cancelReq = ReceivePort();
  send.send({'__cancel__': cancelReq.sendPort});
  var cancelled = false;
  cancelReq.listen((_) => cancelled = true);
  try {
    final out = await _webdavWalk(
      key: params['key']! as String,
      baseUrl: params['baseUrl']! as String,
      username: params['username']! as String,
      password: params['password']! as String,
      allowSelfSigned: params['allowSelfSigned']! as bool,
      minSizeBytes: params['minSizeBytes']! as int,
      minDurationSec: params['minDurationSec']! as int,
      headBytes: params['headBytes']! as int,
      fullMeta: params['fullMeta']! as bool,
      fast: params['fast']! as bool,
      collectCover: params['collectCover']! as bool,
      known: (params['known']! as Map<Object?, Object?>)
          .map((k, v) => MapEntry(k as String, v as ScanFingerprint)),
      onProgress: (p) => progress.send(p),
      isCancelled: () => cancelled,
    );
    send.send(out);
  } finally {
    cancelReq.close();
  }
}

/// 进入 worker isolate：递归 PROPFIND + Range 读头部元数据，返回可落库行与封面字节。
Future<List<_WebdavWalkOut>> _webdavWalk({
  required String key,
  required String baseUrl,
  required String username,
  required String password,
  required bool allowSelfSigned,
  required int minSizeBytes,
  required int minDurationSec,
  required int headBytes,
  required bool fullMeta,
  required bool fast,
  required bool collectCover,
  required Map<String, ScanFingerprint> known,
  void Function(ScanProgress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final client = _newClient(allowSelfSigned);
  final files = <_WebdavEntry>[];
  final out = <_WebdavWalkOut>[];
  final imageCache = <String, Uint8List?>{}; // 同目录图片探测缓存（候选 URL → 字节/null）
  onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
  try {
    await _listRecursive(client, baseUrl, files, username, password,
        isCancelled: isCancelled);
    if (isCancelled?.call() ?? false) return out;
    onProgress?.call(ScanProgress(listing: false, done: 0, total: files.length));
    var done = 0;
    for (final f in files) {
      done++;
      if (isCancelled?.call() ?? false) break;
      onProgress?.call(
          ScanProgress(listing: false, done: done, total: files.length));
      // 已存在且指纹未变 → 跳过探测（零音频下载）。
      final fp = known[f.href];
      if (fp != null &&
          fp.same(f.size, f.mtime, f.etag)) {
        out.add(_WebdavWalkOut(
          _rowFor(key, f, null, fullMeta, fast),
          null,
          _OutKind.unchanged,
        ));
        continue;
      }
      // 「忽略音频」大小过滤：不响应探测的过小文件直接跳过。
      if (minSizeBytes > 0 && f.size > 0 && f.size < minSizeBytes) continue;
      if (fast) {
        out.add(_WebdavWalkOut(
          _rowFor(key, f, null, false, true),
          null,
          fp == null ? _OutKind.added : _OutKind.updated,
        ));
        continue;
      }
      AudioMeta? meta;
      if (!fullMeta) {
        // 最小模式：仅头部标签（时长仍用于过滤，不入库由 _rowFor 处理）。
        try {
          final head =
              await _getHead(client, f.fullUrl, username, password, headBytes);
          if (head.isNotEmpty) meta = parseAudioHead(head, f.ext, f.size);
        } catch (_) {
          // 单文件探测失败跳过（不中断整源扫描）。
        }
      } else {
        // 完整模式：头部补读（大封面）+ 尾部补读（m4a moov-at-end / ogg 时长）+ 同目录图片回退。
        try {
          meta = await readAudioMeta(
            readRange: (start, length) => _getHead(
                client, f.fullUrl, username, password, length,
                start: start),
            format: f.ext,
            fileSize: f.size,
            headBytes: headBytes,
          );
        } catch (_) {
          // 单文件读取失败跳过（不中断整源扫描）。
        }
        if (meta != null) {
          if (!collectCover) {
            meta.cover = null;
          } else {
            meta.cover ??= await _siblingImageWebdav(
                client, f, username, password, imageCache);
          }
        }
      }
      // 时长过滤：仅在解析出时长时生效，避免误杀探测失败的文件。
      final dur = meta?.duration ?? 0;
      if (minDurationSec > 0 && dur > 0 && dur < minDurationSec) continue;
      out.add(_WebdavWalkOut(
        _rowFor(key, f, meta, fullMeta, false),
        meta?.cover,
        fp == null ? _OutKind.added : _OutKind.updated,
      ));
    }
  } finally {
    client.close(force: true);
  }
  return out;
}

/// 扫描期同目录图片回退（WebDAV）：候选 URL 按次探测，命中缓存（跨歌单目录去重）。
Future<Uint8List?> _siblingImageWebdav(HttpClient client, _WebdavEntry f,
    String username, String password, Map<String, Uint8List?> cache) async {
  final slash = f.fullUrl.lastIndexOf('/');
  if (slash < 0) return null;
  final base = f.fullUrl.substring(0, slash + 1);
  final name = f.fullUrl.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final candidates = <String>[
    if (stem.isNotEmpty)
      for (final ext in const [
        '.png', '.jpg', '.jpeg', '.webp', '.PNG', '.JPG',
      ])
        '$base$stem$ext',
    for (final n in const [
      'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png',
      'front.jpg', 'album.jpg',
    ])
      '$base$n',
  ];
  for (final url in candidates) {
    if (url == f.fullUrl) continue;
    if (cache.containsKey(url)) {
      final hit = cache[url];
      if (hit != null) return hit;
      continue;
    }
    final bytes = await _getHead(
        client, url, username, password, kCoverReadCapBytes);
    if (isImageBytes(bytes)) {
      cache[url] = bytes;
      return bytes;
    }
    cache[url] = null;
  }
  return null;
}

/// isolate 产出：一行歌曲数据 + 可选封面字节（封面落盘在主 isolate 完成）。
class _WebdavWalkOut {
  final DirectSongRow row;
  final Uint8List? cover;
  final _OutKind kind;
  const _WebdavWalkOut(this.row, this.cover, this.kind);
}

/// 落库动作分类（增量统计用）。
enum _OutKind { added, updated, unchanged }

DirectSongRow _rowFor(String key, _WebdavEntry f, AudioMeta? meta,
    bool fullMeta, bool fast) {
  final titleFromMeta = !fast && (meta?.title?.isNotEmpty ?? false);
  final title = titleFromMeta ? meta!.title! : fallbackTitle(f.href);
  return DirectSongRow(
    sourceKey: key,
    ref: f.href,
    url: f.fullUrl,
    title: title,
    titleFromMeta: titleFromMeta,
    artist: meta?.artist,
    album: meta?.album,
    albumArtist: meta?.albumArtist,
    trackNo: fullMeta ? meta?.trackNo : null,
    year: fullMeta ? meta?.year : null,
    genre: fullMeta ? meta?.genre : null,
    duration: fullMeta ? meta?.duration : null,
    format: f.ext,
    size: f.size,
    mtime: f.mtime,
    etag: f.etag,
    coverPath: null,
  );
}

// ---------- helpers ----------

class _WebdavEntry {
  final bool isDir;
  final String href;
  final int size;
  final String fullUrl;
  final int mtime;
  final String? etag;
  _WebdavEntry({
    required this.isDir,
    required this.href,
    this.size = 0,
    this.fullUrl = '',
    this.mtime = 0,
    this.etag,
  });

  String get ext {
    final i = href.lastIndexOf('.');
    return i >= 0 ? href.substring(i + 1).toLowerCase() : '';
  }
}

HttpClient _newClient(bool allowSelfSigned) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'SelfMusic'
  ..badCertificateCallback =
      allowSelfSigned ? (cert, host, port) => true : null;

void _auth(HttpClientRequest req, String username, String password) {
  if (username.isEmpty) return;
  final cred = base64Encode(utf8.encode('$username:$password'));
  req.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
}

Future<Uint8List> _getHead(HttpClient client, String url, String username,
    String password, int headBytes, {int start = 0}) async {
  final req = await client.getUrl(Uri.parse(url));
  _auth(req, username, password);
  req.headers.set(HttpHeaders.rangeHeader,
      'bytes=$start-${start + headBytes - 1}');
  final resp = await req.close();
  if (resp.statusCode != 200 && resp.statusCode != 206) {
    await resp.drain<void>();
    return Uint8List(0);
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    builder.add(chunk);
    if (builder.length >= headBytes) break;
  }
  return builder.takeBytes();
}

Future<void> _listRecursive(HttpClient client, String url,
    List<_WebdavEntry> out, String username, String password,
    {bool Function()? isCancelled}) async {
  // WebDAV 目录请求须以 '/' 结尾（如 /dav/ → 207；/dav → 部分服务器 301 重定向
  // 导致 3xx 被 _propfind 判为非 207/200 而返回空）。目录 href 已带尾斜杠，
  // 仅根 base 被 webdavNormalizeBase 去掉了尾斜杠，这里补上。
  final dirUrl = url.endsWith('/') ? url : '$url/';
  final entries = await _propfind(client, dirUrl, username, password);
  final dirs = <String>[];
  for (final e in entries) {
    if (isCancelled?.call() ?? false) return;
    if (!e.isDir && _audioExt(e.href)) {
      out.add(e);
    } else if (e.isDir) {
      dirs.add(e.fullUrl);
    }
    if (out.length >= 20000) {
      throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
    }
  }
  // 目录递归并发（有界 6），显著缩短大目录树的枚举时间。
  await _mapConcurrent(dirs, 6, (d) async {
    if (isCancelled?.call() ?? false) return;
    await _listRecursive(client, d, out, username, password,
        isCancelled: isCancelled);
  });
}

Future<List<_WebdavEntry>> _propfind(
    HttpClient client, String url, String username, String password) async {
  final req = await client.openUrl('PROPFIND', Uri.parse(url));
  req.headers.set('Depth', '1');
  _auth(req, username, password);
  final resp = await req.close().timeout(const Duration(seconds: 30));
  if (resp.statusCode != 207 && resp.statusCode != 200) {
    await resp.drain<void>();
    return const [];
  }
  final body = await utf8.decodeStream(resp).timeout(const Duration(seconds: 30));
  return _parsePropfind(body, url);
}

List<_WebdavEntry> _parsePropfind(String xml, String dirUrl) {
  final out = <_WebdavEntry>[];
  final dirPath = webdavPathOf(dirUrl);
    final doc = XmlDocument.parse(xml);
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final hrefEl = resp.getElement('href', namespace: '*');
      if (hrefEl == null) continue;
      final raw = hrefEl.innerText.trim();
      if (raw.isEmpty) continue;
      final pathOnly = webdavPathOf(raw);
    if (pathOnly == dirPath || pathOnly == '$dirPath/') continue;
    // resourcetype/getcontentlength/getlastmodified/getetag 位于 propstat/prop 内。
    final rt = _firstByName(resp, 'resourcetype');
    final isDir = rt != null &&
        rt.children.any((c) => c is XmlElement && c.name.local == 'collection');
    var size = 0;
    final sizeEl = _firstByName(resp, 'getcontentlength');
    if (sizeEl != null) size = int.tryParse(sizeEl.innerText.trim()) ?? 0;
    var mtime = 0;
    final mt = _firstByName(resp, 'getlastmodified');
    if (mt != null) {
      mtime = _parseHttpDateMs(mt.innerText.trim());
    }
    String? etag;
    final et = _firstByName(resp, 'getetag');
    if (et != null && et.innerText.trim().isNotEmpty) {
      etag = et.innerText.trim();
    }
    out.add(_WebdavEntry(
      isDir: isDir,
      // 存人类可读的路径（解码后）作为 ref/标题来源；网络请求用的 fullUrl 保持编码。
      href: webdavDecodePath(pathOnly.trimLeft()),
      size: size,
      fullUrl: webdavResolve(raw, dirUrl),
      mtime: mtime,
      etag: etag,
    ));
  }
  return out;
}

/// getlastmodified（RFC1123，如 `Wed, 18 Sep 2026 10:00:00 GMT`）→ epoch 秒（UTC）。
int _parseHttpDateMs(String value) {
  try {
    return HttpDate.parse(value).millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return 0;
  }
}

/// 在 [node] 整棵子树里按 local name 找第一个匹配元素（无视 DAV: 命名空间前缀）。
XmlElement? _firstByName(XmlNode node, String name) {
  for (final c in node.descendants) {
    if (c is XmlElement && c.name.local == name) return c;
  }
  return null;
}

/// 有界并发：至多 [pool] 个 [fn] 同时执行（顺序保序）。
Future<void> _mapConcurrent<T>(
    List<T> items, int pool, Future<void> Function(T) fn) async {
  if (items.isEmpty) return;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      await fn(items[i]);
    }
  }
  await Future.wait([for (var i = 0; i < pool; i++) worker()]);
}

bool _audioExt(String href) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav)$', caseSensitive: false)
        .hasMatch(href);