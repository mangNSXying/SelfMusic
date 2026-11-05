/// 时长格式化（全应用统一入口）。
library;

/// 秒 → `mm:ss`；满 1 小时 → `h:mm:ss`（小时不补零）。
///
/// [empty] 为无有效时长（null / ≤0）时的返回值，默认空串（调用点自行隐藏）。
/// [padMinutes] 为 false 时分钟不补零（候选列表等紧凑文案）。
String formatDuration(int? seconds,
    {String empty = '', bool padMinutes = true}) {
  if (seconds == null || seconds <= 0) return empty;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm =
      padMinutes ? m.toString().padLeft(2, '0') : m.toString();
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// [Duration] 版本（播放进度/总时长）：null / 负值按 `00:00` 展示。
String formatClock(Duration? d) => formatDuration(d?.inSeconds, empty: '00:00');

/// 毫秒 → 时长（向下取整到秒）；0 按 [empty] 展示。
String formatDurationMs(int? ms,
        {String empty = '', bool padMinutes = true}) =>
    formatDuration(ms == null ? null : ms ~/ 1000,
        empty: empty, padMinutes: padMinutes);

/// `HH:mm`（睡眠定时等）。
String formatHourMinute(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

/// `HH:mm`（[DateTime] 版本）。
String formatClockTime(DateTime t) => formatHourMinute(t.hour, t.minute);

/// `HH:mm:ss.SSS`（日志时间戳）。
String formatLogTimestamp(DateTime t) =>
    '${formatHourMinute(t.hour, t.minute)}:'
    '${t.second.toString().padLeft(2, '0')}.'
    '${t.millisecond.toString().padLeft(3, '0')}';
