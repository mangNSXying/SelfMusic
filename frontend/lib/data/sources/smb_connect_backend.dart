/// ohos 端 SMB 后端（vendored `smb_connect`，纯 Dart，无原生二进制）。
///
/// - 方言最高 SMB 2.1（无 SMB3；NAS 需允许 SMB2 协商，见
///   `third_party/smb_connect/PATCHES.md`）；
/// - 用户名与密码双空即匿名（`NtlmPasswordAuthenticator` 默认 ANONYMOUS）；
/// - 读用 `RandomAccessFile`（setPosition + 分块 readInto + close，取消不留
///   服务端句柄；`openRead` 的 async* 流取消后关不掉句柄，不用）；
/// - 错误为 `SmbException`（extends Error，消息含 NTSTATUS）：含 LOGON_FAILURE /
///   ACCESS_DENIED → [SourceAuthException]；含 BAD_NETWORK_NAME / NOT_FOUND /
///   NO_SUCH_FILE → StateError；其余 → [SmbStatusException]。
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
        NtlmPasswordAuthenticator;

import 'music_source.dart';
import 'smb_common.dart';

/// smb_connect 错误文本 → 本工程异常（toString 面向用户）。
///
/// 先按 NTSTATUS 标记判定（库抛的是 `SmbException extends Error`，消息含英文
/// 标记；本工程自造的 StateError 全是中文消息，不会误伤），再透传本工程异常。
Object mapSmbConnectError(Object e, String what) {
  final s = e.toString().toUpperCase();
  if (s.contains('LOGON_FAILURE') ||
      s.contains('ACCOUNT_RESTRICTION') ||
      s.contains('ACCESS_DENIED') && s.contains('SESSION')) {
    return SourceAuthException('$what：用户名或密码可能不正确，或该共享无访问权限');
  }
  if (s.contains('BAD_NETWORK_NAME') ||
      s.contains('BAD_NETWORK_PATH') ||
      s.contains('NOT_FOUND') ||
      s.contains('NO_SUCH_FILE') ||
      s.contains('OBJECT_NAME_NOT_FOUND') ||
      s.contains('OBJECT_PATH_NOT_FOUND')) {
    return StateError('$what：文件或目录不存在');
  }
  // 本工程自造异常（全中文消息，走不到上面）原样透传，避免 what 前缀嵌套。
  if (e is SourceAuthException || e is StateError || e is SmbStatusException) {
    return e;
  }
  return SmbStatusException(smbShortErr(e, what));
}

BaseConfiguration _smbConnectConfig(String username, String password) =>
    BaseConfiguration(
      credentials: NtlmPasswordAuthenticator(
        username: username,
        password: password,
      ),
      username: username,
      password: password,
      domain: '',
      bufferCacheSize: 0x1FFF,
      maximumVersion: DialectVersion.SMB210,
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
      throw mapSmbConnectError(e, 'SMB 连接失败（$_where）');
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

  Future<void> testConnection() async {
    await _withConn((c) => c.listFiles(_rootFolder()), 'SMB 连接测试（$_where）');
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

  Future<void> close() async {
    final c = _conn;
    _conn = null;
    if (c == null) return;
    try {
      await c.close();
    } catch (_) {}
  }
}
