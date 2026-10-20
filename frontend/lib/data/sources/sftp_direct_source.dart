import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../../models/song.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import 'sftp_common.dart';
import 'sftp_direct_transport.dart';
import 'sftp_worker.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

// 兼容既有 import：认证方式、纯函数与异常仍从本文件导出。
export 'sftp_common.dart'
    show
        SftpAuthMethod,
        parseSftpAuthMethod,
        sftpHostPort,
        sftpOriginUrl,
        sftpGuardWriteName,
        sftpGuardWriteParent,
        SftpStatusException,
        SshHostKeyMismatch;

/// X-Origin-Ssh 信封体（base64url(JSON)：`{u, p?, k?, pp?, hk}`），供服务端
/// 代理回源鉴权（内存态单次使用，见 §4.6）。纯函数，可单测。
String buildSshEnvelope({
  required String username,
  String? password,
  String? keyPem,
  String? passphrase,
  required String fingerprint,
}) {
  final m = <String, String>{'u': username, 'hk': fingerprint};
  if (password != null && password.isNotEmpty) m['p'] = password;
  if (keyPem != null && keyPem.isNotEmpty) {
    m['k'] = keyPem;
    if (passphrase != null && passphrase.isNotEmpty) m['pp'] = passphrase;
  }
  return base64Url.encode(utf8.encode(jsonEncode(m)));
}

/// SFTP 直连源完整实现（阶段 7，`dartssh2` 纯 Dart）。
///
/// - 扫描：在 worker isolate 内直连（`runScan` 驱动，可汇报进度/可取消），
///   枚举只取 ref/size/mtime（协议无 etag），落库逻辑与 WebDAV/本地同口径；
/// - 播放：`directStream()` 恒 null（just_audio 播不了 `sftp://`），`open()`
///   按 [IntRange] 偏移读喂自建字节流；连接按源复用、掉线重建一次；
/// - 凭据（密码/私钥/passphrase）只活在内存字段里，持久化收敛到 SecretStore；
/// - 主机指纹走 `ssh_known_hosts` TOFU 钉（[LocalIndex]），未知/失配直接抛错，
///   由弹窗测试连接流程处理（扫描 isolate 内同样校验）。
class SftpDirectSource implements MusicSource {
  @override
  final String name;
  final String host;
  final int port;
  final String username;
  final SftpAuthMethod authMethod;
  final String password;
  final String keyPem;
  final String keyPassphrase;
  final LocalIndex index;

  /// 远端根目录（绝对或家目录相对；空串=登录目录）。构造时去尾斜杠。
  final String rootPath;

  /// 播放链路偏好（新增/编辑源弹窗可配，持久化在源配置 `route` 键）。
  @override
  final SourceRoute route;

  SftpDirectSource({
    required this.name,
    required this.host,
    this.port = 22,
    this.username = '',
    this.authMethod = SftpAuthMethod.password,
    this.password = '',
    this.keyPem = '',
    this.keyPassphrase = '',
    required this.index,
    String rootPath = '',
    this.route = SourceRoute.direct,
  }) : rootPath = rootPath.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  String get key => 'sftp:$name';

  @override
  SourceKind get kind => SourceKind.sftp;

  @override
  bool get supportsDirect => true;

  @override
  bool get supportsWrite => true;

  /// 钉键（`host:port`）。
  String get hostPort => sftpHostPort(host, port);

  // ---------- 连接 ----------

  /// 传输层（worker 或旧直连）。懒创建，`close()` 后下次操作重新建。
  SftpTransport? _transport;

  /// 建连（扫描 isolate / 直连兜底用）。主播放链路请走 [_transportFor]，
  /// 优选 worker isolate，避免 KEX/AEAD 解密占用 UI isolate。
  static Future<OpenedSftpConnection> openSftp({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
    required String? pinnedFp,
  }) =>
      SftpConnection.open(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        password: password,
        keyPem: keyPem,
        keyPassphrase: keyPassphrase,
        pinnedFp: pinnedFp,
      );

  /// 仅取主机指纹（测试连接流程用）。走一次性 isolate，避免 SSH 密码学
  /// 计算占住 UI isolate；实现在 [SftpConnection.fetchFingerprintInIsolate]。
  static Future<String> fetchSftpFingerprint({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
  }) =>
      SftpConnection.fetchFingerprintInIsolate(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        password: password,
        keyPem: keyPem,
        keyPassphrase: keyPassphrase,
      );

  /// 懒创建传输层。worker 路径在 Android/桌面/iOS 默认启用；OHOS 真机 PoC
  /// 已过、待 soak 后翻默认，之前默认走旧直连（`SftpWorker.enabled == false`）。
  /// 编译期强制回退：`--dart-define=SFTP_WORKER_DIRECT=true`（全平台走旧直连）。
  SftpTransport _transportFor() {
    final cur = _transport;
    if (cur != null) return cur;
    final pinned = index.sshFingerprint(hostPort);
    if (pinned == null || pinned.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    final next = SftpWorker.enabled
        ? SftpIsolateTransport(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            password: password,
            keyPem: keyPem,
            keyPassphrase: keyPassphrase,
            pinnedFp: pinned,
          )
        : SftpDirectTransport(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            password: password,
            keyPem: keyPem,
            keyPassphrase: keyPassphrase,
            pinnedFp: pinned,
          );
    _transport = next;
    SftpWorker.trace(
        'transport=${next is SftpIsolateTransport ? 'worker' : 'direct'} '
        '$host:$port');
    return next;
  }

  /// SFTP 写操作：上传（流式分块，覆盖同名）/ 删文件 / 建目录。
  /// 无权限类错误转中文 StateError（鉴权已过，这是文件系统权限问题），
  /// 其余沿用读侧映射。
  @override
  Future<void> uploadFile(String parentRef, String filename,
      Stream<List<int>> bytes, int length) async {
    sftpGuardWriteParent(parentRef);
    sftpGuardWriteName(filename);
    if (!_audioExt(filename) && !isSidecarFileName(filename)) {
      throw StateError(
          '仅支持上传音频文件（mp3/flac/m4a/aac/ogg/wav/aif[f][c]）与歌词/封面 sidecar（.lrc/.jpg/.png/.webp）');
    }
    final abs = _absPath(parentRef.isEmpty ? filename : '$parentRef/$filename');
    try {
      await _transportFor().upload(abs, bytes, length);
    } on SftpStatusException catch (e) {
      if (e.code == SftpStatusCode.permissionDenied) {
        throw StateError('上传失败：无写入权限（$abs）');
      }
      rethrow;
    }
  }

  @override
  Future<void> uploadSidecar(String parentRef, String filename,
          Stream<List<int>> bytes, int length) =>
      uploadFile(parentRef, filename, bytes, length);

  @override
  Future<void> deleteSong(Song song) async {
    final abs = _absPath(song.sourceRef);
    try {
      await _transportFor().remove(abs);
    } on SftpStatusException catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        throw StateError('删除失败：文件不存在（可能已被删除）');
      }
      if (e.code == SftpStatusCode.permissionDenied) {
        throw StateError('删除失败：无删除权限');
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteSidecar(String parentRef, String filename) async {
    sftpGuardWriteParent(parentRef);
    sftpGuardWriteName(filename);
    if (!isSidecarFileName(filename)) {
      throw StateError('仅支持删除歌词/封面 sidecar（.lrc/.jpg/.png/.webp）');
    }
    final abs = _absPath(parentRef.isEmpty ? filename : '$parentRef/$filename');
    try {
      await _transportFor().remove(abs);
    } on SftpStatusException catch (e) {
      // 不存在按幂等成功计（嵌入后清理时源目录可能本就没有该文件）。
      if (e.code == SftpStatusCode.noSuchFile) return;
      if (e.code == SftpStatusCode.permissionDenied) {
        throw StateError('删除 sidecar 失败：无删除权限');
      }
      rethrow;
    }
  }

  @override
  Future<void> createFolder(String parentRef, String name) async {
    sftpGuardWriteParent(parentRef);
    sftpGuardWriteName(name);
    final abs = _absPath(parentRef.isEmpty ? name : '$parentRef/$name');
    final transport = _transportFor();
    try {
      await transport.mkdir(abs);
    } on SftpStatusException catch (e) {
      // 已存在即成功（与 WebDAV 405/409 口径一致）：stat 确认是目录才认，
      // 同名文件不认（避免把"建目录撞上文件"误判为成功）。
      if (e.code == SftpStatusCode.failure) {
        try {
          if (await transport.isDirectory(abs)) return;
        } catch (_) {}
        throw StateError('新建文件夹失败：同名文件已存在');
      }
      if (e.code == SftpStatusCode.permissionDenied) {
        throw StateError('新建文件夹失败：无写入权限');
      }
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final transport = _transport;
    _transport = null;
    try {
      await transport?.close();
    } catch (_) {}
  }

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    final pinned = index.sshFingerprint(hostPort);
    if (pinned == null || pinned.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    final known = index.scanFingerprint(key);
    final out = await runScan<List<_SftpWalkOut>>(
      entry: _sftpWalkEntry,
      params: <String, Object?>{
        'key': key,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'password': password,
        'keyPem': keyPem,
        'keyPassphrase': keyPassphrase,
        'pinnedFp': pinned,
        'rootPath': rootPath,
        'minSizeBytes': options.minSizeBytes,
        'known': known,
      },
      token: token,
      onProgress: onProgress,
    );

    // 数据安全闸（与 WebDAV 同）：正常完成却为空、而库里有曲时中止防误清库。
    if (out.isEmpty && known.isNotEmpty && !(token?.cancelled ?? false)) {
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

  /// just_audio 播不了 `sftp://`，恒回 null 走自建字节流。
  @override
  DirectStream? directStream(Song song) => null;

  /// 代理 origin（`sftp://host:port/逐段编码路径`，无 userinfo；凭据走信封）。
  @override
  String? proxyOrigin(Song song) =>
      sftpOriginUrl(host: host, port: port, ref: song.sourceRef);

  /// 代理鉴权头（`X-Origin-Ssh` 信封；指纹缺失即抛错引导先确认）。
  @override
  Future<Map<String, String>> proxyAuthHeaders(Song song) async {
    final fp = index.sshFingerprint(hostPort);
    if (fp == null || fp.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    return {
      'X-Origin-Ssh': buildSshEnvelope(
        username: username,
        password: authMethod == SftpAuthMethod.password ? password : null,
        keyPem: authMethod == SftpAuthMethod.key ? keyPem : null,
        passphrase: authMethod == SftpAuthMethod.key ? keyPassphrase : null,
        fingerprint: fp,
      ),
    };
  }

  /// 预热：小偏移试读——够走完 SSH 握手/鉴权/SFTP，又不下载音频。
  @override
  Future<void> probe(Song song) async {
    await _transportFor().probe(_absPath(song.sourceRef));
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final res = await _transportFor().open(
      _absPath(song.sourceRef),
      start: range?.start,
      length: range?.length,
      fallbackTotal: song.fileSize,
    );
    return OpenedStream(
      contentLength: res.contentLength,
      contentType: _mimeOf(_extOf(song.sourceRef)),
      stream: res.stream,
      totalLength: res.totalLength,
    );
  }

  // ---------- 离线缓存（DEVELOPER.md「客户端同步与缓存批处理」，同 WebDAV 口径） ----------

  static const int _cacheWriteBufBytes = 1 << 20;

  /// 缓存下载的让出节拍（仅旧直连路径）：每个 16KB 解密块后歇 6ms，避免整曲
  /// 缓存长时间占满 UI isolate。worker 路径解密不在 UI isolate，无需节拍。
  static const Duration _cachePaceSleep = Duration(milliseconds: 6);

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
          // 仅旧直连：与元数据补读同一让出纪律（见直连传输的 maxPendingRequests
          // 注释）——整曲缓存持续跑纯 Dart 解密，若不歇息会长时间占满 UI
          // isolate 导致掉帧；缓存是后台行为，慢一点换取界面可响应。
          if (!SftpWorker.enabled) {
            await Future<void>.delayed(_cachePaceSleep);
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
    final user = username.isEmpty ? '' : '$username@';
    final portPart = port == 22 ? '' : ':$port';
    final full = _absPath(song.sourceRef);
    return 'sftp://$user$host$portPart$full';
  }

  // ---------- 路径 ----------

  /// 源内相对引用 → 远端绝对路径（过滤 `..` 防越界）。
  String _absPath(String ref) {
    final parts = ref
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    final rel = parts.join('/');
    if (rootPath.isEmpty) return '/$rel';
    if (rootPath.startsWith('/')) return '$rootPath/$rel';
    return '$rootPath/$rel';
  }

  // ---------- config ----------

  Map<String, String> get configJ => {
        'name': name,
        'host': host,
        'port': port.toString(),
        'username': username,
        'authMethod': authMethod.name,
        'path': rootPath,
      };

  String get configJson => jsonEncode(configJ);
}

// ---------- isolate worker（runScan entry） ----------

void _sftpWalkEntry(Map<String, Object?> msg) async {
  final params = msg['params']! as Map<String, Object?>;
  final send = msg['send']! as SendPort;
  final progress = msg['progress']! as SendPort;
  final cancelReq = ReceivePort();
  send.send({'__cancel__': cancelReq.sendPort});
  var cancelled = false;
  cancelReq.listen((_) => cancelled = true);
  try {
    final out = await _sftpWalk(
      key: params['key']! as String,
      host: params['host']! as String,
      port: params['port']! as int,
      username: params['username']! as String,
      authMethod: parseSftpAuthMethod(params['authMethod']),
      password: params['password']! as String,
      keyPem: params['keyPem']! as String,
      keyPassphrase: params['keyPassphrase']! as String,
      pinnedFp: params['pinnedFp']! as String,
      rootPath: params['rootPath']! as String,
      minSizeBytes: params['minSizeBytes']! as int,
      known: (params['known']! as Map<Object?, Object?>)
          .map((k, v) => MapEntry(k as String, v as ScanFingerprint)),
      onProgress: (q) => progress.send(q),
      isCancelled: () => cancelled,
    );
    send.send(out);
  } catch (e) {
    send.send({'__error__': e.toString()});
  } finally {
    cancelReq.close();
  }
}

class _SftpWalkOut {
  final DirectSongRow row;
  final _OutKind kind;
  const _SftpWalkOut(this.row, this.kind);
}

enum _OutKind { added, updated, unchanged }

/// 进入 worker isolate：递归 readdir + 指纹 diff，返回可落库行。
Future<List<_SftpWalkOut>> _sftpWalk({
  required String key,
  required String host,
  required int port,
  required String username,
  required SftpAuthMethod authMethod,
  required String password,
  required String keyPem,
  required String keyPassphrase,
  required String pinnedFp,
  required String rootPath,
  required int minSizeBytes,
  required Map<String, ScanFingerprint> known,
  void Function(ScanProgress)? onProgress,
  bool Function()? isCancelled,
}) async {
  onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
  final opened = await SftpDirectSource.openSftp(
    host: host,
    port: port,
    username: username,
    authMethod: authMethod,
    password: password,
    keyPem: keyPem,
    keyPassphrase: keyPassphrase,
    pinnedFp: pinnedFp,
  );
  final client = opened.client;
  final sftp = opened.sftp;
  try {
    final base = rootPath.isEmpty ? '/' : rootPath;
    final files = <_SftpEntry>[];
    await _listRecursive(sftp, base, '', files, isCancelled: isCancelled);
    if (isCancelled?.call() ?? false) return const [];
    onProgress
        ?.call(ScanProgress(listing: false, done: 0, total: files.length));
    final out = <_SftpWalkOut>[];
    var done = 0;
    for (final f in files) {
      done++;
      if (isCancelled?.call() ?? false) break;
      onProgress
          ?.call(ScanProgress(listing: false, done: done, total: files.length));
      if (minSizeBytes > 0 && f.size > 0 && f.size < minSizeBytes) continue;
      final fp = known[f.ref];
      final kind = fp == null ? _OutKind.added : _OutKind.updated;
      out.add(_SftpWalkOut(
        DirectSongRow(
          sourceKey: key,
          ref: f.ref,
          title: fallbackTitle(f.ref),
          titleFromMeta: false,
          format: _extOf(f.ref),
          size: f.size,
          mtime: f.mtime,
        ),
        fp != null && fp.same(f.size, f.mtime, null)
            ? _OutKind.unchanged
            : kind,
      ));
      if (out.length >= 20000) {
        throw StateError('单源超过 20000 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
      }
    }
    return out;
  } finally {
    try {
      await sftp.close();
    } catch (_) {}
    client.close();
  }
}

class _SftpEntry {
  final String ref;
  final int size;
  final int mtime;
  const _SftpEntry(
      {required this.ref, required this.size, required this.mtime});
}

/// 递归枚举（有界并发暂不做：SFTP 单连接串行 readdir 足够快，大目录由进度展示）。
Future<void> _listRecursive(
    SftpClient sftp, String absDir, String relBase, List<_SftpEntry> out,
    {bool Function()? isCancelled}) async {
  late final List<SftpName> names;
  try {
    names = await sftp.listdir(absDir);
  } catch (e) {
    throw StateError(shortSftpError(e, 'SFTP 列目录失败（$absDir）'));
  }
  for (final n in names) {
    if (isCancelled?.call() ?? false) return;
    if (n.filename == '.' || n.filename == '..') continue;
    final rel = relBase.isEmpty ? n.filename : '$relBase/${n.filename}';
    final abs =
        absDir.endsWith('/') ? '$absDir${n.filename}' : '$absDir/${n.filename}';
    final isDir = n.attr.mode?.type == SftpFileType.directory;
    if (isDir) {
      await _listRecursive(sftp, abs, rel, out, isCancelled: isCancelled);
    } else if (_audioExt(n.filename)) {
      out.add(_SftpEntry(
        ref: rel,
        size: n.attr.size ?? 0,
        mtime: n.attr.modifyTime ?? 0,
      ));
    }
    if (out.length >= 20000) return;
  }
}

bool _audioExt(String path) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$', caseSensitive: false)
        .hasMatch(path);

String _extOf(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 ? path.substring(i + 1).toLowerCase() : '';
}

String _mimeOf(String ext) {
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
