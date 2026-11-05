/// 退避与 Retry-After 解析（纯函数）。
library;

/// `Retry-After` 秒值 → Duration；缺失/非法/负数返回 null。
Duration? parseRetryAfter(String? raw) {
  final sec = int.tryParse((raw ?? '').trim());
  if (sec == null || sec < 0) return null;
  return Duration(seconds: sec);
}

/// 指数退避：`base * 2^attempt`，超过 [cap] 取 [cap]。
Duration exponentialBackoff(
  int attempt, {
  Duration base = const Duration(seconds: 1),
  Duration cap = const Duration(seconds: 30),
}) {
  final shift = attempt.clamp(0, 30);
  final value = base * (1 << shift);
  return value > cap ? cap : value;
}
