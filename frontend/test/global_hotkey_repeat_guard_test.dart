import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/shortcuts/global_hotkey_repeat_guard.dart';
import 'package:selfmusic/shortcuts/shortcut_models.dart';

/// 全局热键去抖：Windows `RegisterHotKey` 未带 MOD_NOREPEAT，持键时
/// WM_HOTKEY 会按系统重复频率连续投递 onKeyDown，且全局路径没有 KeyRepeat
/// 事件可过滤。不可重复动作（切歌等）必须在时间窗内只认第一次。
void main() {
  test('不可重复动作：窗口内重复触发被吞掉，窗口外恢复', () {
    final guard = GlobalHotkeyRepeatGuard(window: const Duration(milliseconds: 250));
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1000),
        isTrue);
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1030),
        isFalse);
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1249),
        isFalse);
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1250),
        isTrue);
  });

  test('可重复动作（音量/快进）不受窗口限制', () {
    final guard = GlobalHotkeyRepeatGuard();
    for (var i = 0; i < 5; i++) {
      expect(
        guard.allow(ShortcutAction.volumeUp, repeatable: true, nowMs: 1000 + i),
        isTrue,
      );
    }
  });

  test('不同动作各自计时，互不影响', () {
    final guard = GlobalHotkeyRepeatGuard();
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1000),
        isTrue);
    expect(guard.allow(ShortcutAction.previous, repeatable: false, nowMs: 1001),
        isTrue);
    expect(guard.allow(ShortcutAction.next, repeatable: false, nowMs: 1002),
        isFalse);
  });

  test('reset 后立即放行（热键重新注册/录制开始）', () {
    final guard = GlobalHotkeyRepeatGuard();
    expect(guard.allow(ShortcutAction.playPause, repeatable: false, nowMs: 0),
        isTrue);
    expect(guard.allow(ShortcutAction.playPause, repeatable: false, nowMs: 10),
        isFalse);
    guard.reset();
    expect(guard.allow(ShortcutAction.playPause, repeatable: false, nowMs: 20),
        isTrue);
  });
}
