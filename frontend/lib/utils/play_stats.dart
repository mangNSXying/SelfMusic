/// 播放统计口径（改进.txt：播放时长精确到秒，播放次数由播放时长派生）。
///
/// 只存累计播放秒数 `play_sec`，播放次数不落库：
/// 次数 = 累计播放秒数 ÷ 歌曲时长，保留 1 位小数。
/// 好处：拖进度条/后台续播/重播都只影响时长，次数口径始终自洽；
/// 歌曲时长后续被改写时，次数会跟着重算，不会留下脏的绝对次数。

library;

/// 累计播放时长（秒）→ 播放次数（1 位小数）。
///
/// [durationSec] 为歌曲时长（秒）；未知/非正 → 0.0（不显示次数）。
double playCountOf(int playSec, int? durationSec) {
  if (playSec <= 0) return 0;
  if (durationSec == null || durationSec <= 0) return 0;
  final v = playSec / durationSec;
  return (v * 10).round() / 10;
}

/// 累计播放时长（秒）→ 人类可读时长（`12 小时 03 分` / `3 分 05 秒` / `42 秒`）。
String playSecLabel(int playSec) {
  if (playSec <= 0) return '0 秒';
  final h = playSec ~/ 3600;
  final m = (playSec % 3600) ~/ 60;
  final s = playSec % 60;
  if (h > 0) return m > 0 ? '$h 小时 $m 分' : '$h 小时';
  if (m > 0) return s > 0 ? '$m 分 $s 秒' : '$m 分';
  return '$s 秒';
}

/// 播放次数展示（1 位小数，整数不带小数点）。
String playCountLabel(int playSec, int? durationSec) {
  final c = playCountOf(playSec, durationSec);
  if (c <= 0) return '0 次';
  return c == c.roundToDouble() ? '${c.round()} 次' : '$c 次';
}

/// 位置流播放中约 200ms 一次 tick。超过该间隔说明采集断档（设备休眠、进程被
/// 系统挂起/冻结、主线程长时间阻塞）：这段时间的挂钟不可信——设备睡着时
/// 声音早就停了，定时器也停了，整段挂起时间不能算成播放。
const Duration kPlaySecMaxTickGap = Duration(seconds: 5);

/// 挂钟窗口结算：把 [window]→[now] 的整秒数取出，余下不足 1 秒的零头留在窗口里。
///
/// 播放时长必须按挂钟计（后台/息屏时 just_audio 仍在推进，位置流可能被节流），
/// 所以窗口只前进「已整秒」部分，避免逐秒取整累计的漂移。
///
/// 采集断档（间隔 > [kPlaySecMaxTickGap]）时改用媒体位置前进量兜底：只有
/// `position - lastPosition` 证明真的播了多久，才计入多久；位置没前进就整段
/// 丢弃（窗口重挂到 [now]），避免一次挂起把几小时灌进某首歌的累计时长。
({int sec, DateTime window}) settlePlaySecWindow(
  DateTime window,
  DateTime now, {
  Duration? position,
  Duration? lastPosition,
}) {
  final elapsed = now.difference(window);
  if (elapsed.inSeconds <= 0) return (sec: 0, window: window);
  if (elapsed <= kPlaySecMaxTickGap) {
    final whole = elapsed.inSeconds;
    return (sec: whole, window: window.add(Duration(seconds: whole)));
  }
  var sec = 0;
  if (position != null && lastPosition != null) {
    final advanced = (position - lastPosition).inSeconds;
    if (advanced > 0) {
      sec = advanced < elapsed.inSeconds ? advanced : elapsed.inSeconds;
    }
  }
  return (sec: sec, window: now);
}
