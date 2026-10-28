import 'dart:async';
import 'dart:isolate';

import '../../utils/perf_log.dart';

/// 进程内 SMB 初始化租约。
///
/// libsmb2 的全局 `active_contexts` 没有内部锁，多个 isolate 同时
/// `smb2_init_context` 会竞争。本 broker 用一个独立 isolate 做串行闸门：
/// 调用方先 acquire，再执行 `Smb2Pool.connect` / `Smb2Client.connect`，
/// 完成后 release。它只覆盖「建连」，不覆盖读写。
///
/// UI isolate 用 [ensureStarted] + [run]；代理 isolate 由 UI 把 [port]
/// 传进去，用 [runWithPort]，保证与 UI 的扫描/元数据连接共用同一把锁。
class SmbInitBroker {
  static SendPort? _port;
  static Future<void>? _starting;
  static ReceivePort? _exitPort;

  static SendPort? get port => _port;

  static Future<void> ensureStarted() {
    final cur = _port;
    if (cur != null) return Future<void>.value();
    final starting = _starting;
    if (starting != null) return starting;
    final f = _start();
    _starting = f;
    return f.whenComplete(() {
      if (identical(_starting, f)) _starting = null;
    });
  }

  static Future<void> _start() async {
    final ready = ReceivePort();
    try {
      final iso = await Isolate.spawn(
        _brokerEntry,
        ready.sendPort,
        debugName: 'selfmusic-smb-init-broker',
      );
      final exit = ReceivePort();
      _exitPort?.close();
      _exitPort = exit;
      iso.addOnExitListener(exit.sendPort);
      exit.listen((_) {
        _port = null;
        perfLog('smbInitBroker.exit');
      });
      final p = await ready.first.timeout(const Duration(seconds: 5));
      if (p is SendPort) {
        _port = p;
        perfLog('smbInitBroker.ready');
      }
    } catch (e) {
      perfLog('smbInitBroker.startFail', '$e');
    } finally {
      ready.close();
    }
  }

  /// UI isolate 的便捷入口：自动确保 broker 已启动。
  static Future<T> run<T>(Future<T> Function() action) async {
    await ensureStarted();
    final p = _port;
    if (p == null) {
      perfLog('smbInitBroker.unavailable', '直接建连（竞争窗口）');
      return action();
    }
    return runWithPort(p, action);
  }

  /// 代理/扫描 isolate 入口：使用 UI 传进来的 broker SendPort。
  static Future<T> runWithPort<T>(
      SendPort broker, Future<T> Function() action) async {
    final sw = Stopwatch()..start();
    final rp = ReceivePort();
    try {
      broker.send({'op': 'acquire', 'port': rp.sendPort});
      final granted = await rp.first.timeout(
        const Duration(seconds: 30),
        onTimeout: () => false,
      );
      final waited = sw.elapsedMilliseconds;
      if (granted != true) {
        perfLog('smbInitBroker.timeout', 'waited=${waited}ms');
        // 宁可冒一次竞争，也不能让建连永久挂住。
        return await action();
      }
      if (waited >= 200) {
        perfLog('smbInitBroker.acquired', 'waited=${waited}ms');
      }
      try {
        return await action();
      } finally {
        broker.send({'op': 'release'});
      }
    } finally {
      rp.close();
    }
  }
}

void _brokerEntry(SendPort ready) {
  final rp = ReceivePort();
  ready.send(rp.sendPort);
  var busy = false;
  Timer? lease;
  final queue = <SendPort>[];
  late void Function() grantNext;

  void armLease() {
    lease?.cancel();
    // 持有者 isolate 在 connect 中途被杀时不会发 release：租约兜底，
    // 避免 broker 永久 busy 让后续 SMB 初始化每次白等 30s。
    lease = Timer(const Duration(seconds: 90), () => grantNext());
  }

  grantNext = () {
    lease?.cancel();
    lease = null;
    if (queue.isNotEmpty) {
      final next = queue.removeAt(0);
      busy = true;
      next.send(true);
      armLease();
    } else {
      busy = false;
    }
  };

  rp.listen((msg) {
    if (msg is! Map) return;
    switch (msg['op']) {
      case 'acquire':
        final p = msg['port'];
        if (p is! SendPort) return;
        if (!busy) {
          busy = true;
          p.send(true);
          armLease();
        } else {
          queue.add(p);
        }
        break;
      case 'release':
        grantNext();
        break;
    }
  });
}
