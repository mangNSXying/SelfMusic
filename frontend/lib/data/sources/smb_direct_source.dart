import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import 'smb_common.dart';
import 'smb_connect_backend.dart';
import 'smb_dart_smb2.dart';

/// SMB 直连源完整实现（阶段 4，DEVELOPER.md「客户端播放源」）。
///
/// - 双后端：非 ohos 走 `dart_smb2`（FFI libsmb2，SMB2/3），ohos 走 vendored
///   `smb_connect`（纯 Dart，最高 SMB 2.1）；由 [useSmbConnect] 选择
///   （`DirectSourceManager` 按 `isOhos` 传入，数据层不直接做平台判断）。
/// - 扫描：在 worker isolate 内直连（`runScan` 驱动，可汇报进度/可取消），
///   枚举只取 ref/size/mtime（协议无 etag），落库逻辑与 WebDAV/SFTP 同口径；
/// - 播放：`directStream()` 恒 null（无原生 URL），`open()` 按 [IntRange]
///   分块读喂自建字节流；连接按源复用、掉线重建一次；
/// - 凭据（密码）只活在内存字段里，持久化收敛到 SecretStore（`smb_pwd:`）；
/// - 用户名与密码双空即匿名；读写全支持（`supportsWrite=true`，上传/删除/
///   建目录走双后端写通路，口径与 WebDAV 对齐：根目录、静默覆盖、同名目录
///   视为成功）。
class SmbDirectSource implements MusicSource {
  @override
  final String name;
  final String host;
  final String share;
  final String username;
  final String password;
  final LocalIndex index;

  /// 共享内根目录（`/` 分隔；空串=共享根）。构造时去首尾斜杠。
  final String rootPath;

  /// true 用 smb_connect 后端（ohos），false 用 dart_smb2（其余平台）。
  final bool useSmbConnect;

  /// 播放链路偏好（新增/编辑源弹窗可配，持久化在源配置 `route` 键；
  /// 代理链路需服务端 SMB 回源，见 §4.6）。
  @override
  final SourceRoute route;

  SmbDirectSource({
    required this.name,
    required this.host,
    required this.share,
    this.username = '',
    this.password = '',
    required this.index,
    String rootPath = '',
    this.useSmbConnect = false,
    this.route = SourceRoute.direct,
  }) : rootPath = rootPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');

  @override
  String get key => 'smb:$name';

  @override
  SourceKind get kind => SourceKind.smb;

  @override
  bool get supportsDirect => true;

  @override
  bool get supportsWrite => true;

  Smb2PoolBackend? _poolBackend;
  SmbConnectBackend? _connBackend;

  Smb2PoolBackend get _pool =>
      _poolBackend ??= Smb2PoolBackend(
        host: host,
        share: share,
        username: username,
        password: password,
      );

  SmbConnectBackend get _conn =>
      _connBackend ??= SmbConnectBackend(
        host: host,
        share: share,
        username: username,
        password: password,
      );

  /// 测试连接（弹窗用；按平台选后端，不保存源）。
  /// 主机/共享为空直接抛；[rootPath] 非空时顺带验证该子目录可达；
  /// 连通性/鉴权错误按播放链路同口径映射。
  static Future<void> testConnection({
    required String host,
    required String share,
    required String username,
    required String password,
    required bool useSmbConnect,
    String rootPath = '',
  }) async {
    if (host.trim().isEmpty) throw StateError('请填写 SMB 主机');
    if (share.trim().isEmpty) throw StateError('请填写共享名');
    final root = smbRemotePath(rootPath, '');
    if (useSmbConnect) {
      final b = SmbConnectBackend(
          host: host.trim(),
          share: share.trim(),
          username: username,
          password: password);
      try {
        await b.testConnection(root);
      } finally {
        await b.close();
      }
      return;
    }
    final b = Smb2PoolBackend(
        host: host.trim(),
        share: share.trim(),
        username: username,
        password: password);
    try {
      await b.testConnection(root);
    } finally {
      await b.close();
    }
  }

  /// SMB 写操作：上传（流式分块，覆盖同名）/ 删文件 / 建目录。
  /// 按 [useSmbConnect] 转发双后端（错误映射各后端自备，与读侧同口径）。
  @override
  Future<void> uploadFile(String parentRef, String filename,
      Stream<List<int>> bytes, int length) async {
    smbGuardWriteParent(parentRef);
    smbGuardWriteName(filename);
    if (!isSmbAudioFile(filename) && !isSidecarFileName(filename)) {
      throw StateError('仅支持上传音频文件（mp3/flac/m4a/aac/ogg/wav/aif[f][c]）与歌词/封面 sidecar（.lrc/.jpg/.png/.webp）');
    }
    final remote = smbRemotePath(rootPath,
        parentRef.isEmpty ? filename : '$parentRef/$filename');
    if (useSmbConnect) {
      await _conn.uploadFile(remote, bytes);
    } else {
      await _pool.uploadChunked(remote, bytes);
    }
  }

  @override
  Future<void> uploadSidecar(String parentRef, String filename,
          Stream<List<int>> bytes, int length) =>
      uploadFile(parentRef, filename, bytes, length);

  @override
  Future<void> deleteSong(Song song) async {
    final remote = smbRemotePath(rootPath, song.sourceRef);
    if (useSmbConnect) {
      await _conn.deleteFile(remote);
    } else {
      await _pool.deleteFile(remote);
    }
  }

  @override
  Future<void> deleteSidecar(String parentRef, String filename) async {
    smbGuardWriteParent(parentRef);
    smbGuardWriteName(filename);
    if (!isSidecarFileName(filename)) {
      throw StateError('仅支持删除歌词/封面 sidecar（.lrc/.jpg/.png/.webp）');
    }
    final remote = smbRemotePath(rootPath,
        parentRef.isEmpty ? filename : '$parentRef/$filename');
    try {
      if (useSmbConnect) {
        await _conn.deleteFile(remote);
      } else {
        await _pool.deleteFile(remote);
      }
    } catch (e) {
      // 不存在按幂等成功计（嵌入后清理时源目录可能本就没有该文件）。
      if (_isNotFoundErr(e)) return;
      rethrow;
    }
  }

  /// 双后端“文件不存在”判定（dart_smb2 `文件或目录不存在` /
  /// smb_connect `文件不存在`）：deleteSidecar 幂等语义用。
  static bool _isNotFoundErr(Object e) =>
      e is StateError && e.message.contains('不存在');

  @override
  Future<void> createFolder(String parentRef, String name) async {    smbGuardWriteParent(parentRef);
    smbGuardWriteName(name);
    final remote = smbRemotePath(rootPath,
        parentRef.isEmpty ? name : '$parentRef/$name');
    if (useSmbConnect) {
      await _conn.mkdir(remote);
    } else {
      await _pool.mkdir(remote);
    }
  }

  @override
  Future<void> close() async {
    await _poolBackend?.close();
    _poolBackend = null;
    await _connBackend?.close();
    _connBackend = null;
  }

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    final known = index.scanFingerprint(key);
    final out = await runScan<List<_SmbWalkOut>>(
      entry: _smbWalkEntry,
      params: <String, Object?>{
        'key': key,
        'host': host,
        'share': share,
        'username': username,
        'password': password,
        'rootPath': rootPath,
        'minSizeBytes': options.minSizeBytes,
        'known': known,
        'useSmbConnect': useSmbConnect,
      },
      token: token,
      onProgress: onProgress,
    );

    // 数据安全闸（与 WebDAV/SFTP 同）：正常完成却为空、而库里有曲时中止防误清库。
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
      toWrite.add(DirectSongRow(
        sourceKey: item.row.sourceKey,
        ref: item.row.ref,
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
        coverPath: item.row.coverPath,
      ));
    }
    await index.upsertSongs(toWrite);
    await index.markMissingExcept(key, alive);
    await index.clearMissing(key);
    return ScanSummary(
        added: added,
        updated: updated,
        unchanged: unchanged,
        total: alive.length);
  }

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  // ---------- 直连播放 ----------

  /// 无原生 URL 可交播放器，恒回 null 走自建字节流（与 SFTP 同）。
  @override
  DirectStream? directStream(Song song) => null;

  /// 代理 origin（`smb://host/share/逐段编码路径`，无 userinfo；凭据走信封）。
  @override
  String? proxyOrigin(Song song) => smbOriginUrl(
      host: host,
      share: share,
      remote: smbRemotePath(rootPath, song.sourceRef));

  /// 代理鉴权头（`X-Origin-Smb` 信封；匿名源用户与密码双空）。
  @override
  Future<Map<String, String>> proxyAuthHeaders(Song song) async => {
        'X-Origin-Smb':
            buildSmbEnvelope(username: username, password: password),
      };

  /// 预热：1 字节范围读——够走完建连/鉴权，又不下载音频。
  @override
  Future<void> probe(Song song) async {
    final remote = smbRemotePath(rootPath, song.sourceRef);
    try {
      await _readStream(remote, 0, 1).first;
    } on StateError catch (e) {
      // 空文件读不到首字节：连通性已确认，不算失败（与读流语义一致）。
      if (!e.toString().contains('No element')) rethrow;
    }
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final remote = smbRemotePath(rootPath, song.sourceRef);
    int total;
    try {
      total = useSmbConnect
          ? await _conn.fileSize(remote)
          : await _pool.fileSize(remote);
    } catch (_) {
      // stat 失败回退索引大小（可能为 0，即未知）；读流失败会如实抛错。
      total = song.fileSize;
    }
    final start = range?.start ?? 0;
    final end = range == null
        ? total
        : (range.end == null ? total : (range.end! + 1).clamp(0, total));
    final contentLength = range == null ? total : (end - start);
    return OpenedStream(
      contentLength: contentLength,
      contentType: smbMimeOf(smbExtOf(song.sourceRef)),
      stream: _readStream(remote, start, end < start ? start : end),
      totalLength: total > 0 ? total : null,
    );
  }

  Stream<Uint8List> _readStream(String remote, int start, int endExclusive) =>
      useSmbConnect
          ? _conn.readStream(remote, start, endExclusive)
          : _pool.readStream(remote, start, endExclusive);

  // ---------- 离线缓存（DEVELOPER.md「客户端同步与缓存批处理」，同 WebDAV/SFTP 口径） ----------

  static const int _cacheWriteBufBytes = 1 << 20;

  String cacheKeyFor(Song song) =>
      md5.convert(utf8.encode('$key|${song.sourceRef}')).toString();

  @override
  Future<String?> cachedFilePath(Song song) async =>
      index.cachedPath(cacheKeyFor(song));

  /// 远端源原生解析仅对已缓存文件可用（R-2）；未缓存走 Dart 切片兜底。
  @override
  Future<String?> localSandboxPath(Song song) => cachedFilePath(song);

  @override
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async {
    final cacheKey = cacheKeyFor(song);
    if (index.isCached(cacheKey)) return;
    final tmp = File(p.join(index.cacheDir, '.tmp-$cacheKey'));
    var committed = false;
    try {
      final req = await open(song);
      final sink = tmp.openSync(mode: FileMode.write);
      var buf = BytesBuilder(copy: false);
      int total = 0;
      try {
        await for (final chunk in req.stream) {
          if (shouldAbort?.call() == true) {
            throw const PreloadAbortedException();
          }
          buf.add(chunk);
          total += chunk.length;
          if (buf.length >= _cacheWriteBufBytes) {
            sink.writeFromSync(buf.takeBytes());
          }
        }
        if (buf.isNotEmpty) sink.writeFromSync(buf.takeBytes());
      } finally {
        sink.closeSync();
      }
      await index.cacheCommit(cacheKey, tmp.path, total);
      committed = true;
    } finally {
      if (!committed && tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  String displayPath(Song song) {
    final parts = <String>[
      '\\\\$host',
      share,
      if (rootPath.isNotEmpty)
        ...rootPath.split('/').where((s) => s.isNotEmpty),
      ...song.sourceRef.split('/').where((s) => s.isNotEmpty),
    ];
    return parts.join('\\');
  }

  // ---------- config ----------

  Map<String, String> get configJ {
    final c = <String, String>{
      'name': name,
      'host': host,
      'share': share,
      'username': username,
      'route': route.name,
    };
    if (rootPath.isNotEmpty) c['path'] = rootPath;
    return c;
  }

  String get configJson => jsonEncode(configJ);
}

// ---------- isolate worker（runScan entry） ----------

void _smbWalkEntry(Map<String, Object?> msg) async {
  final params = msg['params']! as Map<String, Object?>;
  final send = msg['send']! as SendPort;
  final progress = msg['progress']! as SendPort;
  final cancelReq = ReceivePort();
  send.send({'__cancel__': cancelReq.sendPort});
  var cancelled = false;
  cancelReq.listen((_) => cancelled = true);
  try {
    final host = params['host']! as String;
    final share = params['share']! as String;
    final username = params['username']! as String;
    final password = params['password']! as String;
    final rootPath = params['rootPath']! as String;
    final minSizeBytes = params['minSizeBytes']! as int;
    final known = (params['known']! as Map<Object?, Object?>)
        .map((k, v) => MapEntry(k as String, v as ScanFingerprint));
    final useSmbConnect = params['useSmbConnect']! as bool;
    final key = params['key']! as String;

    progress.send(const ScanProgress(listing: true, done: 0, total: 0));
    final List<SmbScanEntry> entries;
    if (useSmbConnect) {
      final b = SmbConnectBackend(
          host: host, share: share, username: username, password: password);
      try {
        entries = await b.walk(
          root: rootPath,
          minSizeBytes: minSizeBytes,
          onFile: (done, total) => progress.send(
              ScanProgress(listing: false, done: done, total: total)),
          isCancelled: () => cancelled,
        );
      } finally {
        await b.close();
      }
    } else {
      entries = await smb2Walk(
        host: host,
        share: share,
        username: username,
        password: password,
        root: rootPath
            .split('/')
            .where((s) => s.isNotEmpty)
            .join('/'),
        minSizeBytes: minSizeBytes,
        onFile: (done, total) => progress.send(
            ScanProgress(listing: false, done: done, total: total)),
        isCancelled: () => cancelled,
      );
    }
    final out = <_SmbWalkOut>[];
    for (final f in entries) {
      final ref = f.ref;
      final fp = known[ref];
      final kind = fp == null ? _OutKind.added : _OutKind.updated;
      out.add(_SmbWalkOut(
        DirectSongRow(
          sourceKey: key,
          ref: ref,
          title: fallbackTitle(ref),
          titleFromMeta: false,
          format: smbExtOf(ref),
          size: f.size,
          mtime: f.mtime,
        ),
        fp != null && fp.same(f.size, f.mtime, null)
            ? _OutKind.unchanged
            : kind,
      ));
      if (out.length >= kSmbMaxEntries) {
        throw StateError('单源超过 $kSmbMaxEntries 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
      }
    }
    send.send(out);
  } catch (e) {
    send.send({'__error__': e.toString()});
  } finally {
    cancelReq.close();
  }
}

class _SmbWalkOut {
  final DirectSongRow row;
  final _OutKind kind;
  const _SmbWalkOut(this.row, this.kind);
}

enum _OutKind { added, updated, unchanged }
