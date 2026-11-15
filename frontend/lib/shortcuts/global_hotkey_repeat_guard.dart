import 'shortcut_models.dart';

/// 系统级全局热键的去抖门（仅不可重复动作）。
///
/// 窗口内快捷键收到的是 Flutter 的 `KeyEvent`，`KeyRepeatEvent` 可以直接
/// 忽略；系统级热键没有这层信息：Windows 的 `RegisterHotKey` 未带
/// `MOD_NOREPEAT`，持键期间每个系统自动重复间隔都会投递一次 `onKeyDown`
/// （hotkey_manager_windows 全部按 `onKeyDown` 上报，也没有 keyUp）。
///
/// 不加门控时，按住「下一首」会在共享播放器上叠发大量 `setUrl`——
/// just_audio 不会中断并发 load，桌面 media_kit 适配层的装载状态是跨 load
/// 共享的，旧曲的迟到事件可以把新曲的装载提前判成功，表现为「UI 切了、
/// 声音还在旧曲」。故对不可重复动作（切歌/播放/模式/收藏等）按时间窗只认
/// 第一次；音量/快进这类可重复动作不拦。
class GlobalHotkeyRepeatGuard {
  GlobalHotkeyRepeatGuard({this.window = const Duration(milliseconds: 250)});

  /// 同一动作的最小触发间隔。
  final Duration window;

  final Map<ShortcutAction, int> _lastAtMs = {};

  /// [action] 本次触发是否放行。[repeatable] 为 true（音量/快进）恒放行。
  /// [nowMs] 仅测试注入，生产走系统时钟。
  bool allow(ShortcutAction action, {required bool repeatable, int? nowMs}) {
    if (repeatable) return true;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = _lastAtMs[action];
    if (last != null && now - last < window.inMilliseconds) return false;
    _lastAtMs[action] = now;
    return true;
  }

  /// 清空记录（热键重新注册/录制开始时调用，避免旧时间窗跨绑定生效）。
  void reset() => _lastAtMs.clear();
}
