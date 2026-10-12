/// 非 ohos 平台的 SMB 后端（`dart_smb2`，FFI libsmb2，SMB 2.0.2→3.1.1）。
///
/// - 主 isolate 只用 [Smb2PoolBackend]（异步 worker 池：连接复用、断线自动重连；
///   同步 [Smb2Client] 绝不在主 isolate 调用，会阻塞 UI）；
/// - 扫描 isolate 用 [smb2Walk]（同步 FFI 在自有 isolate 内，包推荐用法）。
/// - 用户名/密码为空即匿名（传 null，不做 guest 特殊处理，libsmb2 按空凭据协商）。
/// - 鉴权类错误（auth/accessDenied）转 [SourceAuthException]（装载链路快速失败，
///   见 [MusicSource] 约定）；其余转 [SmbStatusException]。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';

import 'music_source.dart';
import 'smb_common.dart';

/// 是否为鉴权类错误（重试无意义，装载链路应直接展示）。
bool _isAuthError(Smb2Exception e) =>
    e.type == Smb2ErrorType.auth || e.type == Smb2ErrorType.accessDenied;

/// dart_smb2 错误 → 本工程异常（toString 面向用户，无 `Smb2Exception` 前缀）。
Object _mapSmb2Error(Object e, String what) {
  if (e is Smb2Exception) {
    if (_isAuthError(e)) {
      return SourceAuthException('$what：用户名或密码可能不正确，或该共享无访问权限');
    }
    if (e.type == Smb2ErrorType.fileNotFound) {
      return StateError('$what：文件或目录不存在');
    }
    return SmbStatusException(smbShortErr(e, what));
  }
  return e;
}

/// 主 isolate 播放/缓存用后端（连接按源复用；失败重建一次再试）。
class Smb2PoolBackend {
  final String host;
  final String share;
  final String username;
  final String password;

  Smb2Pool? _pool;

  Smb2PoolBackend({
    required this.host,
    required this.share,
    required this.username,
    required this.password,
  });

  String get _where => '$host/$share';

  Future<Smb2Pool> _poolClient() async {
    final cur = _pool;
    if (cur != null) return cur;
    try {
      final p = await Smb2Pool.connect(
        host: host,
        share: share,
        user: username.isEmpty ? null : username,
        password: password.isEmpty ? null : password,
        workers: 2,
        timeoutSeconds: 30,
      );
      _pool = p;
      return p;
    } catch (e) {
      throw _mapSmb2Error(e, 'SMB 连接失败（$_where）');
    }
  }

  /// 疑似掉线时重建一次再试（鉴权/不存在类错误直接抛，不重试）。
  Future<T> _withPool<T>(Future<T> Function(Smb2Pool p) fn, String what) async {
    try {
      return await fn(await _poolClient());
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } catch (_) {
      await close();
      try {
        return await fn(await _poolClient());
      } catch (e) {
        throw _mapSmb2Error(e, what);
      }
    }
  }

  Future<void> testConnection() async {
    await _withPool((p) => p.listDirectory(''), 'SMB 连接测试（$_where）');
  }

  Future<int> fileSize(String remote) => _withPool(
        (p) => p.fileSize(remote),
        'SMB 取文件大小（$_where）',
      );

  /// 分块范围读（`endExclusive` 为开区间；stateless，取消即停、无句柄泄漏）。
  Stream<Uint8List> readStream(
      String remote, int start, int endExclusive) async* {
    var off = start;
    while (off < endExclusive) {
      final want = endExclusive - off;
      final len = want < kSmbReadChunkBytes ? want : kSmbReadChunkBytes;
      final chunk = await _withPool(
        (p) => p.readFileRange(remote, offset: off, length: len),
        'SMB 读取（$_where）',
      );
      if (chunk.isEmpty) break;
      off += chunk.length;
      yield chunk;
    }
  }

  Future<void> close() async {
    final p = _pool;
    _pool = null;
    if (p == null) return;
    try {
      await p.disconnect();
    } catch (_) {}
  }
}

/// 扫描 isolate 内递归枚举（同步 FFI；调用方传已洗好的连接参数）。
/// 返回共享相对路径的原始条目（调用方再按 `rootPath` 折成 `ref`）。
Future<List<SmbScanEntry>> smb2Walk({
  required String host,
  required String share,
  required String username,
  required String password,
  required String root,
  required int minSizeBytes,
  void Function(int done, int total)? onFile,
  bool Function()? isCancelled,
}) async {
  final client = Smb2Client.open();
  try {
    client.connect(
      host: host,
      share: share,
      user: username.isEmpty ? null : username,
      password: password.isEmpty ? null : password,
      timeoutSeconds: 30,
    );
  } catch (e) {
    throw _mapSmb2Error(e, 'SMB 连接失败（$host/$share）');
  }
  try {
    final files = <_RawFile>[];
    _listRecursive(client, root, files, isCancelled);
    if (isCancelled?.call() ?? false) return const [];
    final out = <SmbScanEntry>[];
    var done = 0;
    for (final f in files) {
      done++;
      if (isCancelled?.call() ?? false) break;
      onFile?.call(done, files.length);
      if (minSizeBytes > 0 && f.size > 0 && f.size < minSizeBytes) continue;
      out.add(SmbScanEntry(
        ref: f.remote,
        size: f.size,
        mtime: f.mtime,
      ));
      if (out.length >= kSmbMaxEntries) {
        throw StateError('单源超过 $kSmbMaxEntries 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
      }
    }
    return out;
  } finally {
    try {
      client.disconnect();
    } catch (_) {}
  }
}

class _RawFile {
  final String remote;
  final int size;
  final int mtime;
  const _RawFile({required this.remote, required this.size, required this.mtime});
}

void _listRecursive(Smb2Client client, String dirRemote, List<_RawFile> out,
    bool Function()? isCancelled) {
  late final List<Smb2DirEntry> entries;
  try {
    entries = client.listDirectory(dirRemote);
  } catch (e) {
    throw _mapSmb2Error(e, 'SMB 列目录失败（$dirRemote）');
  }
  for (final e in entries) {
    if (isCancelled?.call() ?? false) return;
    if (e.name == '.' || e.name == '..') continue;
    final remote = dirRemote.isEmpty ? e.name : '$dirRemote/${e.name}';
    if (e.isDirectory) {
      _listRecursive(client, remote, out, isCancelled);
    } else if (e.isFile && isSmbAudioFile(e.name)) {
      out.add(_RawFile(
        remote: remote,
        size: e.size,
        mtime: e.stat.modified.millisecondsSinceEpoch ~/ 1000,
      ));
    }
    if (out.length >= kSmbMaxEntries) return;
  }
}
