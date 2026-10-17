/// ohos 端 SMB 后端（vendored `smb_connect`，纯 Dart，无原生二进制）。
///
/// - 方言最高 SMB 3.1.1（修复上游协商上下文解析后启用）；SMB3 协商/建连
///   失败（非鉴权原因）时自动回退 SMB 2.1，兼容只支持 SMB2 的旧 NAS。
///   服务器若只允许 SMB3.1.1（`server min protocol = SMB3_11` 的 Samba），
///   旧 2.1 后端会收到 NOT_SUPPORTED——这是鸿蒙/安卓差异的根因，见
///   `third_party/smb_connect/PATCHES.md`；
/// - 用户名与密码双空即匿名（`NtlmPasswordAuthenticator` 默认 ANONYMOUS）；
/// - 读用 `RandomAccessFile`（setPosition + 分块 readInto + close，取消不留
///   服务端句柄；`openRead` 的 async* 流取消后关不掉句柄，不用）；
/// - 错误为 `SmbException`（extends Error，`toString()` 为库内英文文案，
///   如 "Logon failure…"/"Not supported"）：鉴权类 → [SourceAuthException]；
///   BAD_NETWORK_NAME / NOT_FOUND / NO_SUCH_FILE → StateError；方言不支持 →
///   带 SMB3 提示的 [SmbStatusException]；其余 → [SmbStatusException]。
/// - 同一实例的连接按源复用；纯 Dart，扫描 isolate 内同样可用。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/smb_connect.dart'
    show
        SmbConnect,
        SmbFile,
        BaseConfiguration,
        DialectVersion,
        NtlmPasswordAuthenticator,
        SmbAuthException;

import 'music_source.dart';
import 'smb_common.dart';

/// smb_connect 错误文本 → 本工程异常（toString 面向用户）。
///
/// 先按 NTSTATUS 标记判定（库抛的是 `SmbException extends Error`，消息含英文
/// 标记；本工程自造的 StateError 全是中文消息，不会误伤），再透传本工程异常。
const _smbAuthHint =
    '用户名或密码可能不正确，或该共享无访问权限；若账密确认无误，'
    '可能是服务器要求 SMB3 加密（鸿蒙纯 Dart 后端暂不支持），'
    '请改用 WebDAV/SFTP，或仅在服务端放宽 SMB 加密';

Object mapSmbConnectError(Object e, String what) {
  // 库内 Smb2Session 鉴权失败直接抛 SmbAuthException（message 为
  // "Logon failure..." / "Access is denied."）；先按类型判定，避免
  // 依赖英文文案。
  if (e is SmbAuthException) {
    return SourceAuthException('$what：$_smbAuthHint');
  }
  final s = e.toString().toUpperCase();
  if (s.contains('LOGON_FAILURE') ||
      s.contains('LOGON FAILURE') ||
      s.contains('UNKNOWN USER NAME OR BAD PASSWORD') ||
      s.contains('ACCOUNT_RESTRICTION') ||
      s.contains('ACCESS IS DENIED') && s.contains('SESSION')) {
    return SourceAuthException('$what：$_smbAuthHint');
  }
  if (s.contains('BAD_NETWORK_NAME') ||
      s.contains('BAD_NETWORK_PATH') ||
      s.contains('NOT_FOUND') ||
      s.contains('NO_SUCH_FILE') ||
      s.contains('OBJECT_NAME_NOT_FOUND') ||
      s.contains('OBJECT_PATH_NOT_FOUND')) {
    return StateError('$what：文件或目录不存在');
  }
  if (s.contains('NOT_SUPPORTED') ||
      s.contains('NOT SUPPORTED') ||
      s.contains('NOT COMPATIBLE')) {
    // 典型：服务器设了 server min protocol = SMB3_11，而协商列表里
    // 没有可接受的方言（旧版仅到 SMB2.1 时会命中；库内表现为
    // "This client is not compatible with the server."）。
    return SmbStatusException(
        '$what：服务器拒绝了当前 SMB 方言（可能要求 SMB3/3.1.1，或禁用了 SMB2）');
  }
  // 本工程自造异常（全中文消息，走不到上面）原样透传，避免 what 前缀嵌套。
  if (e is SourceAuthException || e is StateError || e is SmbStatusException) {
    return e;
  }
  return SmbStatusException(smbShortErr(e, what));
}

BaseConfiguration _smbConnectConfig(String username, String password,
        {bool smb3 = true}) =>
    BaseConfiguration(
      credentials: NtlmPasswordAuthenticator(
        username: username,
        password: password,
      ),
      username: username,
      password: password,
      domain: '',
      bufferCacheSize: 0x1FFF,
      // 先在方言列表里带上 3.1.1/3.0.x；服务器只支持 2.1 时会自动选 2.1。
      maximumVersion: smb3 ? DialectVersion.SMB311 : DialectVersion.SMB210,
    );

/// 主 isolate 播放/缓存用后端（连接按源复用；失败重建一次再试）。
class SmbConnectBackend {
  final String host;
  final String share;
  final String username;
  final String password;

  SmbConnect? _conn;

  SmbConnectBackend({
    required this.host,
    required this.share,
    required this.username,
    required this.password,
  });

  String get _where => '$host/$share';

  /// `share` 下的完整连接路径（`/` 开头，`getShare` 取首段为 share）。
  String libPath(String remote) => '/$share${remote.isEmpty ? '' : '/$remote'}';

  Future<SmbConnect> _client() async {
    final cur = _conn;
    if (cur != null) return cur;
    try {
      final c = await SmbConnect.connect(
          _smbConnectConfig(username, password), host);
      _conn = c;
      return c;
    } catch (e) {
      final mapped = mapSmbConnectError(e, 'SMB 连接失败（$_where）');
      // 鉴权失败/目录不存在与方言无关，直接抛；网络不可达/超时也不必
      // 重试另一种方言（否则每次请求要等两遍 35s 超时）。其余（例如
      // 3.1.1 协商上下文、签名实现差异）回退只用 2.1 再试一次。服务器
      // 只支持 3.1.1 时回退也会失败，此时保留第一次的错误。
      if (mapped is SourceAuthException ||
          mapped is StateError ||
          e is SocketException ||
          e is TimeoutException) {
        throw mapped;
      }
      try {
        final c = await SmbConnect.connect(
            _smbConnectConfig(username, password, smb3: false), host);
        _conn = c;
        return c;
      } catch (_) {
        throw mapped;
      }
    }
  }

  /// 疑似掉线时重建一次再试（鉴权/不存在类错误直接抛，不重试）。
  Future<T> _withConn<T>(Future<T> Function(SmbConnect c) fn, String what) async {
    try {
      return await fn(await _client());
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } catch (_) {
      await close();
      try {
        return await fn(await _client());
      } catch (e) {
        throw mapSmbConnectError(e, what);
      }
    }
  }

  /// 测试连接：列出 [root]（空=共享根）；弹窗「路径」带子目录时顺带验证
  /// 子目录可达（扫描就依赖它，早失败早提示）。
  Future<void> testConnection([String root = '']) async {
    await _withConn(
        (c) => c.listFiles(_rootFolder(root)), 'SMB 连接测试（$_where）');
  }

  Future<int> fileSize(String remote) => _withConn((c) async {
        final f = await c.file(libPath(remote));
        if (!f.isExists) throw StateError('SMB 文件不存在（$_where/$remote）');
        return f.size;
      }, 'SMB 取文件大小（$_where）');

  /// 分块范围读（`endExclusive` 为开区间；RAF 随流开关，取消不泄漏）。
  Stream<Uint8List> readStream(
      String remote, int start, int endExclusive) async* {
    final c = await _client();
    late final SmbFile f;
    try {
      f = await c.file(libPath(remote));
    } catch (e) {
      throw mapSmbConnectError(e, 'SMB 打开文件（$_where/$remote）');
    }
    if (!f.isExists) throw StateError('SMB 文件不存在（$_where/$remote）');
    final raf = await c.open(f, mode: FileMode.read);
    var closed = false;
    Future<void> closeRaf() async {
      if (closed) return;
      closed = true;
      try {
        await raf.close();
      } catch (_) {}
    }

    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () async {
        try {
          await raf.setPosition(start);
          var off = start;
          final buf = Uint8List(kSmbReadChunkBytes);
          while (off < endExclusive) {
            final want = endExclusive - off;
            final n = await raf.readInto(
                buf, 0, want < buf.length ? want : buf.length);
            if (n <= 0) break;
            off += n;
            controller.add(Uint8List.view(buf.buffer, 0, n));
          }
          await controller.close();
        } catch (e) {
          controller.addError(e);
          await controller.close();
        } finally {
          await closeRaf();
        }
      },
      onCancel: closeRaf,
    );
    yield* controller.stream;
  }

  /// 递归枚举（主 isolate 与扫描 isolate 共用；纯 Dart，可跨 isolate 构造）。
  Future<List<SmbScanEntry>> walk({
    required String root,
    required int minSizeBytes,
    void Function(int done, int total)? onFile,
    bool Function()? isCancelled,
  }) async {
    final c = await _client();
    final files = <SmbFile>[];
    await _listRecursive(c, _rootFolder(root), files, isCancelled);
    if (isCancelled?.call() ?? false) return const [];
    final out = <SmbScanEntry>[];
    var done = 0;
    for (final f in files) {
      done++;
      if (isCancelled?.call() ?? false) break;
      onFile?.call(done, files.length);
      if (minSizeBytes > 0 && f.size > 0 && f.size < minSizeBytes) continue;
      out.add(SmbScanEntry(
        ref: smbRelRef(root, _remoteOf(f)),
        size: f.size,
        mtime: f.lastModified ~/ 1000,
      ));
      if (out.length >= kSmbMaxEntries) {
        throw StateError('单源超过 $kSmbMaxEntries 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
      }
    }
    return out;
  }

  SmbFile _rootFolder([String? rootOverride]) {
    final root = rootOverride ?? '';
    final clean = root
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .join('/');
    // path 供子项拼接（`/`），uncPath 供枚举查询（`\`；共享根为单斜杠）。
    return SmbFile(
      '/$share${clean.isEmpty ? '' : '/$clean'}',
      clean.isEmpty ? r'\' : '\\${clean.replaceAll('/', r'\')}',
      share,
      0,
      0,
      0,
      0,
      0,
      true,
    );
  }

  /// SmbFile.path → 共享相对远端路径（去 `/share` 首段）。
  String _remoteOf(SmbFile f) {
    var p = f.path.replaceAll(r'\', '/');
    final prefix = '/$share/';
    if (p == '/$share' || p == '/$share/') return '';
    if (p.startsWith(prefix)) return p.substring(prefix.length);
    if (p.startsWith('/')) p = p.substring(1);
    final head = p.contains('/') ? p.substring(0, p.indexOf('/')) : p;
    if (head == share) return p.contains('/') ? p.substring(head.length + 1) : '';
    return p;
  }

  Future<void> _listRecursive(SmbConnect c, SmbFile folder, List<SmbFile> out,
      bool Function()? isCancelled) async {
    late final List<SmbFile> entries;
    try {
      entries = await c.listFiles(folder);
    } catch (e) {
      throw mapSmbConnectError(e, 'SMB 列目录失败（${folder.path}）');
    }
    for (final e in entries) {
      if (isCancelled?.call() ?? false) return;
      if (e.isDirectory()) {
        await _listRecursive(c, e, out, isCancelled);
      } else if (e.isExists && isSmbAudioFile(e.name)) {
        out.add(e);
      }
      if (out.length >= kSmbMaxEntries) return;
    }
  }

  // ---------- 写（ohos 纯 Dart；覆盖/幂等口径与 dart_smb2 / WebDAV 对齐） ----------

  /// 分块顺序写（覆盖同名：先删后建；`openWrite` 不截断，短盖长会留尾巴）。
  /// 流式不驻留内存；句柄随 sink.close 释放（Smb2StreamConsumer.close）。
  Future<void> uploadFile(String remote, Stream<List<int>> bytes) async {
    final lib = libPath(remote);
    await _withConn((c) async {
      try {
        final old = await c.file(lib);
        if (old.isExists) await c.delete(old);
      } catch (e) {
        final mapped = mapSmbConnectError(e, 'SMB 删除旧文件（$_where）');
        if (mapped is! StateError) rethrow;
        // 不存在：继续建新文件。
      }
      final created = await c.createFile(lib);
      final sink = await c.openWrite(created);
      try {
        await sink.addStream(bytes.map((chunk) =>
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk)));
      } finally {
        await sink.close();
      }
    }, 'SMB 上传（$_where）');
  }

  /// 删文件（不存在按 WebDAV 404 口径抛错，不静默成功；只读文件中文提示）。
  Future<void> deleteFile(String remote) async {
    final lib = libPath(remote);
    await _withConn((c) async {
      final f = await c.file(lib);
      if (!f.isExists) {
        throw StateError('SMB 删除失败（$_where/$remote）：文件不存在');
      }
      if (!f.canWrite()) {
        throw StateError('SMB 删除失败（$_where/$remote）：文件只读');
      }
      await c.delete(f);
    }, 'SMB 删除（$_where）');
  }

  /// 建目录（库内 createFolder 用 FILE_OPEN_IF，已存在直接成功，天然幂等）。
  Future<void> mkdir(String remote) async {
    final lib = libPath(remote);
    await _withConn((c) => c.createFolder(lib), 'SMB 新建文件夹（$_where）');
  }

  Future<void> close() async {
    final c = _conn;
    _conn = null;
    if (c == null) return;
    try {
      await c.close();
    } catch (_) {}
  }
}
