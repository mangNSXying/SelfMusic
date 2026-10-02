import 'dart:async';
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
import 'webdav_url.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// WebDAV 直连源完整实现（阶段 3）。
///
/// - 扫描：Isolate 内递归 PROPFIND + Range 读头部 + 纯 Dart 解析元数据，
///   [runScan] 驱动（可汇报进度 / 可取消），产出 [_WebdavWalkOut] 列表，
///   主 isolate 批量落库到 [LocalIndex]。
/// - 增量：比对 `(size, mtime, etag)` 指纹，未变化直接跳过读头（零音频下载）。
/// - 快速：只建索引——只用 PROPFIND 的 ref/size/mtime/etag 落库，不读音频内容，
///   元数据与封面全部留空，交给播放时补读与后台补读；
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
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    // 只传可跨 isolate 发送的原始值（不含 this）。
    final known = index.scanFingerprint(key);
    final out = await runScan<List<_WebdavWalkOut>>(
      entry: _webdavWalkEntry,
      params: <String, Object?>{
        'key': key,
        'baseUrl': _base,
        'username': username,
        'password': password,
        'allowSelfSigned': allowSelfSigned,
        'minSizeBytes': options.minSizeBytes,
        'known': known,
      },
      token: token,
      onProgress: onProgress,
    );

    // 数据安全闸：扫描正常完成但结果为空、而本地库该源已有曲目时，大概率是
    // 指到了空目录/配错路径——中止并报错，绝不静默清库（markMissingExcept +
    // clearMissing 会把整库当「全部消失」删除）。取消的半途扫描不在此列。
    // 如确认服务器目录确实已清空，删除并重建该源即可。
    if (out.isEmpty &&
        known.isNotEmpty &&
        !(token?.cancelled ?? false)) {
      throw ScanWorkerException('扫描结果为 0，但本地库已有 ${known.length} 首；'
          '为防止误清库已中止。如确认服务器目录已清空，请删除并重建该源');
    }

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
      // 快速扫描不取封面（item.cover 恒为 null），此分支保留给未来取值方式变化。
      final coverPath = item.cover == null || item.cover!.isEmpty
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
    // 提交（写隔离批量单事务）：await 保证 scan 返回时行已落库可见。
    await index.upsertSongs(toWrite);
    await index.markMissingExcept(key, alive);
    // 删除不再存在的行（保留收藏）。
    await index.clearMissing(key);
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

  /// 预热：1 字节 Range 请求——够走完 DNS/TCP/TLS/鉴权与路由，又不下载音频。
  ///
  /// 用 GET+Range 而不是 HEAD：部分 WebDAV 服务对 HEAD 返回 405，却正常支持
  /// Range（与 [open] 的取流路径完全一致，避免预热与实际装载口径不同）。
  @override
  Future<void> probe(Song song) async {
    final url = _playUrl(song);
    if (url == null) throw StateError('WebDAV 缺少播放地址，无法预热');
    final client = _newClient(allowSelfSigned);
    try {
      final req = await client.getUrl(Uri.parse(url));
      _auth(req, username, password);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw SourceAuthException(WebdavStatusException(resp.statusCode, url).toString());
        }
        throw WebdavStatusException(resp.statusCode, url);
      }
      // 只取到第一块数据就收手：Range 被忽略时这里是 200 + 整首，drain 会把整首
      // 读下来（预热反而成了隐藏的整曲下载）。读完即取消订阅，最后强制关 client。
      try {
        await resp.first;
      } on StateError {
        // 空响应体：状态码已确认可达，不算失败。
      }
    } finally {
      client.close(force: true);
    }
  }

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
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw SourceAuthException(WebdavStatusException(resp.statusCode, url).toString());
      }
      throw WebdavStatusException(resp.statusCode, url);
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
    // 范围读取时 contentLength 只是「这次拿到多少」，资源真实大小在
    // Content-Range 尾部（`bytes 0-8388607/20971520`）。调用方（如同目录图片
    // 探测）要靠它判断读到的字节是不是被截断的片段。
    int? totalLength;
    if (range == null) {
      if (resp.contentLength > 0) totalLength = resp.contentLength;
    } else {
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null) {
        final slash = cr.lastIndexOf('/');
        if (slash >= 0 && slash + 1 < cr.length) {
          final t = int.tryParse(cr.substring(slash + 1).trim());
          if (t != null && t > 0) totalLength = t;
        }
      }
      // 服务端忽略 Range 直接返回 200 全量时，contentLength 就是资源大小。
      if (totalLength == null &&
          resp.statusCode == 200 &&
          resp.contentLength > 0 &&
          resp.contentLength > contentLength) {
        totalLength = resp.contentLength;
      }
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
      totalLength: totalLength,
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

  /// 缓存落盘缓冲阈值（攒够才顺序写一次）。
  static const int _cacheWriteBufBytes = 1 << 20;

  /// 该歌的缓存 key（供 CacheManager 跟踪 LRU / 跳过正在播放）。
  String cacheKeyFor(Song song) =>
      md5.convert(utf8.encode('$key|${song.sourceRef}')).toString();

  @override
  Future<String?> cachedFilePath(Song song) async =>
      index.cachedPath(cacheKeyFor(song));

  @override
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async {
    final cacheKey = cacheKeyFor(song);
    if (index.isCached(cacheKey)) return;
    final client = _newClient(allowSelfSigned);
    final tmp = File(p.join(index.cacheDir, '.tmp-$cacheKey'));
    var committed = false;
    try {
      final req =
          await client.getUrl(Uri.parse(_playUrl(song)!));
      _auth(req, username, password);
      final resp = await _withDeadline(
          req.close(), _kRequestDeadline, 'WebDAV 缓存取流（${_playUrl(song)}）');
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        await resp.drain<void>();
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw SourceAuthException(WebdavStatusException(resp.statusCode, _playUrl(song)!).toString());
        }
        throw WebdavStatusException(resp.statusCode, _playUrl(song)!);
      }
      // 大缓冲顺序写：网络块常为 8~64KB，逐块 writeFromSync 会把「启动缓存」
      // 变成上万次小写入（CSV：cache\.tmp-* 70.7MB/12952 次写）。攒够 1MB 再落。
      final sink = tmp.openSync(mode: FileMode.write);
      var buf = BytesBuilder(copy: false);
      int total = 0;
      try {
        // 整曲下载原先没有总时限：后台预热遇到半死不活的连接会一直挂着，
        // 既占连接也拖住预热槽位（_warmingKey 一占就是整首的时长）。
        await _withDeadline(
          () async {
            await for (final chunk in resp) {
              // 换歌后这份预载已作废：整曲下载能把队列里的当前曲元数据拖到几分钟后。
              if (shouldAbort?.call() == true) {
                throw const PreloadAbortedException();
              }
              buf.add(chunk);
              total += chunk.length;
              if (buf.length >= _cacheWriteBufBytes) {
                sink.writeFromSync(buf.takeBytes());
              }
            }
          }(),
          _kCacheDownloadDeadline,
          'WebDAV 缓存整曲下载',
        );
        if (buf.isNotEmpty) sink.writeFromSync(buf.takeBytes());
      } finally {
        sink.closeSync();
      }
      await index.cacheCommit(cacheKey, tmp.path, total);
      committed = true;
    } finally {
      client.close(force: true);
      // 半途失败（超时/断流/非 2xx）会留下 .tmp-<key>：它是整曲大小，且永远
      // 不会被回收——下一次缓存同 key 时又写一个，缓存目录被撑爆且不计入
      // cacheTotalBytes（那里只数已登记的 .dat），设置页看不出来。
      if (!committed && tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {
          // 删除失败（占用/只读）不该盖掉真正的失败原因
        }
      }
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
      known: (params['known']! as Map<Object?, Object?>)
          .map((k, v) => MapEntry(k as String, v as ScanFingerprint)),
      onProgress: (p) => progress.send(p),
      isCancelled: () => cancelled,
    );
    send.send(out);
  } catch (e) {
    // 隔离内异常以 {'__error__'} 回传主 isolate 转抛：曾无 catch，worker 带
    // uncaught error 死掉后 runScan 干等 10 分钟超时（连接异常即此表现）。
    send.send({'__error__': e.toString()});
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
  required Map<String, ScanFingerprint> known,
  void Function(ScanProgress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final client = _newClient(allowSelfSigned);
  final files = <_WebdavEntry>[];
  final out = <_WebdavWalkOut>[];
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
      // 快速：只建索引。已存在且指纹未变 → 原样回传；否则仅用枚举信息落库，
      // 一个字节的音频内容都不读（PROPFIND 已经给了 ref/size/mtime/etag）。
      final fp = known[f.href];
      final kind = fp == null ? _OutKind.added : _OutKind.updated;
      // 「忽略音频」大小过滤：枚举已带 size，无需读文件。
      if (minSizeBytes > 0 && f.size > 0 && f.size < minSizeBytes) continue;
      out.add(_WebdavWalkOut(
        _rowFor(key, f),
        null,
        fp != null && fp.same(f.size, f.mtime, f.etag)
            ? _OutKind.unchanged
            : kind,
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
  final _OutKind kind;
  const _WebdavWalkOut(this.row, this.cover, this.kind);
}

/// 落库动作分类（增量统计用）。
enum _OutKind { added, updated, unchanged }

/// 快速：只建索引 —— 全部字段只来自枚举信息与文件名，元数据一律留空
/// （时长/曲目/年份/流派/封面全交给播放时补读与后台补读回填）。
DirectSongRow _rowFor(String key, _WebdavEntry f) {
  return DirectSongRow(
    sourceKey: key,
    ref: f.href,
    url: f.fullUrl,
    title: fallbackTitle(f.href),
    titleFromMeta: false,
    artist: null,
    album: null,
    albumArtist: null,
    trackNo: null,
    year: null,
    genre: null,
    duration: null,
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

/// WebDAV 非 2xx 响应：携带状态码，供上层按语义分流（子目录 404 竞态容忍）。
/// toString 面向用户（扫描错误 / 播放 toast 直接展示，无 Exception 前缀）。
class WebdavStatusException implements Exception {
  final int status;
  final String url;
  const WebdavStatusException(this.status, this.url);

  @override
  String toString() {
    switch (status) {
      case 401:
      case 403:
        return 'WebDAV 鉴权失败（HTTP $status）：用户名或密码可能已更改，'
            '请在「源管理」编辑该源重新输入密码';
      case 404:
        return 'WebDAV 路径不存在（HTTP 404）：请检查源地址与服务器目录';
      default:
        return 'WebDAV 请求失败（HTTP $status，$url）';
    }
  }
}

/// 套接字空档时限：两段数据之间超过这么久没有收发就判定连接死了。
/// dart:io 默认也是 15s，这里显式写死——它同时是「大文件中途断流」的兜底，
/// 不依赖 SDK 默认值。
const Duration _kIdleTimeout = Duration(seconds: 15);

/// 单次「小请求」总时限（连接 + 响应头 + 传输），覆盖 [_getHead] 这类
/// 取头部/采样字节的调用。[_kIdleTimeout] 只管数据间的空档，管不住「一直慢吞吞
/// 地传」，也管不住那些并不经过字节流的路径，故再补一道总闸。
const Duration _kRequestDeadline = Duration(seconds: 30);

/// 整曲缓存下载的总时限。缓存是后台预热，失败可重来，绝不能无限期占着连接；
/// 但慢速网络下几十 MB 的歌也要给够余量，故取宽松值。
const Duration _kCacheDownloadDeadline = Duration(minutes: 15);

HttpClient _newClient(bool allowSelfSigned) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..idleTimeout = _kIdleTimeout
  ..userAgent = 'SelfMusic'
  ..badCertificateCallback =
      allowSelfSigned ? (cert, host, port) => true : null;

/// 给 [future] 加总时限，超时抛 [TimeoutException] 并带上可读原因。
/// 注意 Dart 的 `.timeout` 不会真正掐断底层 socket（真正的回收靠调用方
/// `finally` 里的 `client.close(force: true)`），这里只保证「不会无限期挂着」。
Future<T> _withDeadline<T>(Future<T> future, Duration limit, String what) {
  return future.timeout(limit, onTimeout: () {
    throw TimeoutException('$what 超时（${limit.inSeconds}s）');
  });
}

void _auth(HttpClientRequest req, String username, String password) {
  if (username.isEmpty) return;
  final cred = base64Encode(utf8.encode('$username:$password'));
  req.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
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
    try {
      await _listRecursive(client, d, out, username, password,
          isCancelled: isCancelled);
    } on WebdavStatusException catch (e) {
      // 子目录在遍历中途被删（404）属正常竞态，跳过该分支继续；
      // 401/5xx 等其余错误上抛终止整源扫描。
      if (e.status != 404) rethrow;
    }
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
    // 鉴权/路径/服务端错误必须响亮失败：曾静默返回空列表，上层把整库当
    // 「全部消失」清掉（2026-09-29 真机：密码过期 401 → 扫描"成功"0 首 →
    // 清空本地曲库，且 UI 无任何报错）。
    throw WebdavStatusException(resp.statusCode, url);
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
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$', caseSensitive: false)
        .hasMatch(href);