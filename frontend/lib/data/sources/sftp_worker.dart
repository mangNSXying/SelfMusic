import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'music_source.dart';
import 'sftp_common.dart';

/// 读批大小：主 isolate 一次最多拉这么多已解密字节。256KB 约等于 320kbps
/// 音频 6 秒，起播/seek 的首批延迟足够小；同时把跨 isolate 缓冲上限钉死。
const int _kReadBatchBytes = 256 * 1024;

/// worker 内部 SFTP 读的块大小与在飞请求数。解密在 worker isolate，不再受
/// UI 帧率约束，可以放开并发换吞吐；单个 worker 仍只服务一个源，避免抢带宽。
const int _kReadChunkBytes = 64 * 1024;
const int _kReadMaxPending = 4;

/// 上传批大小：主 isolate 攒够再跨 isolate 发，减少消息往返；worker 内
/// `writeBytes` 再按 64KB 扇出。
const int _kUploadBatchBytes = 256 * 1024;
const int _kUploadChunkBytes = 64 * 1024;
const int _kUploadMaxPending = 4;

/// 长活 SFTP worker 的主 isolate 代理。
///
/// 每个 [SftpDirectSource] 持有至多一个 worker；SSH 握手、SFTP 请求、AES-GCM
/// 解密、主机指纹校验全部在 worker isolate 内完成，主 isolate 只收发明文块。
/// 这样即使 `dartssh2` 解密占满一个 isolate，UI 仍有自己的事件循环。
///
/// 平台开关：Android/桌面/iOS 默认启用；OHOS 因 fork engine 的 isolate 行为
/// 尚未真机 PoC，默认走旧直连（见 [enabled]），验证通过后用
/// `--dart-define=SFTP_WORKER_ISOLATE=true` 打开。
class SftpWorker {
  SftpWorker._(this._cmd, this._reply, this._isolate) {
    _reply.listen(
      _onMessage,
      onError: (Object e) => _failAll(StateError('SFTP worker 通信失败：$e')),
    );
    _isolate.addOnExitListener(
      _reply.sendPort,
      response: <String, Object?>{'t': 'exit'},
    );
  }

  final SendPort _cmd;
  final ReceivePort _reply;
  final Isolate _isolate;

  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final Map<int, _ReadState> _reads = {};
  int _seq = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  /// 有打开的读流或未完成的命令。空闲回收只看这个，不靠定时器猜播放状态：
  /// 暂停的播放仍保留读流，不会在暂停期间被误关。
  bool get busy => _reads.isNotEmpty || _pending.isNotEmpty;

  /// 是否启用 worker 路径。OHOS 默认关闭；验证通过后可用 dart-define 打开。
  static bool enabled = Platform.operatingSystem != 'ohos' ||
      const bool.fromEnvironment('SFTP_WORKER_ISOLATE');

  /// 启动 worker 并完成 SSH/SFTP 建连。建连失败会在 boot 阶段返回，主 isolate
  /// 不执行任何 KEX/解密。
  static Future<SftpWorker> start({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
    required String pinnedFp,
  }) async {
    final boot = ReceivePort();
    final reply = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _sftpWorkerEntry,
        <String, Object?>{
          'boot': boot.sendPort,
          'reply': reply.sendPort,
          'host': host,
          'port': port,
          'username': username,
          'authMethod': authMethod.name,
          'password': password,
          'keyPem': keyPem,
          'keyPassphrase': keyPassphrase,
          'pinnedFp': pinnedFp,
        },
        debugName: 'sftp-worker-$host:$port',
      );
      final bootMsg = await boot.first.timeout(const Duration(seconds: 30));
      if (bootMsg is! Map) {
        throw const SftpStatusException('SFTP worker 启动失败：无 boot 响应');
      }
      final msg = bootMsg.cast<String, Object?>();
      if (msg['fatal'] != null) {
        throw sftpExceptionFromPayload(
          (msg['fatal'] as Map?)?.cast<String, Object?>() ?? msg,
        );
      }
      final cmd = msg['cmd'];
      if (cmd is! SendPort) {
        throw const SftpStatusException('SFTP worker 启动失败：缺少命令端口');
      }
      return SftpWorker._(cmd, reply, isolate);
    } catch (e) {
      try {
        isolate?.kill(priority: Isolate.immediate);
      } catch (_) {}
      boot.close();
      reply.close();
      if (e is SftpStatusException ||
          e is SourceAuthException ||
          e is SshHostKeyMismatch ||
          e is StateError) {
        rethrow;
      }
      throw SftpStatusException(shortSftpError(e, 'SFTP worker 启动失败'));
    } finally {
      boot.close();
    }
  }

  Future<Map<String, Object?>> _send(String type, Map<String, Object?> body) {
    if (_closed) {
      return Future.error(StateError('SFTP worker 已关闭'));
    }
    final id = _seq++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      _cmd.send(<String, Object?>{'t': type, 'id': id, ...body});
    } catch (e) {
      _pending.remove(id);
      return Future.error(StateError('SFTP worker 不可用：$e'));
    }
    return completer.future;
  }

  void _onMessage(Object? raw) {
    if (raw is! Map) return;
    final m = raw.cast<String, Object?>();
    final id = m['id'];
    if (id is int) {
      final read = _reads[id];
      if (read != null) {
        read.onMessage(m);
        return;
      }
      final pending = _pending.remove(id);
      if (pending != null && !pending.isCompleted) {
        if (m['ok'] == true) {
          pending.complete(m);
        } else {
          pending.completeError(sftpExceptionFromPayload(
            (m['error'] as Map?)?.cast<String, Object?>() ?? m,
          ));
        }
        return;
      }
    }
    if (m['t'] == 'exit' && !_closed) {
      _failAll(StateError('SFTP worker 意外退出'));
    }
  }

  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  }) async {
    final m = await _send('open', <String, Object?>{
      'path': path,
      'start': start,
      'length': length,
      'fallbackTotal': fallbackTotal,
    });
    final id = m['id'] as int;
    final contentLength = (m['contentLength'] as num?)?.toInt() ?? 0;
    final totalLength = (m['totalLength'] as num?)?.toInt();
    late final _ReadState state;
    final controller = StreamController<List<int>>(
      onListen: () {
        state.listened = true;
        state.listenDeadline?.cancel();
        state.listenDeadline = null;
        state.requestNext();
      },
      onPause: () => state.paused = true,
      onResume: () {
        state.paused = false;
        state.requestNext();
      },
      onCancel: () => state.cancel(),
    );
    state = _ReadState(this, id, controller, contentLength);
    _reads[id] = state;
    state.listenDeadline = Timer(const Duration(seconds: 60), () {
      // 打开成功但从没被消费：超时回收远端句柄，避免 worker 文件句柄泄漏。
      if (!state.listened) state.cancel();
    });
    return SftpOpenResult(
      contentLength: contentLength,
      totalLength: totalLength,
      stream: controller.stream,
    );
  }

  Future<void> probe(String path) async {
    await _send('probe', <String, Object?>{'path': path});
  }

  /// 上传不做自动重试：字节流是一次性的，失败后重放会丢数据/重复写。调用方
  /// （缓存/手动上传）可重新打开源文件再发一次。
  Future<void> upload(String path, Stream<List<int>> bytes, int length) async {
    if (_closed) throw StateError('SFTP worker 已关闭');
    final started = await _send(
        'uploadStart', <String, Object?>{'path': path, 'length': length});
    final id = started['id'] as int;
    final iterator = StreamIterator<List<int>>(bytes);
    final buf = BytesBuilder(copy: false);
    var ended = false;
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        buf.add(chunk);
        if (buf.length >= _kUploadBatchBytes) {
          await _uploadChunk(id, buf.takeBytes());
        }
      }
      final tail = buf.takeBytes();
      if (tail.isNotEmpty) await _uploadChunk(id, tail);
      await _send('uploadEnd', <String, Object?>{'uploadId': id});
      ended = true;
    } finally {
      await iterator.cancel();
      if (!ended) {
        // 让 worker 关句柄；主 isolate 不等待结果，避免失败路径再卡一次。
        if (!_closed) {
          _cmd.send(<String, Object?>{
            't': 'uploadAbort',
            'id': -1,
            'uploadId': id,
          });
        }
      }
    }
  }

  Future<void> _uploadChunk(int uploadId, Uint8List chunk) async {
    await _send('uploadChunk', <String, Object?>{
      'uploadId': uploadId,
      'bytes': chunk,
    });
  }

  Future<void> remove(String path) async {
    await _send('remove', <String, Object?>{'path': path});
  }

  Future<void> mkdir(String path) async {
    await _send('mkdir', <String, Object?>{'path': path});
  }

  Future<bool> isDirectory(String path) async {
    final m = await _send('isDir', <String, Object?>{'path': path});
    return m['isDirectory'] == true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final read in _reads.values.toList()) {
      read.detach();
    }
    _reads.clear();
    final id = _seq++;
    final done = Completer<Map<String, Object?>>();
    _pending[id] = done;
    try {
      _cmd.send(<String, Object?>{'t': 'close', 'id': id});
      await done.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      // 关连接失败不阻塞 UI；kill isolate 会回收 socket。
    }
    _pending.remove(id);
    try {
      _reply.close();
    } catch (_) {}
    try {
      _isolate.kill(priority: Isolate.immediate);
    } catch (_) {}
    _failAll(StateError('SFTP worker 已关闭'));
  }

  void _failAll(Object error) {
    for (final pending in _pending.values.toList()) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    for (final read in _reads.values.toList()) {
      read.fail(error);
    }
    _reads.clear();
  }

  void _removeRead(int id) {
    _reads.remove(id);
  }
}

class _ReadState {
  _ReadState(this.worker, this.id, this.controller, this.contentLength);

  final SftpWorker worker;
  final int id;
  final StreamController<List<int>> controller;
  final int contentLength;
  int received = 0;
  bool paused = false;
  bool requesting = false;
  bool closed = false;
  bool listened = false;
  Timer? listenDeadline;

  void requestNext() {
    if (closed || paused || requesting) return;
    if (contentLength > 0 && received >= contentLength) {
      _finish(sendCancel: true);
      return;
    }
    requesting = true;
    try {
      worker._cmd.send(<String, Object?>{
        't': 'read',
        'id': id,
        'maxBytes': _kReadBatchBytes,
      });
    } catch (e) {
      fail(StateError('SFTP worker 不可用：$e'));
    }
  }

  void onMessage(Map<String, Object?> m) {
    if (closed) return;
    switch (m['t']) {
      case 'data':
        final bytes = m['bytes'];
        if (bytes is Uint8List) {
          received += bytes.length;
          controller.add(bytes);
        }
        break;
      case 'batchDone':
        requesting = false;
        if (m['eof'] == true) {
          _finish(sendCancel: false);
        } else {
          requestNext();
        }
        break;
      case 'eof':
        _finish(sendCancel: false);
        break;
      case 'error':
        final payload = (m['error'] as Map?)?.cast<String, Object?>() ?? m;
        controller.addError(sftpExceptionFromPayload(payload));
        _finish(sendCancel: false);
        break;
    }
  }

  void cancel() {
    if (closed) return;
    closed = true;
    _cancelDeadline();
    worker._removeRead(id);
    if (!worker._closed) {
      try {
        worker._cmd.send(<String, Object?>{'t': 'cancel', 'id': id});
      } catch (_) {}
    }
    unawaited(controller.close());
  }

  void detach() {
    if (closed) return;
    closed = true;
    _cancelDeadline();
    unawaited(controller.close());
  }

  void fail(Object error) {
    if (closed) return;
    closed = true;
    _cancelDeadline();
    controller.addError(error);
    unawaited(controller.close());
  }

  void _finish({required bool sendCancel}) {
    if (closed) return;
    closed = true;
    _cancelDeadline();
    worker._removeRead(id);
    if (sendCancel && !worker._closed) {
      try {
        worker._cmd.send(<String, Object?>{'t': 'cancel', 'id': id});
      } catch (_) {}
    }
    unawaited(controller.close());
  }

  void _cancelDeadline() {
    listenDeadline?.cancel();
    listenDeadline = null;
  }
}

/// main isolate 侧传输实现：只把命令和明文块搬进/搬出 worker。
class SftpIsolateTransport implements SftpTransport {
  final String host;
  final int port;
  final String username;
  final SftpAuthMethod authMethod;
  final String password;
  final String keyPem;
  final String keyPassphrase;
  final String pinnedFp;

  SftpIsolateTransport({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.password,
    required this.keyPem,
    required this.keyPassphrase,
    required this.pinnedFp,
  });

  SftpWorker? _worker;
  Timer? _idleSweep;
  int _idleTicks = 0;

  Future<SftpWorker> _ensureWorker() async {
    final cur = _worker;
    if (cur != null && !cur.isClosed) return cur;
    final next = await SftpWorker.start(
      host: host,
      port: port,
      username: username,
      authMethod: authMethod,
      password: password,
      keyPem: keyPem,
      keyPassphrase: keyPassphrase,
      pinnedFp: pinnedFp,
    );
    _worker = next;
    _idleTicks = 0;
    _idleSweep ??= Timer.periodic(const Duration(minutes: 1), (_) {
      final worker = _worker;
      if (worker == null) {
        _idleSweep?.cancel();
        _idleSweep = null;
        return;
      }
      if (worker.busy) {
        _idleTicks = 0;
        return;
      }
      if (++_idleTicks >= 10) {
        _idleTicks = 0;
        unawaited(_closeWorker());
      }
    });
    return next;
  }

  Future<void> _closeWorker() async {
    _idleSweep?.cancel();
    _idleSweep = null;
    _idleTicks = 0;
    final cur = _worker;
    _worker = null;
    try {
      await cur?.close();
    } catch (_) {}
  }

  Future<T> _withWorker<T>(Future<T> Function(SftpWorker worker) fn) async {
    try {
      return await fn(await _ensureWorker());
    } on SourceAuthException {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } on StateError {
      rethrow;
    } on SftpStatusException catch (e) {
      if (e.code == SftpStatusCode.noConnection ||
          e.code == SftpStatusCode.connectionLost) {
        return _reconnectAndRetry(fn);
      }
      rethrow;
    } catch (_) {
      return _reconnectAndRetry(fn);
    }
  }

  Future<T> _reconnectAndRetry<T>(
      Future<T> Function(SftpWorker worker) fn) async {
    await _closeWorker();
    try {
      return await fn(await _ensureWorker());
    } on SourceAuthException {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } on StateError {
      rethrow;
    } on SftpStatusException {
      rethrow;
    } catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 请求失败'));
    }
  }

  @override
  Future<void> probe(String path) =>
      _withWorker((worker) => worker.probe(path));

  @override
  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  }) =>
      _withWorker((worker) => worker.open(
            path,
            start: start,
            length: length,
            fallbackTotal: fallbackTotal,
          ));

  @override
  Future<void> upload(String path, Stream<List<int>> bytes, int length) async {
    // 不重试：流只能消费一次。worker 启动失败仍可在此抛给调用方。
    final worker = await _ensureWorker();
    await worker.upload(path, bytes, length);
  }

  @override
  Future<void> remove(String path) =>
      _withWorker((worker) => worker.remove(path));

  @override
  Future<void> mkdir(String path) =>
      _withWorker((worker) => worker.mkdir(path));

  @override
  Future<bool> isDirectory(String path) =>
      _withWorker((worker) => worker.isDirectory(path));

  @override
  Future<void> close() => _closeWorker();
}

// ---------- worker isolate ----------

class _WorkerFile {
  _WorkerFile({
    required this.id,
    required this.file,
    required this.offset,
    required this.end,
    required this.reply,
  });

  final int id;
  final SftpFile file;
  final int? end;
  final SendPort reply;
  int offset;
  bool reading = false;
  bool cancelled = false;
  bool closed = false;

  void send(Map<String, Object?> m) {
    try {
      reply.send(<String, Object?>{'id': id, ...m});
    } catch (_) {}
  }

  Future<void> pump(int maxBytes) async {
    if (reading || cancelled || closed) return;
    reading = true;
    try {
      final remaining = end == null ? maxBytes : end! - offset;
      if (remaining <= 0) {
        send(<String, Object?>{'t': 'eof'});
        await close();
        return;
      }
      var got = 0;
      await for (final chunk in file.read(
        length: remaining,
        offset: offset,
        chunkSize: _kReadChunkBytes,
        maxPendingRequests: _kReadMaxPending,
      )) {
        if (cancelled || closed) break;
        offset += chunk.length;
        got += chunk.length;
        send(<String, Object?>{'t': 'data', 'bytes': chunk});
        if (got >= remaining) break;
      }
      if (cancelled || closed) return;
      final eof = (end != null && offset >= end!) || got < remaining;
      send(<String, Object?>{'t': 'batchDone', 'eof': eof});
      if (eof) await close();
    } catch (e) {
      if (!cancelled && !closed) {
        send(<String, Object?>{
          't': 'error',
          'error': _sftpErrorPayload(e),
        });
      }
      await close();
    } finally {
      reading = false;
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    try {
      await file.close();
    } catch (_) {}
  }
}

class _WorkerUpload {
  _WorkerUpload(this.file);
  final SftpFile file;
  int offset = 0;
  bool closed = false;

  Future<void> close() async {
    if (closed) return;
    closed = true;
    try {
      await file.close();
    } catch (_) {}
  }
}

Future<void> _sftpWorkerEntry(Map<String, Object?> params) async {
  final boot = params['boot'] as SendPort;
  final reply = params['reply'] as SendPort;
  final cmd = ReceivePort();
  late final OpenedSftpConnection conn;
  try {
    conn = await SftpConnection.open(
      host: params['host'] as String,
      port: params['port'] as int,
      username: params['username'] as String,
      authMethod: parseSftpAuthMethod(params['authMethod']),
      password: params['password'] as String,
      keyPem: params['keyPem'] as String,
      keyPassphrase: params['keyPassphrase'] as String,
      pinnedFp: params['pinnedFp'] as String,
    );
  } catch (e) {
    try {
      boot.send(<String, Object?>{'fatal': _sftpErrorPayload(e)});
    } catch (_) {}
    cmd.close();
    return;
  }

  final files = <int, _WorkerFile>{};
  final uploads = <int, _WorkerUpload>{};
  var closing = false;

  void replyOk(int id, [Map<String, Object?>? extra]) {
    try {
      reply.send(<String, Object?>{'id': id, 'ok': true, ...?extra});
    } catch (_) {}
  }

  void replyError(int id, Object e) {
    try {
      reply.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': _sftpErrorPayload(e),
      });
    } catch (_) {}
  }

  Future<void> handleOpen(Map<String, Object?> m) async {
    final id = m['id'] as int;
    SftpFile? file;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      file = await conn.sftp.open(
        m['path'] as String,
        mode: SftpFileOpenMode.read,
      );
      final fallbackTotal = (m['fallbackTotal'] as num?)?.toInt() ?? 0;
      int total;
      try {
        total = (await file.stat()).size ?? fallbackTotal;
      } catch (_) {
        total = fallbackTotal;
      }
      final begin = (m['start'] as num?)?.toInt() ?? 0;
      final length = (m['length'] as num?)?.toInt();
      int? end;
      if (length != null) {
        end = begin + length;
        if (total > 0 && end > total) end = total;
      } else if (total > 0) {
        end = total;
      }
      final contentLength =
          end == null ? 0 : (end - begin < 0 ? 0 : end - begin);
      files[id] = _WorkerFile(
        id: id,
        file: file,
        offset: begin,
        end: end,
        reply: reply,
      );
      file = null; // 句柄所有权已交给 _WorkerFile
      replyOk(id, <String, Object?>{
        'contentLength': contentLength,
        'totalLength': total > 0 ? total : null,
      });
    } catch (e) {
      replyError(id, e);
      try {
        await file?.close();
      } catch (_) {}
    }
  }

  Future<void> handleProbe(Map<String, Object?> m) async {
    final id = m['id'] as int;
    SftpFile? file;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      file = await conn.sftp.open(
        m['path'] as String,
        mode: SftpFileOpenMode.read,
      );
      await file.read(length: 1, offset: 0).first;
      replyOk(id);
    } catch (e) {
      replyError(id, e);
    } finally {
      try {
        await file?.close();
      } catch (_) {}
    }
  }

  Future<void> handleUploadStart(Map<String, Object?> m) async {
    final id = m['id'] as int;
    SftpFile? file;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      file = await conn.sftp.open(
        m['path'] as String,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      uploads[id] = _WorkerUpload(file);
      file = null;
      replyOk(id);
    } catch (e) {
      replyError(id, e);
      try {
        await file?.close();
      } catch (_) {}
    }
  }

  Future<void> handleUploadChunk(Map<String, Object?> m) async {
    final id = m['id'] as int;
    final uploadId = (m['uploadId'] as num?)?.toInt() ?? -1;
    final upload = uploads[uploadId];
    if (upload == null) {
      replyError(id, StateError('上传句柄不存在'));
      return;
    }
    try {
      final bytes = m['bytes'] as Uint8List;
      await upload.file.writeBytes(
        bytes,
        offset: upload.offset,
        chunkSize: _kUploadChunkBytes,
        maxPendingRequests: _kUploadMaxPending,
      );
      upload.offset += bytes.length;
      replyOk(id);
    } catch (e) {
      replyError(id, e);
    }
  }

  Future<void> handleUploadEnd(Map<String, Object?> m) async {
    final id = m['id'] as int;
    final uploadId = (m['uploadId'] as num?)?.toInt() ?? -1;
    final upload = uploads.remove(uploadId);
    if (upload == null) {
      replyError(id, StateError('上传句柄不存在'));
      return;
    }
    try {
      await upload.close();
      replyOk(id);
    } catch (e) {
      replyError(id, e);
    }
  }

  Future<void> handleUploadAbort(Map<String, Object?> m) async {
    final uploadId = (m['uploadId'] as num?)?.toInt() ?? -1;
    final upload = uploads.remove(uploadId);
    try {
      await upload?.close();
    } catch (_) {}
  }

  Future<void> handleRemove(Map<String, Object?> m) async {
    final id = m['id'] as int;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      await conn.sftp.remove(m['path'] as String);
      replyOk(id);
    } catch (e) {
      replyError(id, e);
    }
  }

  Future<void> handleMkdir(Map<String, Object?> m) async {
    final id = m['id'] as int;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      await conn.sftp.mkdir(m['path'] as String);
      replyOk(id);
    } catch (e) {
      replyError(id, e);
    }
  }

  Future<void> handleIsDir(Map<String, Object?> m) async {
    final id = m['id'] as int;
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      final attrs = await conn.sftp.stat(m['path'] as String);
      replyOk(id, <String, Object?>{'isDirectory': attrs.isDirectory});
    } catch (e) {
      replyError(id, e);
    }
  }

  void handleRead(Map<String, Object?> m) {
    final id = m['id'] as int;
    final file = files[id];
    if (file == null) {
      try {
        reply.send(<String, Object?>{
          't': 'error',
          'id': id,
          'error': _sftpErrorPayload(StateError('读句柄不存在')),
        });
      } catch (_) {}
      return;
    }
    final maxBytes = (m['maxBytes'] as num?)?.toInt() ?? _kReadBatchBytes;
    unawaited(file.pump(maxBytes));
  }

  Future<void> handleCancel(Map<String, Object?> m) async {
    final id = m['id'] as int;
    final file = files.remove(id);
    if (file != null) {
      file.cancelled = true;
      await file.close();
    }
    try {
      reply.send(<String, Object?>{'t': 'closed', 'id': id});
    } catch (_) {}
  }

  try {
    boot.send(<String, Object?>{'cmd': cmd.sendPort});
  } catch (e) {
    cmd.close();
    try {
      await conn.sftp.close();
    } catch (_) {}
    conn.client.close();
    return;
  }

  await for (final raw in cmd) {
    if (raw is! Map) continue;
    final m = raw.cast<String, Object?>();
    final type = m['t'];
    switch (type) {
      case 'open':
        unawaited(handleOpen(m));
        break;
      case 'read':
        handleRead(m);
        break;
      case 'cancel':
        unawaited(handleCancel(m));
        break;
      case 'probe':
        unawaited(handleProbe(m));
        break;
      case 'uploadStart':
        unawaited(handleUploadStart(m));
        break;
      case 'uploadChunk':
        unawaited(handleUploadChunk(m));
        break;
      case 'uploadEnd':
        unawaited(handleUploadEnd(m));
        break;
      case 'uploadAbort':
        unawaited(handleUploadAbort(m));
        break;
      case 'remove':
        unawaited(handleRemove(m));
        break;
      case 'mkdir':
        unawaited(handleMkdir(m));
        break;
      case 'isDir':
        unawaited(handleIsDir(m));
        break;
      case 'close':
        closing = true;
        for (final file in files.values.toList()) {
          file.cancelled = true;
          await file.close();
        }
        files.clear();
        for (final upload in uploads.values.toList()) {
          await upload.close();
        }
        uploads.clear();
        try {
          await conn.sftp.close();
        } catch (_) {}
        try {
          conn.client.close();
        } catch (_) {}
        replyOk(m['id'] as int, <String, Object?>{'t': 'closed'});
        cmd.close();
        return;
    }
  }
}

/// 跨 isolate 的错误载荷 → 主 isolate 异常。保持与旧直连一致的中文提示和
/// 状态码（上传/删除的 permissionDenied / noSuchFile 分支依赖 code）。
Object sftpExceptionFromPayload(Map<String, Object?> m) {
  final kind = m['kind'];
  final message = (m['message'] as String?)?.trim();
  switch (kind) {
    case 'hostKey':
      return SshHostKeyMismatch((m['actual'] as String?) ?? '');
    case 'auth':
      return SourceAuthException(message ?? 'SFTP 鉴权失败');
    case 'status':
      return SftpStatusException(
        message ?? 'SFTP 请求失败',
        code: (m['code'] as num?)?.toInt(),
      );
    case 'state':
      return StateError(message ?? 'SFTP 状态错误');
    default:
      return SftpStatusException(message ?? 'SFTP 请求失败');
  }
}

Map<String, Object?> _sftpErrorPayload(Object e) {
  if (e is SshHostKeyMismatch) {
    return <String, Object?>{
      'kind': 'hostKey',
      'message': e.toString(),
      'actual': e.actual,
    };
  }
  if (e is SourceAuthException) {
    return <String, Object?>{'kind': 'auth', 'message': e.message};
  }
  if (e is SftpStatusError) {
    return <String, Object?>{
      'kind': 'status',
      'message': e.message,
      'code': e.code,
    };
  }
  if (e is SftpStatusException) {
    return <String, Object?>{
      'kind': 'status',
      'message': e.message,
      'code': e.code,
    };
  }
  if (e is StateError) {
    return <String, Object?>{'kind': 'state', 'message': e.message.toString()};
  }
  return <String, Object?>{'kind': 'unknown', 'message': e.toString()};
}
