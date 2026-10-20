import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'music_source.dart';
import 'sftp_common.dart';
import 'sftp_direct_transport.dart';

/// 读批大小：主 isolate 一次最多拉这么多已解密字节。256KB 约等于 320kbps
/// 音频 6 秒，起播/seek 的首批延迟足够小；同时把跨 isolate 缓冲上限钉死。
const int _kReadBatchBytes = 256 * 1024;

/// worker 内部 SFTP 读块大小；单个 64KB 请求约合 320kbps 音频 1.6 秒。
const int _kReadChunkBytes = 64 * 1024;

/// 单个读流（一个 SFTP 文件句柄）在飞的 64KB 读块上限；多个流共享
/// [_kReadGlobalConcurrency] 的全局配额。单流 4 路约等于原实现的每流并发，
/// 起播/顺序读吞吐不变；多流（播放 + 补读 + seek 旧流）才被全局配额收口。
const int _kReadPerStreamConcurrency = 4;

/// 全 worker 在飞的 SFTP 读请求总数上限（原先每流各 4 路、叠加无上限）。
/// 真机实测：一场 seek 会有旧流 + 新流 + 重复流的十几路 64KB 读在飞，
/// `open`/`stat` 控制请求排在它们后面要 3s 级才返回；限流后控制请求
/// 最多只需等 4 个读，seek 打开延迟降到 RTT 量级。
const int _kReadGlobalConcurrency = 4;

/// 上传批大小：主 isolate 攒够再跨 isolate 发，减少消息往返；worker 内
/// `writeBytes` 再按 64KB 扇出。
const int _kUploadBatchBytes = 256 * 1024;
const int _kUploadChunkBytes = 64 * 1024;
const int _kUploadMaxPending = 4;

/// 上传失败是否值得断线续传：只有连接类错误可以重试；权限/不存在等业务
/// 状态码原样抛给调用方，避免把真实失败原因掩盖成「重试后仍失败」。
bool _uploadRetryable(Object e) {
  if (e is SourceAuthException || e is SshHostKeyMismatch) return false;
  if (e is SftpStatusException) {
    final code = e.code;
    return code == null ||
        code == SftpStatusCode.noConnection ||
        code == SftpStatusCode.connectionLost;
  }
  return true; // worker 退出/关闭、socket 层错误等
}

/// worker 基础设施启动失败（`Isolate.spawn` 抛错 / boot 超时 / 缺少命令
/// 端口）：与 SSH 层错误区分开，供传输层决定「当次转旧直连 / 连续失败后
/// 永久降级」。SSH 连不上、鉴权失败、指纹失配等真实业务错误不在此列，
/// 不触发降级——旧直连会遇到同样的失败，只会掩盖真实原因。
class SftpWorkerUnavailableException extends SftpStatusException {
  const SftpWorkerUnavailableException(super.message);
}

void _trace(String message) => sftpTrace(message);

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
    _live.add(this);
    // 新建即视为最近使用：多源上限淘汰时不会先挑刚起来的 worker。
    _lastUsed = ++_useSeq;
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

  /// 有打开的读流、未完成的命令或宿主租约（正在执行的操作）。空闲回收与
  /// 多源上限只看这个，不靠定时器猜播放状态：暂停的播放仍保留读流，不会
  /// 在暂停期间被误关。
  bool get busy => _leases > 0 || _reads.isNotEmpty || _pending.isNotEmpty;

  /// 是否启用 worker 路径。OHOS 默认关闭；验证通过后可用 dart-define 打开。
  static bool enabled = Platform.operatingSystem != 'ohos' ||
      const bool.fromEnvironment('SFTP_WORKER_ISOLATE');

  /// 供传输层写同一条 `[sftp-worker]` 诊断日志（受 SFTP_WORKER_TRACE 控制）。
  static void trace(String message) => _trace(message);

  /// 全局存活 worker 软上限：多 SFTP 源同时活动时，避免每个源各常驻一条
  /// SSH 连接、互相抢带宽。新 worker 启动前若已达上限，先回收最久未用的
  /// **空闲** worker（无读流、无在飞命令、无租约）；全部忙时不强行回收，
  /// 宁可短暂超一点，也不打断正在播放/补读的源。
  static const int maxLiveWorkers = 3;

  /// 存活 worker 注册表；淘汰按 [_lastUsed] 找最久未用。
  static final List<SftpWorker> _live = [];
  static int _useSeq = 0;
  int _lastUsed = 0;
  int _leases = 0;

  /// 由传输层在拉起新 worker 前调用：超上限时回收最久未用的空闲 worker。
  static void evictIdleForCapacity() {
    if (_live.length < maxLiveWorkers) return;
    final idle = _live.where((w) => !w._closed && !w.busy).toList()
      ..sort((a, b) => a._lastUsed.compareTo(b._lastUsed));
    for (final worker in idle) {
      if (_live.length < maxLiveWorkers) break;
      _trace('evict idle worker (live=${_live.length}, '
          'max=$maxLiveWorkers)');
      unawaited(worker.close());
    }
  }

  /// 仅供测试/冒烟：当前存活 worker 数。
  @visibleForTesting
  static int get liveWorkerCount => _live.length;

  /// 宿主传输在操作期间持有租约；防止「已取得 worker、命令尚未发出」的
  /// 窗口里被 [evictIdleForCapacity] 回收（发送失败会变成用户可见错误）。
  void _lease() => _leases++;

  void _release() {
    if (_leases > 0) _leases--;
  }

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
    final started = Stopwatch()..start();
    _trace('spawn $host:$port user=$username auth=${authMethod.name}');
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
        throw const SftpWorkerUnavailableException(
            'SFTP worker 启动失败：无 boot 响应');
      }
      final msg = bootMsg.cast<String, Object?>();
      if (msg['fatal'] != null) {
        _trace('boot fatal $host:$port after ${started.elapsedMilliseconds}ms: '
            '${msg['fatal']}');
        throw sftpExceptionFromPayload(
          (msg['fatal'] as Map?)?.cast<String, Object?>() ?? msg,
        );
      }
      final cmd = msg['cmd'];
      if (cmd is! SendPort) {
        throw const SftpWorkerUnavailableException('SFTP worker 启动失败：缺少命令端口');
      }
      _trace('ready $host:$port in ${started.elapsedMilliseconds}ms');
      return SftpWorker._(cmd, reply, isolate);
    } catch (e) {
      _trace(
          'start failed $host:$port after ${started.elapsedMilliseconds}ms: $e');
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
      throw SftpWorkerUnavailableException(
          shortSftpError(e, 'SFTP worker 启动失败'));
    } finally {
      boot.close();
    }
  }

  Future<Map<String, Object?>> _send(String type, Map<String, Object?> body) {
    if (_closed) {
      return Future.error(StateError('SFTP worker 已关闭'));
    }
    _lastUsed = ++_useSeq;
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
      _trace('isolate exited unexpectedly');
      _failAll(StateError('SFTP worker 意外退出'));
    }
  }

  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  }) async {
    _trace('open $path start=$start length=$length');
    final m = await _send('open', <String, Object?>{
      'path': path,
      'start': start,
      'length': length,
      'fallbackTotal': fallbackTotal,
    });
    final id = m['id'] as int;
    final contentLength = (m['contentLength'] as num?)?.toInt() ?? 0;
    final totalLength = (m['totalLength'] as num?)?.toInt();
    _trace('open ok id=$id content=$contentLength total=$totalLength');
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

  /// 开始一次上传，返回上传句柄；[truncate]=false 时不截断远端文件，
  /// 供断线续传按绝对偏移覆盖写（见 [SftpIsolateTransport.upload]）。
  Future<int> uploadBegin(String path, {bool truncate = true}) async {
    final m = await _send('uploadStart', <String, Object?>{
      'path': path,
      'truncate': truncate,
    });
    return m['id'] as int;
  }

  /// 写一批明文；[offset] 是批在文件中的绝对偏移（续传重发时不变）。
  Future<void> uploadChunk(int uploadId, int offset, Uint8List bytes) async {
    await _send('uploadChunk', <String, Object?>{
      'uploadId': uploadId,
      'offset': offset,
      'bytes': bytes,
    });
  }

  Future<void> uploadEnd(int uploadId) async {
    await _send('uploadEnd', <String, Object?>{'uploadId': uploadId});
  }

  /// 放弃上传：只通知 worker 关远端句柄，不等回复，避免失败路径再卡一次。
  void uploadAbort(int uploadId) {
    if (_closed) return;
    try {
      _cmd.send(<String, Object?>{
        't': 'uploadAbort',
        'id': -1,
        'uploadId': uploadId,
      });
    } catch (_) {}
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
    _live.remove(this);
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
  bool firstDataLogged = false;
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
          if (!firstDataLogged) {
            firstDataLogged = true;
            _trace('read first data id=$id bytes=${bytes.length}');
          }
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
    _trace('read cancel id=$id received=$received/$contentLength');
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
    _trace('read fail id=$id received=$received: $error');
    closed = true;
    _cancelDeadline();
    controller.addError(error);
    unawaited(controller.close());
  }

  void _finish({required bool sendCancel}) {
    if (closed) return;
    _trace('read finish id=$id received=$received/$contentLength '
        'sendCancel=$sendCancel');
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
  Future<SftpWorker>? _starting;
  Timer? _idleSweep;
  int _idleTicks = 0;
  bool _disposed = false;

  /// 旧直连兜底（worker 启动失败后惰性创建；正常路径不建连）。
  SftpDirectTransport? _direct;

  /// worker 连续启动失败达到 [_kStartFailuresBeforeDegrade] 后永久降级：
  /// 本实例不再尝试 spawn，全部操作走 [_direct]。只统计传输层启动失败
  /// （[SftpWorkerUnavailableException]），SSH/鉴权错误不计入。
  bool _degraded = false;
  int _startFailures = 0;

  /// 连续启动失败多少次后永久降级。首次失败只影响当次操作（立即转直连），
  /// 下一次仍给 worker 一次机会——偶发瞬态失败（内存压力等）不至于让整个
  /// 源会话退回 UI isolate 解密；连续两次才认为是平台性问题。
  static const int _kStartFailuresBeforeDegrade = 2;

  /// 仅供测试：非空时替代 [SftpWorker.start]（故障注入，验证降级调度）。
  @visibleForTesting
  static Future<SftpWorker> Function()? debugStartOverride;

  /// 记录一次 worker 启动失败；达到阈值时永久降级并输出诊断日志。
  void _noteStartFailure() {
    _startFailures++;
    if (_startFailures >= _kStartFailuresBeforeDegrade) {
      if (!_degraded) {
        _degraded = true;
        _trace('worker 连续启动失败 $_startFailures 次，'
            '$host:$port 永久改走旧直连');
      }
    } else {
      _trace('worker 启动失败 $_startFailures 次，本次操作转旧直连');
    }
  }

  SftpDirectTransport _directTransport() => _direct ??= SftpDirectTransport(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        password: password,
        keyPem: keyPem,
        keyPassphrase: keyPassphrase,
        pinnedFp: pinnedFp,
      );

  /// 统一调度：worker 可用时走 worker；启动失败或已永久降级时走旧直连。
  /// 已降级实例的后续操作零等待，不再为每次调用白付一次 spawn/boot 超时。
  Future<T> _dispatch<T>(
    Future<T> Function(SftpWorker worker) viaWorker,
    Future<T> Function(SftpDirectTransport direct) viaDirect,
  ) async {
    if (_disposed) throw StateError('SFTP worker 传输已关闭');
    if (_degraded) return viaDirect(_directTransport());
    final SftpWorker worker;
    try {
      worker = await _ensureWorker();
    } on SftpWorkerUnavailableException catch (e) {
      // 命令还未下发，本次操作转旧直连是安全的。
      _trace('worker 不可用（$e），本次操作转旧直连');
      return viaDirect(_directTransport());
    }
    // 命令已下发（含掉线重放）后 worker 再启动失败时不转直连：操作可能已
    // 在远端生效，转直连重复投递会改变语义（如删除第二次报「不存在」）。
    //
    // 租约覆盖整个操作窗口（含「已取到 worker、命令未发」的微任务间隙），
    // 多源上限回收空闲 worker 时不会把它挑走。
    worker._lease();
    try {
      return await _withWorker(worker, viaWorker);
    } finally {
      worker._release();
    }
  }

  /// 并发去重：多个命令（起播/读标签/歌词）会在同一帧里先后进来，
  /// 若无 [_starting] 守卫，每个调用都会看到 `_worker == null` 而各起一个
  /// worker（真机日志实测两条 SSH 握手并发、首个 isolate 被覆盖后泄漏）。
  Future<SftpWorker> _ensureWorker() {
    final cur = _worker;
    if (cur != null && !cur.isClosed) return Future.value(cur);
    final starting = _starting;
    if (starting != null) return starting;
    if (_disposed) {
      return Future.error(StateError('SFTP worker 传输已关闭'));
    }
    final future = _startWorker();
    _starting = future;
    return future.whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
  }

  Future<SftpWorker> _startWorker() async {
    // 多源并发：全局存活 worker 达上限时，先回收最久未用的空闲 worker。
    SftpWorker.evictIdleForCapacity();
    final override = debugStartOverride;
    final SftpWorker next;
    try {
      next = await (override != null
          ? override()
          : SftpWorker.start(
              host: host,
              port: port,
              username: username,
              authMethod: authMethod,
              password: password,
              keyPem: keyPem,
              keyPassphrase: keyPassphrase,
              pinnedFp: pinnedFp,
            ));
    } on SftpWorkerUnavailableException {
      _noteStartFailure();
      rethrow;
    }
    _startFailures = 0;
    if (_disposed) {
      // close() 在握手期间被调用：新 worker 直接回收，不留给无人引用的状态。
      try {
        await next.close();
      } catch (_) {}
      throw StateError('SFTP worker 传输已关闭');
    }
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

  Future<T> _withWorker<T>(
    SftpWorker worker,
    Future<T> Function(SftpWorker worker) fn,
  ) async {
    try {
      return await fn(worker);
    } on SourceAuthException {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } on StateError {
      rethrow;
    } on SftpStatusException catch (e) {
      if (e.code == SftpStatusCode.noConnection ||
          e.code == SftpStatusCode.connectionLost) {
        _trace('reconnect after status ${e.code}: ${e.message}');
        return _reconnectAndRetry(fn);
      }
      rethrow;
    } catch (e) {
      _trace('reconnect after error: $e');
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
  Future<void> probe(String path) => _dispatch<void>(
        (worker) => worker.probe(path),
        (direct) => direct.probe(path),
      );

  @override
  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  }) =>
      _dispatch<SftpOpenResult>(
        (worker) => worker.open(
          path,
          start: start,
          length: length,
          fallbackTotal: fallbackTotal,
        ),
        (direct) => direct.open(
          path,
          start: start,
          length: length,
          fallbackTotal: fallbackTotal,
        ),
      );

  /// 上传：断线自动重连一次并续传。
  ///
  /// 字节流是一次性的，不能靠调用方重开源文件重发，所以由这里驱动：
  /// 每批带绝对偏移发出，发出前记为 [pending]；连接类失败后重连，若已有
  /// 确认落盘的数据则以 `truncate: false` 重开会话并重放 [pending]
  /// （相同字节覆盖写是幂等的），否则重新截断从头来。业务错误
  /// （权限/不存在）不重试，原样抛给调用方。
  ///
  /// worker 启动失败发生在消费源流之前：整次上传转旧直连重投，流不受影响。
  @override
  Future<void> upload(String path, Stream<List<int>> bytes, int length) async {
    if (_disposed) throw StateError('SFTP worker 传输已关闭');
    if (_degraded) return _directTransport().upload(path, bytes, length);
    final SftpWorker worker;
    try {
      worker = await _ensureWorker();
    } on SftpWorkerUnavailableException catch (e) {
      _trace('worker 不可用（$e），本次上传转旧直连');
      return _directTransport().upload(path, bytes, length);
    }
    await _uploadViaWorker(worker, path, bytes);
  }

  Future<void> _uploadViaWorker(
    SftpWorker initial,
    String path,
    Stream<List<int>> bytes,
  ) async {
    final iterator = StreamIterator<List<int>>(bytes);
    var worker = initial;
    int? uploadId;
    Uint8List? pending; // 已读出、尚未确认落盘的最后一批
    var pendingAt = 0; // [pending] 在文件中的绝对偏移
    var batchStart = 0; // 当前批缓冲的起始绝对偏移
    var staged = 0; // 已从源流读出并交给上传的总字节数（含缓冲/在飞的批）
    var resumed = false;
    final batch = BytesBuilder(copy: false);

    Future<void> openSession({required bool truncate}) async {
      uploadId = await worker.uploadBegin(path, truncate: truncate);
      SftpWorker.trace('upload open $path truncate=$truncate id=$uploadId');
    }

    // 连接类失败后重连一次并重放当前 RPC；重放用绝对偏移覆盖最后一批。
    Future<T> guard<T>(Future<T> Function() op) async {
      try {
        return await op();
      } catch (e) {
        if (resumed || !_uploadRetryable(e)) rethrow;
        resumed = true;
        SftpWorker.trace('upload 断线续传 $path：$e');
        final acked = pending == null ? staged : pendingAt;
        final old = worker;
        await _closeWorker();
        worker = await _ensureWorker();
        // 租约转交到新 worker；若上面抛错，finally 仍释放 old 的租约。
        old._release();
        worker._lease();
        if (uploadId != null) {
          // 首块之前失败时会话还没建立，交给重放的 op 自己开。
          await openSession(truncate: acked == 0);
        }
        return await op();
      }
    }

    Future<void> flush() async {
      if (batch.length == 0) return;
      pending = batch.takeBytes();
      pendingAt = batchStart;
      await guard(() => worker.uploadChunk(uploadId!, pendingAt, pending!));
      pending = null;
      batchStart = staged;
    }

    // 整次上传期间持有租约：上传是活跃写操作，不该被多源上限当成空闲回收
    // （虽然断线续传能兜住，但没必要凭空制造重连）。
    worker._lease();
    var done = false;
    try {
      await guard(() => openSession(truncate: true));
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        batch.add(chunk);
        staged += chunk.length;
        if (batch.length >= _kUploadBatchBytes) await flush();
      }
      await flush();
      await guard(() => worker.uploadEnd(uploadId!));
      done = true;
    } finally {
      worker._release();
      await iterator.cancel();
      final id = uploadId;
      if (!done && id != null) worker.uploadAbort(id);
    }
  }

  @override
  Future<void> remove(String path) => _dispatch<void>(
        (worker) => worker.remove(path),
        (direct) => direct.remove(path),
      );

  @override
  Future<void> mkdir(String path) => _dispatch<void>(
        (worker) => worker.mkdir(path),
        (direct) => direct.mkdir(path),
      );

  @override
  Future<bool> isDirectory(String path) => _dispatch<bool>(
        (worker) => worker.isDirectory(path),
        (direct) => direct.isDirectory(path),
      );

  @override
  Future<void> close() async {
    _disposed = true;
    _degraded = false;
    _startFailures = 0;
    await _closeWorker();
    final direct = _direct;
    _direct = null;
    try {
      await direct?.close();
    } catch (_) {}
  }
}

// ---------- worker isolate ----------

/// worker 读调度闸门：控制请求（open/stat/probe）优先于读。
///
/// - [enterControl]/[exitControl] 包住控制请求：期间不再下发新的读请求；
/// - [acquireReadSlot]/[releaseReadSlot] 限制全 worker 在飞读请求数。
///
/// 只能约束“新下发”的请求，已在途的无法撤回；因此上限设小，让控制请求
/// 最多排队短于一两个 RTT 窗口。真机日志里 seek 时 `open ok` 曾拖到
/// 3.5s（排在十几路 64KB 读之后），就是缺这道闸门。
class _WorkerReadGate {
  int _controlOps = 0;
  Completer<void> _controlIdle = Completer<void>()..complete();
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  void enterControl() {
    if (_controlOps == 0) _controlIdle = Completer<void>();
    _controlOps++;
  }

  void exitControl() {
    if (_controlOps == 0) return;
    _controlOps--;
    if (_controlOps == 0 && !_controlIdle.isCompleted) {
      _controlIdle.complete();
    }
  }

  Future<void> acquireReadSlot() async {
    while (true) {
      // 控制请求（尤其 seek 的 open/stat）优先：在飞期间不下发新读。
      await _controlIdle.future;
      if (_inFlight < _kReadGlobalConcurrency) {
        _inFlight++;
        return;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void releaseReadSlot() {
    if (_inFlight == 0) return;
    _inFlight--;
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
  }
}

class _WorkerFile {
  _WorkerFile({
    required this.id,
    required this.file,
    required this.offset,
    required this.end,
    required this.reply,
    required this.gate,
  });

  final int id;
  final SftpFile file;
  final int? end;
  final SendPort reply;
  final _WorkerReadGate gate;
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
      final requested = end == null ? maxBytes : end! - offset;
      if (requested <= 0) {
        send(<String, Object?>{'t': 'eof'});
        await close();
        return;
      }
      final base = offset;
      final queue = <Future<Uint8List?>>[];
      var reserved = 0;

      void topUp() {
        while (!cancelled &&
            !closed &&
            reserved < requested &&
            queue.length < _kReadPerStreamConcurrency) {
          final want = requested - reserved > _kReadChunkBytes
              ? _kReadChunkBytes
              : requested - reserved;
          final future = _readChunk(base + reserved, want);
          // 取消时这个 future 可能不再被 await；先吞掉错误防 unhandled。
          future.ignore();
          queue.add(future);
          reserved += want;
        }
      }

      topUp();
      var got = 0;
      while (got < requested && queue.isNotEmpty && !cancelled && !closed) {
        final chunk = await queue.removeAt(0);
        topUp();
        if (cancelled || closed) return;
        if (chunk == null || chunk.isEmpty) break;
        offset += chunk.length;
        got += chunk.length;
        send(<String, Object?>{'t': 'data', 'bytes': chunk});
      }
      if (cancelled || closed) return;
      final eof = (end != null && offset >= end!) || got < requested;
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

  /// 读一个不超过 [want] 字节的块；并发上限交给 [gate] 统一调度。
  /// 短读（OpenSSH 会把请求裁剪到较小回复）由 dartssh2 在同一流内补齐
  /// 到 [want]；流自然结束=EOF。
  Future<Uint8List?> _readChunk(int at, int want) async {
    await gate.acquireReadSlot();
    try {
      if (cancelled || closed) return null;
      final buf = BytesBuilder(copy: false);
      await for (final chunk in file.read(
        length: want,
        offset: at,
        chunkSize: want,
        maxPendingRequests: 1,
      )) {
        buf.add(chunk);
        if (buf.length >= want) break;
      }
      if (buf.isEmpty) return null;
      return buf.takeBytes();
    } finally {
      gate.releaseReadSlot();
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
  final started = Stopwatch()..start();
  _trace('isolate entered');
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
    _trace('isolate connected in ${started.elapsedMilliseconds}ms');
  } catch (e) {
    _trace('isolate boot failed after ${started.elapsedMilliseconds}ms: $e');
    try {
      boot.send(<String, Object?>{'fatal': _sftpErrorPayload(e)});
    } catch (_) {}
    cmd.close();
    return;
  }

  final files = <int, _WorkerFile>{};
  final uploads = <int, _WorkerUpload>{};
  final gate = _WorkerReadGate();
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
    gate.enterControl();
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      file = await conn.sftp.open(
        m['path'] as String,
        mode: SftpFileOpenMode.read,
      );
      final fallbackTotal = (m['fallbackTotal'] as num?)?.toInt() ?? 0;
      int total = fallbackTotal;
      // 索引里的文件大小几乎总是准的（扫描时写入）；有它就跳过 stat，
      // 让 seek 的 open 少一个 RTT。未知大小才去问服务器。
      if (total <= 0) {
        try {
          total = (await file.stat()).size ?? 0;
        } catch (_) {
          total = 0;
        }
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
        gate: gate,
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
    } finally {
      gate.exitControl();
    }
  }

  Future<void> handleProbe(Map<String, Object?> m) async {
    final id = m['id'] as int;
    SftpFile? file;
    gate.enterControl();
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
      gate.exitControl();
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
      // 续传（truncate=false）保留已落盘内容：主 isolate 会用绝对偏移
      // 覆盖写最后一批，重发相同字节是幂等的。
      var mode = SftpFileOpenMode.write | SftpFileOpenMode.create;
      if (m['truncate'] != false) mode = mode | SftpFileOpenMode.truncate;
      file = await conn.sftp.open(m['path'] as String, mode: mode);
      uploads[id] = _WorkerUpload(file);
      file = null;
      replyOk(id);
    } catch (e) {
      _trace('uploadStart failed truncate=${m['truncate']}: $e');
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
    final offset = (m['offset'] as num?)?.toInt() ?? upload.offset;
    try {
      final bytes = m['bytes'] as Uint8List;
      await upload.file.writeBytes(
        bytes,
        offset: offset,
        chunkSize: _kUploadChunkBytes,
        maxPendingRequests: _kUploadMaxPending,
      );
      upload.offset = offset + bytes.length;
      replyOk(id);
    } catch (e) {
      _trace('uploadChunk failed at $offset: $e');
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
    gate.enterControl();
    try {
      if (closing) throw StateError('SFTP worker 正在关闭');
      final attrs = await conn.sftp.stat(m['path'] as String);
      replyOk(id, <String, Object?>{'isDirectory': attrs.isDirectory});
    } catch (e) {
      replyError(id, e);
    } finally {
      gate.exitControl();
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
