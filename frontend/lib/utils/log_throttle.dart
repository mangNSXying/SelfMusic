/// 日志节流：抑制同因/高频重复的 debug/perf 输出。
library;

class LogThrottle {
  /// [window] 为时间窗；[sameReasonOnly] 为 true 时只按「原因是否与上次相同」
  /// 去重（成功路径需调用 [reset]），否则窗口内任意原因都只放行一条。
  LogThrottle({
    this.window = const Duration(seconds: 60),
    this.sameReasonOnly = false,
  });

  final Duration window;
  final bool sameReasonOnly;

  String? _lastReason;
  DateTime? _lastAt;

  /// 返回 true 表示本次应当输出日志。
  bool shouldLog(String reason) {
    if (sameReasonOnly) {
      if (_lastReason == reason) return false;
      _lastReason = reason;
      return true;
    }
    final now = DateTime.now();
    final last = _lastAt;
    if (last != null && now.difference(last) < window) return false;
    _lastAt = now;
    _lastReason = reason;
    return true;
  }

  /// 成功后重置（下一次同因仍会输出）。
  void reset() {
    _lastReason = null;
    _lastAt = null;
  }
}
