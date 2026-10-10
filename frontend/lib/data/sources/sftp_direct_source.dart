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
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// SFTP 认证方式：密码 / 粘贴的 PEM 私钥文本（含 passphrase 的加密私钥另填）。
enum SftpAuthMethod { password, key }

/// 解析持久化/同步来的认证方式；缺失或非法回落密码（旧配置兼容）。
SftpAuthMethod parseSftpAuthMethod(Object? v) =>
    SftpAuthMethod.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SftpAuthMethod.password,
    );

/// `host:port` 钉键（host 小写；与 `normalizeSftpAddress` 的主机段同口径）。
String sftpHostPort(String host, int port) =>
    '${host.trim().toLowerCase()}:$port';

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

/// 代理 origin（`sftp://host:port/逐段编码路径`，无 userinfo；凭据走信封）。
/// 纯函数，可单测。IPv6 主机自动加方括号。
String sftpOriginUrl({
  required String host,
  required int port,
  required String ref,
}) {
  var h = host.trim();
  if (h.contains(':') && !(h.startsWith('[') && h.endsWith(']'))) {
    h = '[$h]';
  }
  final enc = ref
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
  return 'sftp://$h:$port/$enc';
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
  bool get supportsWrite => false;

  /// 钉键（`host:port`）。
  String get hostPort => sftpHostPort(host, port);

  // ---------- 连接 ----------

  SSHClient? _client;
  SftpClient? _sftp;

  /// 建连（调用方传已钉指纹做校验；`pinnedFp` 为空=未知主机，直接抛错引导
  /// 用户走弹窗测试连接流程，绝不静默信任）。密钥文本非法抛 [SourceAuthException]
  /// （指回密钥/口令）；指纹失配抛 [SshHostKeyMismatch]（带实际指纹）；
  /// 鉴权失败抛 [SourceAuthException]；其余连通性问题抛 [SftpStatusException]。
  static Future<({SSHClient client, SftpClient sftp})> openSftp({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
    required String? pinnedFp,
  }) async {
    if (pinnedFp == null || pinnedFp.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    List<SSHIdentity>? identities;
    if (authMethod == SftpAuthMethod.key) {
      try {
        identities = SSHKeyPair.fromPem(
            keyPem, keyPassphrase.isEmpty ? null : keyPassphrase);
      } catch (e) {
        throw const SourceAuthException('SFTP 密钥无法解析：请检查密钥文本与 passphrase');
      }
    }
    late final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 15));
    } catch (e) {
      throw SftpStatusException(
          _shortErrStatic(e, 'SFTP 连接失败（$host:$port）'));
    }
    String? presented;
    final client = SSHClient(
      socket,
      username: username,
      onVerifyHostKey: (type, fp) async {
        presented = utf8.decode(fp);
        return presented == pinnedFp;
      },
      identities: identities,
      onPasswordRequest:
          authMethod == SftpAuthMethod.password ? () => password : null,
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      // 指纹优先：verifier 拒收后的错误可能被包装变形，一律以实际指纹为准。
      final got = presented;
      if (got != null && got != pinnedFp) throw SshHostKeyMismatch(got);
      if (e is SSHAuthError) {
        throw const SourceAuthException('SFTP 鉴权失败：用户名或密码/密钥可能已更改，'
            '请编辑该源重输');
      }
      throw SftpStatusException(_shortErrStatic(e, 'SFTP 建连失败'));
    }
    try {
      final sftp = await client.sftp();
      return (client: client, sftp: sftp);
    } catch (e) {
      client.close();
      throw SftpStatusException(_shortErrStatic(e, 'SFTP 子系统失败'));
    }
  }

  static String _shortErrStatic(Object e, String what) {
    final s = e.toString().replaceFirst(
        RegExp(r'^(Bad state: |StateError: )'), '');
    return s.length > 160 ? what : '$what：$s';
  }

  /// 仅取主机指纹（测试连接流程用）：接受任意主机密钥，**调用方必须随后向
  /// 用户展示并钉住**，不得用于播放/扫描。鉴权失败抛 [SourceAuthException]，
  /// 其余连通性问题抛 [SftpStatusException]。
  static Future<String> fetchSftpFingerprint({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
  }) async {
    List<SSHIdentity>? identities;
    if (authMethod == SftpAuthMethod.key) {
      try {
        identities = SSHKeyPair.fromPem(
            keyPem, keyPassphrase.isEmpty ? null : keyPassphrase);
      } catch (e) {
        throw const SourceAuthException('SFTP 密钥无法解析：请检查密钥文本与 passphrase');
      }
    }
    late final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 15));
    } catch (e) {
      throw SftpStatusException(
          _shortErrStatic(e, 'SFTP 连接失败（$host:$port）'));
    }
    String? fp;
    final client = SSHClient(
      socket,
      username: username,
      onVerifyHostKey: (type, f) async {
        fp = utf8.decode(f);
        return true;
      },
      identities: identities,
      onPasswordRequest:
          authMethod == SftpAuthMethod.password ? () => password : null,
    );
    try {
      await client.authenticated;
      final got = fp;
      if (got == null || got.isEmpty) throw StateError('未能获取主机指纹');
      return got;
    } on SSHAuthError {
      throw const SourceAuthException('SFTP 鉴权失败：用户名或密码/密钥可能不正确');
    } catch (e) {
      throw SftpStatusException(_shortErrStatic(e, 'SFTP 建连失败'));
    } finally {
      client.close();
    }
  }

  /// 共享连接（懒建连；操作失败疑似掉线时重建一次再试）。
  Future<SftpClient> _sftpClient() async {
    final pinned = index.sshFingerprint(hostPort);
    if (pinned == null || pinned.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    Future<SftpClient> connect() async {
      await close();
      final opened = await openSftp(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        password: password,
        keyPem: keyPem,
        keyPassphrase: keyPassphrase,
        pinnedFp: pinned,
      );
      _client = opened.client;
      _sftp = opened.sftp;
      return opened.sftp;
    }

    final cur = _sftp;
    if (cur != null) return cur;
    try {
      return await connect();
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } catch (e) {
      throw SftpStatusException(_shortErr(e, 'SFTP 连接失败'));
    }
  }

  /// 疑似掉线时重建一次再试（鉴权/指纹类错误直接抛，不重试）。
  Future<T> _withSftp<T>(Future<T> Function(SftpClient sftp) fn) async {
    try {
      return await fn(await _sftpClient());
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } catch (_) {
      await close();
      try {
        return await fn(await _sftpClient());
      } catch (e) {
        if (e is SourceAuthException ||
            e is StateError ||
            e is SshHostKeyMismatch) {
          rethrow;
        }
        throw SftpStatusException(_shortErr(e, 'SFTP 请求失败'));
      }
    }
  }

  static String _shortErr(Object e, String what) {
    final s = e.toString().replaceFirst(
        RegExp(r'^(Bad state: |StateError: )'), '');
    return s.length > 160 ? what : '$what：$s';
  }

  /// SFTP 写操作（v1 未实现，见 §6.10）：统一抛不支持，保持接口完整。
  @override
  Future<void> uploadFile(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      throw UnimplementedError('$key 不支持上传');

  @override
  Future<void> deleteSong(Song song) async =>
      throw UnimplementedError('$key 不支持删除');

  @override
  Future<void> createFolder(String parentRef, String name) async =>
      throw UnimplementedError('$key 不支持新建文件夹');

  @override
  Future<void> close() async {
    try {
      await _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    _sftp = null;
    _client = null;
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
        passphrase:
            authMethod == SftpAuthMethod.key ? keyPassphrase : null,
        fingerprint: fp,
      ),
    };
  }

  /// 预热：小偏移试读——够走完 SSH 握手/鉴权/SFTP，又不下载音频。
  @override
  Future<void> probe(Song song) async {
    await _withSftp((sftp) async {
      final file = await sftp.open(_absPath(song.sourceRef),
          mode: SftpFileOpenMode.read);
      try {
        await file.read(length: 1, offset: 0).first;
      } finally {
        try {
          await file.close();
        } catch (_) {}
      }
    });
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    return _withSftp((sftp) async {
      final file = await sftp.open(_absPath(song.sourceRef),
          mode: SftpFileOpenMode.read);
      int total;
      try {
        total = (await file.stat()).size ?? song.fileSize;
      } catch (_) {
        // stat 失败回退索引大小（可能为 0，即未知）。
        total = song.fileSize;
      }
      final start = range?.start ?? 0;
      final end = range == null
          ? total
          : (range.end == null ? total : (range.end! + 1).clamp(0, total));
      final contentLength = range == null ? total : (end - start);
      final src = file.read(length: contentLength <= 0 ? null : contentLength,
          offset: start);
      // 句柄随流走：结束/出错/取消都关（seek 取消不留服务器句柄）。
      var closed = false;
      Future<void> closeFile() async {
        if (closed) return;
        closed = true;
        try {
          await file.close();
        } catch (_) {}
      }

      late final StreamController<List<int>> controller;
      late StreamSubscription<Uint8List> sub;
      controller = StreamController<List<int>>(
        onListen: () {
          sub = src.listen(
            controller.add,
            onError: (Object e) async {
              controller.addError(e);
              await controller.close();
              await closeFile();
            },
            onDone: () async {
              await controller.close();
              await closeFile();
            },
            cancelOnError: false,
          );
        },
        onCancel: () async {
          await sub.cancel();
          await closeFile();
        },
      );
      return OpenedStream(
        contentLength: contentLength,
        contentType: _mimeOf(_extOf(song.sourceRef)),
        stream: controller.stream,
        totalLength: total > 0 ? total : null,
      );
    });
  }

  // ---------- 离线缓存（DESIGN §6.5，同 WebDAV 口径） ----------

  static const int _cacheWriteBufBytes = 1 << 20;

  String cacheKeyFor(Song song) =>
      md5.convert(utf8.encode('$key|${song.sourceRef}')).toString();

  @override
  Future<String?> cachedFilePath(Song song) async =>
      index.cachedPath(cacheKeyFor(song));

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

/// SFTP 非 2xx 语义外的连接/协议错误：toString 面向用户直接展示。
class SftpStatusException implements Exception {
  final String message;
  const SftpStatusException(this.message);

  @override
  String toString() => message;
}

/// 扫描 isolate 内主机指纹失配：携带实际指纹供主 isolate 转抛展示。
class SshHostKeyMismatch implements Exception {
  final String actual;
  const SshHostKeyMismatch(this.actual);

  @override
  String toString() => 'SSH 主机指纹与已确认的不一致（实际 $actual）：'
      '可能是中间人或服务器重装，请核对后重新确认';
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
    await _listRecursive(sftp, base, '', files,
        isCancelled: isCancelled);
    if (isCancelled?.call() ?? false) return const [];
    onProgress?.call(ScanProgress(listing: false, done: 0, total: files.length));
    final out = <_SftpWalkOut>[];
    var done = 0;
    for (final f in files) {
      done++;
      if (isCancelled?.call() ?? false) break;
      onProgress?.call(
          ScanProgress(listing: false, done: done, total: files.length));
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
        throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
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
  const _SftpEntry({required this.ref, required this.size, required this.mtime});
}

/// 递归枚举（有界并发暂不做：SFTP 单连接串行 readdir 足够快，大目录由进度展示）。
Future<void> _listRecursive(SftpClient sftp, String absDir, String relBase,
    List<_SftpEntry> out,
    {bool Function()? isCancelled}) async {
  late final List<SftpName> names;
  try {
    names = await sftp.listdir(absDir);
  } catch (e) {
    throw StateError(
        SftpDirectSource._shortErrStatic(e, 'SFTP 列目录失败（$absDir）'));
  }
  for (final n in names) {
    if (isCancelled?.call() ?? false) return;
    if (n.filename == '.' || n.filename == '..') continue;
    final rel = relBase.isEmpty ? n.filename : '$relBase/${n.filename}';
    final abs = absDir.endsWith('/')
        ? '$absDir${n.filename}'
        : '$absDir/${n.filename}';
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
