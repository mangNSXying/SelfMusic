import 'dart:async';
import 'dart:isolate';

import '../../utils/perf_log.dart';
import 'media_proxy_worker.dart';
import 'smb_init_broker.dart';

/// MediaProxy 总开关（默认开启）；应急可用
/// `--dart-define=MEDIA_PROXY=false` 关闭，回落到 DirectAudioSource。
const bool kMediaProxyEnabled =
    bool.fromEnvironment('MEDIA_PROXY', defaultValue: true);

/// 一次 MediaProxy session 的启动结果。
///
/// [permanent] 表示源侧永久不可用（文件不存在/无权限/鉴权失败/指纹失配），
/// 调用方不应重启 isolate 或回退 DirectAudioSource。
class MediaProxyStartResult {
  final Uri? url;
  final bool permanent;
  final String? error;

  const MediaProxyStartResult({this.url, this.permanent = false, this.error});
}

/// 源侧永久不可用（文件已删除、无权限等），重试和字节流回退都不会成功。
class MediaProxyUnavailableException implements Exception {
  final String message;
  const MediaProxyUnavailableException(this.message);

  @override
  String toString() => message;
}

/// UI 侧的 MediaProxy 控制端：管理独立 isolate、session URL 与生命周期。
///
/// 音频字节完全不经过本 isolate；这里只收 worker 日志和 start/stop 回执。
class MediaProxyClient {
  Isolate? _isolate;
  SendPort? _cmd;
  ReceivePort? _events;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _starting;
  String? _activeToken;

  bool get hasSession => _activeToken != null;

  /// 启动一个 session，返回 native player 可直接打开的 loopback URL。
  /// [MediaProxyStartResult.permanent] 为 true 时调用方不应重试或回退。
  Future<MediaProxyStartResult> start(Map<String, Object?> config,
      {required String basename}) async {
    if (_closed || !kMediaProxyEnabled) {
      return const MediaProxyStartResult(error: 'MediaProxy 已关闭');
    }
    final cmd = await _ensureStarted();
    if (cmd == null) {
      return const MediaProxyStartResult(error: 'MediaProxy isolate 不可用');
    }
    final cfg = Map<String, Object?>.from(config);
    if (cfg['kind'] == 'smb') {
      await SmbInitBroker.ensureStarted();
      final broker = SmbInitBroker.port;
      perfLog('mediaProxy.smbBroker',
          broker == null ? 'unavailable' : 'ok');
      if (broker != null) cfg['smbBrokerPort'] = broker;
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final sw = Stopwatch()..start();
    perfLog('mediaProxy.start',
        'kind=${cfg['kind']} key=${cfg['sourceKey']} size=${cfg['size']}');
    cmd.send({
      'op': 'start',
      'id': id,
      'config': cfg,
      'basename': basename,
    });
    try {
      final resp = await completer.future.timeout(const Duration(seconds: 40));
      if (resp['ok'] != true) {
        final permanent = resp['permanent'] == true;
        final error = resp['error'] as String?;
        perfLog('mediaProxy.startFail',
            'kind=${cfg['kind']} key=${cfg['sourceKey']} ms=${sw.elapsedMilliseconds} permanent=$permanent err=$error');
        return MediaProxyStartResult(permanent: permanent, error: error);
      }
      final token = resp['token'] as String?;
      final port = resp['port'];
      if (token == null || port is! int) {
        perfLog('mediaProxy.startBadReply', '$resp');
        return const MediaProxyStartResult(error: 'MediaProxy 回执缺少 URL');
      }
      _activeToken = token;
      perfLog('mediaProxy.startOk',
          'kind=${cfg['kind']} key=${cfg['sourceKey']} port=$port total=${resp['total']} ms=${sw.elapsedMilliseconds}');
      return MediaProxyStartResult(
        url: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: port,
          pathSegments: ['media', token, basename],
        ),
      );
    } on TimeoutException {
      perfLog('mediaProxy.startTimeout',
          'kind=${cfg['kind']} key=${cfg['sourceKey']} ms=${sw.elapsedMilliseconds}');
      // 让 worker 放弃在途 start（消息顺序保证 start 收尾后处理 stop）。
      _cmd?.send({'op': 'stop'});
      return const MediaProxyStartResult(error: 'MediaProxy 启动超时');
    } catch (e) {
      perfLog('mediaProxy.startError', e);
      return MediaProxyStartResult(error: '$e');
    } finally {
      _pending.remove(id);
    }
  }

  /// 停掉当前 session（换曲/停止/退出）。不等待 worker 回执，消息有序即可。
  Future<void> stop() async {
    _activeToken = null;
    _cmd?.send({'op': 'stop'});
    perfLog('mediaProxy.stop');
  }

  /// isolate 崩溃/握手失败后的重启；下一次 start 会自动重新 spawn。
  Future<void> restart() async {
    perfLog('mediaProxy.restart');
    await _disposeIsolate();
  }

  Future<void> close() async {
    _closed = true;
    await _disposeIsolate();
  }

  Future<void> _disposeIsolate() async {
    final cmd = _cmd;
    _cmd = null;
    _activeToken = null;
    if (cmd != null) {
      cmd.send({'op': 'shutdown'});
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _events?.close();
    _events = null;
    _failPending(StateError('MediaProxy closed'));
    perfLog('mediaProxy.isolate.closed');
  }

  Future<SendPort?> _ensureStarted() async {
    if (_closed) return null;
    final cur = _cmd;
    if (cur != null) return cur;
    final starting = _starting;
    if (starting != null) {
      await starting;
      return _cmd;
    }
    final f = _startIsolate();
    _starting = f;
    try {
      await f;
    } finally {
      if (identical(_starting, f)) _starting = null;
    }
    return _cmd;
  }

  Future<void> _startIsolate() async {
    final ready = ReceivePort();
    final events = ReceivePort();
    try {
      final iso = await Isolate.spawn(
        mediaProxyIsolateEntry,
        [ready.sendPort, events.sendPort],
        debugName: 'selfmusic-media-proxy',
      );
      _isolate = iso;
      _events = events;
      events.listen(
        _onEvent,
        onError: (Object e, StackTrace st) {
          perfLog('mediaProxy.eventError', e);
        },
        onDone: _resetIsolate,
      );
      iso.addOnExitListener(events.sendPort, response: {'op': 'exit'});
      final port = await ready.first.timeout(const Duration(seconds: 10));
      if (port is SendPort) {
        _cmd = port;
        perfLog('mediaProxy.isolate.ready');
      } else {
        perfLog('mediaProxy.isolate.badHandshake', '$port');
      }
    } catch (e) {
      perfLog('mediaProxy.isolate.startFail', e);
      _isolate?.kill(priority: Isolate.immediate);
      _resetIsolate();
    } finally {
      ready.close();
    }
  }

  void _onEvent(Object? msg) {
    if (msg is! Map) return;
    switch (msg['op']) {
      case 'log':
        perfLog('mediaProxy.worker', msg['line']);
        return;
      case 'exit':
        _resetIsolate();
        return;
    }
    final id = msg['id'];
    if (id is int) {
      _pending.remove(id)?.complete(msg.cast<String, Object?>());
    }
  }

  void _resetIsolate() {
    final wasRunning = _cmd != null || _isolate != null;
    _cmd = null;
    _isolate = null;
    _activeToken = null;
    _events?.close();
    _events = null;
    _failPending(StateError('MediaProxy isolate exited'));
    if (wasRunning) perfLog('mediaProxy.isolate.reset');
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }
}
