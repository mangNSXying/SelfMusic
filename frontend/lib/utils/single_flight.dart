/// 单飞执行：同一时刻只跑一份，期间重复触发登记 dirty，结束后补跑一轮。
library;

import 'dart:async';

class SingleFlight {
  bool _inflight = false;
  bool _dirty = false;

  bool get isRunning => _inflight;

  /// 执行 [body]；已在跑时只标记 dirty，不做并发执行。
  void run(Future<void> Function() body) {
    if (_inflight) {
      _dirty = true;
      return;
    }
    _inflight = true;
    unawaited(() async {
      try {
        await body();
      } finally {
        _inflight = false;
        if (_dirty) {
          _dirty = false;
          run(body);
        }
      }
    }());
  }
}
