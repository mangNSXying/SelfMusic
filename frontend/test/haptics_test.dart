import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/haptics.dart';

class _FakeHapticsPlatform extends HapticsPlatform {
  _FakeHapticsPlatform({this.motor = true});

  final bool motor;
  final calls = <({int durationMs, int? amplitude})>[];

  @override
  bool get isMobile => true;

  @override
  Future<bool> hasVibrator() async => motor;

  @override
  Future<bool> vibrate({required int durationMs, int? amplitude}) async {
    calls.add((durationMs: durationMs, amplitude: amplitude));
    return motor;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.shamiko.selfmusic/vibration');
  final calls = <MethodCall>[];

  void mockChannel(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    calls.clear();
    Haptics.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    Haptics.debugReset();
  });

  group('ChannelHapticsPlatform', () {
    test('vibrate 参数透传并返回原生结果', () async {
      mockChannel((call) async {
        calls.add(call);
        return true;
      });

      final ok = await const ChannelHapticsPlatform(channel)
          .vibrate(durationMs: 10, amplitude: 110);

      expect(ok, isTrue);
      expect(calls.single.method, 'vibrate');
      expect(calls.single.arguments, {'durationMs': 10, 'amplitude': 110});
    });

    test('amplitude 缺省时不传该键', () async {
      mockChannel((call) async {
        calls.add(call);
        return true;
      });

      await const ChannelHapticsPlatform(channel).vibrate(durationMs: 5);

      expect(calls.single.arguments, {'durationMs': 5});
    });

    test('PlatformException → false，不向业务层抛', () async {
      mockChannel((call) async {
        throw PlatformException(code: 'boom');
      });

      expect(
        await const ChannelHapticsPlatform(channel).vibrate(durationMs: 10),
        isFalse,
      );
    });

    test('MissingPluginException → false，不向业务层抛', () async {
      mockChannel((call) async {
        throw MissingPluginException('no impl');
      });

      expect(await const ChannelHapticsPlatform(channel).hasVibrator(), isFalse);
    });

    test('hasVibrator 返回原生布尔值', () async {
      mockChannel((call) async => true);
      expect(await const ChannelHapticsPlatform(channel).hasVibrator(), isTrue);
      mockChannel((call) async => false);
      expect(await const ChannelHapticsPlatform(channel).hasVibrator(), isFalse);
    });
  });

  group('Haptics 门控', () {
    test('桌面（无通道平台）：capable=false，探测后 fire 不触发', () async {
      // 测试宿主为 Linux，forCurrentPlatform 返回 Noop。
      expect(Haptics.capable, isFalse);
      await Haptics.probe();
      expect(Haptics.hasVibrator, isFalse);
      Haptics.fire(HapticStrength.light);
    });

    test('开关关闭时 fire 静默', () async {
      final fake = _FakeHapticsPlatform();
      Haptics.debugReset(platform: fake, enabled: false);
      await Haptics.probe();

      Haptics.fire(HapticStrength.light);

      expect(fake.calls, isEmpty);
    });

    test('探测到无马达后 fire 静默', () async {
      final fake = _FakeHapticsPlatform(motor: false);
      Haptics.debugReset(platform: fake);
      await Haptics.probe();

      Haptics.fire(HapticStrength.light);

      expect(fake.calls, isEmpty);
    });

    test('三档强度映射：selection / light / medium', () async {
      final fake = _FakeHapticsPlatform();
      Haptics.debugReset(platform: fake);
      await Haptics.probe();

      Haptics.fire(HapticStrength.selection);
      Haptics.fire(HapticStrength.light);
      Haptics.fire(HapticStrength.medium);

      expect(fake.calls, [
        (durationMs: 5, amplitude: 60),
        (durationMs: 10, amplitude: 110),
        (durationMs: 20, amplitude: 180),
      ]);
    });
  });
}
