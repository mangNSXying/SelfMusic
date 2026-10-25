import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../shortcuts/shortcut_models.dart';

/// 鸿蒙全局快捷键桥（Dart 侧，`selfmusic/global_hotkeys` 通道封装）。
///
/// 与 ArkTS 侧 `GlobalHotkeyBridge.ets` 配对：ArkTS 用
/// `@kit.InputKit` 的 `inputConsumer.on('hotkeyChange')` 订阅系统级组合键，
/// 触发时经同一 MethodChannel 反向调用 `triggered`（参数为
/// [ShortcutAction.name]），Dart 侧再交给 `AppShortcuts` 执行动作。
///
/// 契约：
/// - `register {id,key,preKeys}` → null；`id` 为动作名，`key`/`preKeys` 为
///   鸿蒙 KeyCode（`@ohos.multimodalInput.keyCode`）。注册失败（系统占用
///   `4200002` / 已被其他应用订阅 `4200003` / 不支持 `801`）抛
///   [PlatformException]，调用方记录日志并跳过该绑定。
/// - `unregisterAll {}` → null；取消全部已注册回调。
/// - ArkTS → Dart `triggered <id>`；未知 id 忽略。
///
/// 鸿蒙 `inputConsumer` 的 `preKeys` 仅接受 Ctrl/Shift/Alt（1~4 个），
/// `finalKey` 不能是修饰键或 Meta，因此 [ohosHotkeySpecFor] 会拒绝 Meta
/// 与无法映射的按键。桌面端仍走 `hotkey_manager`，本类只被 `isOhos`
/// 分支使用。
class OhosGlobalHotkeys {
  OhosGlobalHotkeys({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 ArkTS 侧约定的方法通道名。
  static const String channelName = 'selfmusic/global_hotkeys';

  final MethodChannel _channel;
  void Function(ShortcutAction action)? _onTriggered;
  bool _handlerInstalled = false;
  bool _disposed = false;

  /// 装配 ArkTS → Dart 的触发回调；重复调用只更新回调，不重复安装 handler。
  void attach(void Function(ShortcutAction action) onTriggered) {
    if (_disposed) return;
    _onTriggered = onTriggered;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_handleCall);
  }

  /// 注册一个全局组合键；失败向上抛，由调用方按单个绑定降级。
  Future<void> register(ShortcutAction action, OhosHotkeySpec spec) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('register', <String, Object?>{
      'id': action.name,
      'key': spec.keyCode,
      'preKeys': spec.preKeys,
    });
  }

  /// 取消全部注册；重复调用幂等。
  Future<void> unregisterAll() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('unregisterAll');
  }

  /// 解除触发回调并移除通道 handler；随后 [register]/[unregisterAll] 为 no-op。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onTriggered = null;
    if (_handlerInstalled) {
      _handlerInstalled = false;
      _channel.setMethodCallHandler(null);
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'triggered') return null;
    final id = call.arguments;
    if (id is! String) return null;
    for (final action in ShortcutAction.values) {
      if (action.name == id) {
        _onTriggered?.call(action);
        break;
      }
    }
    return null;
  }
}

/// 一个可交给鸿蒙 `inputConsumer` 的组合键：最终键 + 修饰键 KeyCode。
@immutable
class OhosHotkeySpec {
  const OhosHotkeySpec({required this.keyCode, required this.preKeys});

  /// `@ohos.multimodalInput.keyCode.KeyCode` 数值（如 KEYCODE_SPACE=2050）。
  final int keyCode;

  /// `HotkeyOptions.preKeys`：Ctrl/Alt/Shift 的 KeyCode，1~4 个。
  final List<int> preKeys;

  @override
  bool operator ==(Object other) =>
      other is OhosHotkeySpec &&
      other.keyCode == keyCode &&
      listEquals(other.preKeys, preKeys);

  @override
  int get hashCode => Object.hash(keyCode, Object.hashAll(preKeys));
}

// 鸿蒙 KeyCode（@ohos.multimodalInput.keyCode，API 9+）。这里只保留全局
// 快捷键可能用到的键；数值与 SDK d.ts 对齐，Dart 侧无法直接 import ArkTS enum。
const int _ohosCtrlLeft = 2072;
const int _ohosAltLeft = 2045;
const int _ohosShiftLeft = 2047;

/// 把应用内绑定转换为鸿蒙全局组合键；不支持时返回 null。
///
/// 拒绝条件：
/// - 含 Meta（鸿蒙 `finalKey` 明确排除 Meta，`preKeys` 也不支持）；
/// - 没有任何 Ctrl/Alt/Shift 修饰键（`preKeys` 至少 1 个）；
/// - 最终键无法映射到鸿蒙 KeyCode。
OhosHotkeySpec? ohosHotkeySpecFor(ShortcutBinding binding) {
  if (binding.meta) return null;
  final preKeys = <int>[
    if (binding.control) _ohosCtrlLeft,
    if (binding.alt) _ohosAltLeft,
    if (binding.shift) _ohosShiftLeft,
  ];
  if (preKeys.isEmpty) return null;
  final keyCode = _ohosKeyCode(binding.keyId);
  if (keyCode == null) return null;
  return OhosHotkeySpec(keyCode: keyCode, preKeys: preKeys);
}

int? _ohosKeyCode(int keyId) {
  if (keyId >= LogicalKeyboardKey.keyA.keyId &&
      keyId <= LogicalKeyboardKey.keyZ.keyId) {
    return 2017 + (keyId - LogicalKeyboardKey.keyA.keyId);
  }
  if (keyId >= LogicalKeyboardKey.digit0.keyId &&
      keyId <= LogicalKeyboardKey.digit9.keyId) {
    return 2000 + (keyId - LogicalKeyboardKey.digit0.keyId);
  }
  if (keyId >= LogicalKeyboardKey.f1.keyId &&
      keyId <= LogicalKeyboardKey.f12.keyId) {
    return 2090 + (keyId - LogicalKeyboardKey.f1.keyId);
  }
  if (keyId >= LogicalKeyboardKey.numpad0.keyId &&
      keyId <= LogicalKeyboardKey.numpad9.keyId) {
    return 2103 + (keyId - LogicalKeyboardKey.numpad0.keyId);
  }
  return _ohosNamedKeyCodes[keyId];
}

/// 非字母/数字/F 键/小键盘数字的固定映射。
final Map<int, int> _ohosNamedKeyCodes = <int, int>{
  // 空白与控制键。
  LogicalKeyboardKey.space.keyId: 2050, // KEYCODE_SPACE
  LogicalKeyboardKey.tab.keyId: 2049, // KEYCODE_TAB
  LogicalKeyboardKey.enter.keyId: 2054, // KEYCODE_ENTER
  LogicalKeyboardKey.escape.keyId: 2070, // KEYCODE_ESCAPE
  LogicalKeyboardKey.backspace.keyId: 2055, // KEYCODE_DEL
  LogicalKeyboardKey.delete.keyId: 2071, // KEYCODE_FORWARD_DEL
  LogicalKeyboardKey.insert.keyId: 2083, // KEYCODE_INSERT
  LogicalKeyboardKey.home.keyId: 2081, // KEYCODE_MOVE_HOME
  LogicalKeyboardKey.end.keyId: 2082, // KEYCODE_MOVE_END
  LogicalKeyboardKey.pageUp.keyId: 2068, // KEYCODE_PAGE_UP
  LogicalKeyboardKey.pageDown.keyId: 2069, // KEYCODE_PAGE_DOWN
  LogicalKeyboardKey.capsLock.keyId: 2074, // KEYCODE_CAPS_LOCK
  LogicalKeyboardKey.numLock.keyId: 2102, // KEYCODE_NUM_LOCK
  LogicalKeyboardKey.scrollLock.keyId: 2075, // KEYCODE_SCROLL_LOCK
  LogicalKeyboardKey.printScreen.keyId: 2079, // KEYCODE_SYSRQ
  LogicalKeyboardKey.pause.keyId: 2080, // KEYCODE_BREAK
  LogicalKeyboardKey.contextMenu.keyId: 2067, // KEYCODE_MENU

  // 方向键。
  LogicalKeyboardKey.arrowUp.keyId: 2012, // KEYCODE_DPAD_UP
  LogicalKeyboardKey.arrowDown.keyId: 2013, // KEYCODE_DPAD_DOWN
  LogicalKeyboardKey.arrowLeft.keyId: 2014, // KEYCODE_DPAD_LEFT
  LogicalKeyboardKey.arrowRight.keyId: 2015, // KEYCODE_DPAD_RIGHT

  // 标点（含 Shift 后的字符，Shift 作为 preKey 一并发送）。
  LogicalKeyboardKey.comma.keyId: 2043, // KEYCODE_COMMA
  LogicalKeyboardKey.period.keyId: 2044, // KEYCODE_PERIOD
  LogicalKeyboardKey.slash.keyId: 2064, // KEYCODE_SLASH
  LogicalKeyboardKey.semicolon.keyId: 2062, // KEYCODE_SEMICOLON
  LogicalKeyboardKey.equal.keyId: 2058, // KEYCODE_EQUALS
  LogicalKeyboardKey.minus.keyId: 2057, // KEYCODE_MINUS
  LogicalKeyboardKey.backquote.keyId: 2056, // KEYCODE_GRAVE
  LogicalKeyboardKey.bracketLeft.keyId: 2059, // KEYCODE_LEFT_BRACKET
  LogicalKeyboardKey.bracketRight.keyId: 2060, // KEYCODE_RIGHT_BRACKET
  LogicalKeyboardKey.backslash.keyId: 2061, // KEYCODE_BACKSLASH
  LogicalKeyboardKey.quote.keyId: 2063, // KEYCODE_APOSTROPHE
  LogicalKeyboardKey.quoteSingle.keyId: 2063, // KEYCODE_APOSTROPHE
  LogicalKeyboardKey.exclamation.keyId: 2001, // KEYCODE_1
  LogicalKeyboardKey.at.keyId: 2002, // KEYCODE_2
  LogicalKeyboardKey.numberSign.keyId: 2003, // KEYCODE_3
  LogicalKeyboardKey.dollar.keyId: 2004, // KEYCODE_4
  LogicalKeyboardKey.percent.keyId: 2005, // KEYCODE_5
  LogicalKeyboardKey.caret.keyId: 2006, // KEYCODE_6
  LogicalKeyboardKey.ampersand.keyId: 2007, // KEYCODE_7
  LogicalKeyboardKey.asterisk.keyId: 2008, // KEYCODE_8
  LogicalKeyboardKey.parenthesisLeft.keyId: 2009, // KEYCODE_9
  LogicalKeyboardKey.parenthesisRight.keyId: 2000, // KEYCODE_0
  LogicalKeyboardKey.underscore.keyId: 2057, // KEYCODE_MINUS
  LogicalKeyboardKey.add.keyId: 2058, // KEYCODE_EQUALS
  LogicalKeyboardKey.braceLeft.keyId: 2059, // KEYCODE_LEFT_BRACKET
  LogicalKeyboardKey.braceRight.keyId: 2060, // KEYCODE_RIGHT_BRACKET
  LogicalKeyboardKey.bar.keyId: 2061, // KEYCODE_BACKSLASH
  LogicalKeyboardKey.colon.keyId: 2062, // KEYCODE_SEMICOLON
  LogicalKeyboardKey.less.keyId: 2043, // KEYCODE_COMMA
  LogicalKeyboardKey.greater.keyId: 2044, // KEYCODE_PERIOD
  LogicalKeyboardKey.question.keyId: 2064, // KEYCODE_SLASH
  LogicalKeyboardKey.tilde.keyId: 2056, // KEYCODE_GRAVE

  // 小键盘非数字键。
  LogicalKeyboardKey.numpadEnter.keyId: 2119, // KEYCODE_NUMPAD_ENTER
  LogicalKeyboardKey.numpadDivide.keyId: 2113, // KEYCODE_NUMPAD_DIVIDE
  LogicalKeyboardKey.numpadMultiply.keyId: 2114, // KEYCODE_NUMPAD_MULTIPLY
  LogicalKeyboardKey.numpadSubtract.keyId: 2115, // KEYCODE_NUMPAD_SUBTRACT
  LogicalKeyboardKey.numpadAdd.keyId: 2116, // KEYCODE_NUMPAD_ADD
  LogicalKeyboardKey.numpadDecimal.keyId: 2117, // KEYCODE_NUMPAD_DOT
  LogicalKeyboardKey.numpadComma.keyId: 2118, // KEYCODE_NUMPAD_COMMA
  LogicalKeyboardKey.numpadEqual.keyId: 2120, // KEYCODE_NUMPAD_EQUALS

  // 媒体键（部分键可能被系统占用，注册失败按单键降级）。
  LogicalKeyboardKey.mediaPlayPause.keyId: 10, // KEYCODE_MEDIA_PLAY_PAUSE
  LogicalKeyboardKey.mediaStop.keyId: 11, // KEYCODE_MEDIA_STOP
  LogicalKeyboardKey.mediaTrackNext.keyId: 12, // KEYCODE_MEDIA_NEXT
  LogicalKeyboardKey.mediaTrackPrevious.keyId: 13, // KEYCODE_MEDIA_PREVIOUS
  LogicalKeyboardKey.mediaRewind.keyId: 14, // KEYCODE_MEDIA_REWIND
  LogicalKeyboardKey.mediaFastForward.keyId: 15, // KEYCODE_MEDIA_FAST_FORWARD
  LogicalKeyboardKey.mediaPlay.keyId: 2085, // KEYCODE_MEDIA_PLAY
  LogicalKeyboardKey.mediaPause.keyId: 2086, // KEYCODE_MEDIA_PAUSE
  LogicalKeyboardKey.mediaClose.keyId: 2087, // KEYCODE_MEDIA_CLOSE
  LogicalKeyboardKey.mediaRecord.keyId: 2089, // KEYCODE_MEDIA_RECORD
  LogicalKeyboardKey.audioVolumeUp.keyId: 16, // KEYCODE_VOLUME_UP
  LogicalKeyboardKey.audioVolumeDown.keyId: 17, // KEYCODE_VOLUME_DOWN
  LogicalKeyboardKey.audioVolumeMute.keyId: 22, // KEYCODE_VOLUME_MUTE
};
