import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/platform/harmonyos/ohos_global_hotkeys.dart';
import 'package:selfmusic/shortcuts/shortcut_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('鸿蒙全局键映射', () {
    test('默认全局绑定映射为 Ctrl+Alt + 对应 KeyCode', () {
      final global = defaultGlobalBindings(primaryIsMeta: false);
      final playPause = ohosHotkeySpecFor(global[ShortcutAction.playPause]!);
      final previous = ohosHotkeySpecFor(global[ShortcutAction.previous]!);
      final next = ohosHotkeySpecFor(global[ShortcutAction.next]!);
      final favorite =
          ohosHotkeySpecFor(global[ShortcutAction.toggleFavorite]!);

      expect(playPause!.keyCode, 2050); // KEYCODE_SPACE
      expect(playPause.preKeys, [2072, 2045]); // Ctrl + Alt
      expect(previous!.keyCode, 2014); // KEYCODE_DPAD_LEFT
      expect(next!.keyCode, 2015); // KEYCODE_DPAD_RIGHT
      expect(favorite!.keyCode, 2028); // KEYCODE_L
      expect(favorite.preKeys, [2072, 2045]);
    });

    test('字母、数字、功能键与小键盘数字按区间映射', () {
      OhosHotkeySpec? spec(LogicalKeyboardKey key, {bool control = true}) =>
          ohosHotkeySpecFor(
              ShortcutBinding(keyId: key.keyId, control: control));

      expect(spec(LogicalKeyboardKey.keyA)!.keyCode, 2017);
      expect(spec(LogicalKeyboardKey.keyZ)!.keyCode, 2042);
      expect(spec(LogicalKeyboardKey.digit0)!.keyCode, 2000);
      expect(spec(LogicalKeyboardKey.digit9)!.keyCode, 2009);
      expect(spec(LogicalKeyboardKey.f1)!.keyCode, 2090);
      expect(spec(LogicalKeyboardKey.f12)!.keyCode, 2101);
      expect(spec(LogicalKeyboardKey.numpad0)!.keyCode, 2103);
      expect(spec(LogicalKeyboardKey.numpad9)!.keyCode, 2112);
    });

    test('Shift 后标点映射到基础键并保留 Shift 修饰键', () {
      final spec = ohosHotkeySpecFor(ShortcutBinding(
        keyId: LogicalKeyboardKey.exclamation.keyId,
        control: true,
        shift: true,
      ));
      expect(spec!.keyCode, 2001); // KEYCODE_1
      expect(spec.preKeys, [2072, 2047]); // Ctrl + Shift
    });

    test('Meta、无修饰键与未映射键被拒绝', () {
      expect(
        ohosHotkeySpecFor(ShortcutBinding(
          keyId: LogicalKeyboardKey.keyL.keyId,
          meta: true,
        )),
        isNull,
      );
      expect(
        ohosHotkeySpecFor(
            ShortcutBinding(keyId: LogicalKeyboardKey.keyL.keyId)),
        isNull,
      );
      expect(
        ohosHotkeySpecFor(ShortcutBinding(
          keyId: LogicalKeyboardKey.launchMail.keyId,
          control: true,
        )),
        isNull,
      );
    });
  });

  group('OhosGlobalHotkeys 通道', () {
    const channel = MethodChannel(OhosGlobalHotkeys.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    late OhosGlobalHotkeys bridge;

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      bridge = OhosGlobalHotkeys(channel: channel);
    });

    tearDown(() {
      bridge.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('register 发送动作名、KeyCode 与修饰键', () async {
      await bridge.register(
        ShortcutAction.playPause,
        const OhosHotkeySpec(keyCode: 2050, preKeys: [2072, 2045]),
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'register');
      expect(calls.single.arguments, <String, Object?>{
        'id': 'playPause',
        'key': 2050,
        'preKeys': <int>[2072, 2045],
      });
    });

    test('triggered 事件分发到对应动作', () async {
      ShortcutAction? received;
      bridge.attach((action) => received = action);
      await messenger.handlePlatformMessage(
        OhosGlobalHotkeys.channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('triggered', 'next')),
        (_) {},
      );
      expect(received, ShortcutAction.next);
    });

    test('未知 triggered id 被忽略', () async {
      var count = 0;
      bridge.attach((_) => count++);
      await messenger.handlePlatformMessage(
        OhosGlobalHotkeys.channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('triggered', 'not-an-action')),
        (_) {},
      );
      expect(count, 0);
    });

    test('unregisterAll 调用通道方法', () async {
      await bridge.unregisterAll();
      expect(calls.single.method, 'unregisterAll');
    });
  });
}
