import 'dart:async';
import 'dart:isolate';

/// 扫描进度事件（worker → 主 isolate）。
class ScanProgress {
  /// 已处理（探测）数量；[listing] 阶段为 0。
  final int done;

  /// 本阶段总数；未知（列表阶段）为 0。
  final int total;

  /// 是否仍在枚举（本地目录 / PROPFIND 树），探测尚未开始。
  final bool listing;
  const ScanProgress({required this.done, required this.total, this.listing = false});

  /// 进度比例；枚举阶段或未知总量时 null（UI 转不确定态）。
  double? get value => listing || total <= 0 ? null : done / total;
}

/// 取消令牌：主 isolate 持有，`cancel()` 后把信号转发给扫描 worker。
class ScanToken {
  final ReceivePort _wire = ReceivePort();
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    try {
      _wire.sendPort.send(null);
    } catch (_) {}
  }

  /// 主 isolate 侧收到的底层事件（供 runScan 转发到 worker）。
  Stream get events => _wire;

  void close() => _wire.close();
}

/// 在独立 [Isolate.spawn] 中运行 [entry]，支持流式进度上报与取消。
///
/// [entry] 收到 `Map<String, Object?>`，含 `params`（调用方参数）、`send`（SendPort，
/// 结果）、`progress`（SendPort，进度）。worker 契约：
/// 1. 先向 `send` 回发握手 `{'__cancel__': SendPort}`（worker 的取消监听口）；
/// 2. 探测期间可向 `progress` 发 [ScanProgress]；
/// 3. 结束向 `send` 发最终结果 `R`。
///
/// 主 isolate 在握手后把 [ScanToken] 的取消事件转发到 worker；扫描超时抛
/// [TimeoutException]。worker 结束或超时后必定 kill，不留孤儿 isolate。
Future<R> runScan<R>({
  required void Function(Map<String, Object?> msg) entry,
  required Map<String, Object?> params,
  ScanToken? token,
  void Function(ScanProgress)? onProgress,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final resultPort = ReceivePort();
  final progressPort = ReceivePort();
  final isolate = await Isolate.spawn(entry, <String, Object?>{
    'params': params,
    'send': resultPort.sendPort,
    'progress': progressPort.sendPort,
  });

  SendPort? workerCancel;
  final done = Completer<(bool, Object?)>();
  resultPort.listen((msg) {
    if (msg is Map && msg['__cancel__'] is SendPort) {
      workerCancel = msg['__cancel__'] as SendPort;
      if (token != null && token.cancelled) {
        // 握手前已取消：立即转发。
        try {
          workerCancel!.send(null);
        } catch (_) {}
      }
      return;
    }
    if (!done.isCompleted) done.complete((true, msg));
  });

  StreamSubscription<dynamic>? tokenSub;
  if (token != null) {
    tokenSub = token.events.listen((_) {
      final wc = workerCancel;
      if (wc != null) {
        try {
          wc.send(null);
        } catch (_) {}
      }
    });
  }

  final progressSub = progressPort.listen((p) {
    if (p is ScanProgress && onProgress != null) onProgress(p);
  });

  try {
    final res = await done.future.timeout(timeout);
    return res.$2 as R;
  } finally {
    await tokenSub?.cancel();
    await progressSub.cancel();
    resultPort.close();
    progressPort.close();
    token?.close();
    isolate.kill(priority: Isolate.immediate);
  }
}