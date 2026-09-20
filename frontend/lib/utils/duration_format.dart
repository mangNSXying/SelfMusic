/// 时长格式化（全应用统一入口）。
library;

/// 秒 → `mm:ss`；满 1 小时 → `h:mm:ss`（小时不补零）。
///
/// [empty] 为无有效时长（null / ≤0）时的返回值，默认空串（调用点自行隐藏）。
String formatDuration(int? seconds, {String empty = ''}) {
  if (seconds == null || seconds <= 0) return empty;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// [Duration] 版本（播放进度/总时长）：null / 负值按 `00:00` 展示。
String formatClock(Duration? d) => formatDuration(d?.inSeconds, empty: '00:00');
