import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/platform/harmonyos/ohos_platform_bridge.dart';

/// `makeCoverThumb` 桥封装的 mock 通道用例（ohos-thumb-native-decode feature）。
///
/// 本仓库首次引入 `TestDefaultBinaryMessenger.setMockMethodCallHandler` 模式：
/// 宿主（Windows）的 `Platform.operatingSystem` 恒非 'ohos'，桥封装是纯静态
/// 方法不判平台，可在任意宿主直测——mock 通道回 true/false/PlatformException/
/// MissingPluginException/超时五类场景，断言参数透传与「任何失败 → false 不
/// 抛出」的兜底语义（plan.md R-5：调用方零 try/catch 负担）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('selfmusic/platform');

  /// mock 侧收到的调用记录（方法名 + 参数透传断言用）。
  final calls = <MethodCall>[];

  void mockChannel(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    calls.clear();
    // 目录激活缓存是进程级静态状态：逐用例清空，避免相互影响。
    OhosPlatformBridge.debugResetDirectoryActivation();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('方法名与参数透传：srcPath/thumbPath/maxEdge/quality 原样过通道', () async {
    mockChannel((call) async {
      calls.add(call);
      return true;
    });

    final ok = await OhosPlatformBridge.makeCoverThumb(
        '/covers/abc.jpg', '/covers/abc.thumb.jpg',
        maxEdge: 512, quality: 90);

    expect(ok, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'makeCoverThumb');
    expect(calls.single.arguments, <String, Object?>{
      'srcPath': '/covers/abc.jpg',
      'thumbPath': '/covers/abc.thumb.jpg',
      'maxEdge': 512,
      'quality': 90,
    });
  });

  test('缺省参数透传：maxEdge=768 / quality=82（与 kCoverThumb* 常量对齐）', () async {
    mockChannel((call) async {
      calls.add(call);
      return true;
    });

    final ok = await OhosPlatformBridge.makeCoverThumb(
        '/covers/x.jpg', '/covers/x.thumb.jpg');

    expect(ok, isTrue);
    expect(calls.single.arguments, <String, Object?>{
      'srcPath': '/covers/x.jpg',
      'thumbPath': '/covers/x.thumb.jpg',
      'maxEdge': 768,
      'quality': 82,
    });
  });

  test('true 直通：原生生成成功 → 返回 true', () async {
    mockChannel((call) async => true);

    final ok =
        await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');

    expect(ok, isTrue);
  });

  test('false 直通：原生生成失败（不可解码/写盘失败）→ 返回 false', () async {
    mockChannel((call) async => false);

    final ok =
        await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');

    expect(ok, isFalse);
  });

  test('PlatformException → false：debugPrint 诊断后兜底，不向上抛', () async {
    mockChannel((call) async {
      throw PlatformException(code: '500', message: '图像解码服务异常');
    });

    final ok =
        await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');

    expect(ok, isFalse);
  });

  test('MissingPluginException（桥未装配/旧原生包）→ false，不向上抛', () async {
    // mock 侧显式抛 MissingPluginException 时 test messenger 回 null 应答，
    // invokeMethod 按未注册通道语义重抛——确定性模拟「原生包没有该方法」。
    mockChannel((call) async {
      throw MissingPluginException();
    });

    final ok =
        await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');

    expect(ok, isFalse);
  });

  test('超时（注入短超时，原生迟迟不回包）→ false，不向上抛', () async {
    // 永不完成的应答模拟系统图像服务卡死：唯一出口是 Dart 侧超时包装。
    final never = Completer<Object?>();
    mockChannel((call) => never.future);

    final ok = await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg',
        timeout: const Duration(milliseconds: 30));

    expect(ok, isFalse);
  });

  group('返回值解析兼容（ohos-thumb-taskpool T004）', () {
    test('旧 bool 形态：makeCoverThumbDetailed 解析 ok 且无结构化字段', () async {
      mockChannel((call) async => true);

      final r = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg');

      expect(r.ok, isTrue);
      expect(r.costMs, isNull);
      expect(r.degraded, isNull);
      expect(r.timeout, isFalse);
    });

    test('新结构化形态 {ok,costMs,degraded}：ok/costMs/degraded 全部解析', () async {
      mockChannel((call) async => <String, Object?>{
            'ok': true,
            'costMs': 42,
            'degraded': 'worker',
          });

      final ok =
          await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');
      expect(ok, isTrue);

      final r = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg');
      expect(r.ok, isTrue);
      expect(r.costMs, 42);
      expect(r.degraded, 'worker');
    });

    test('新结构化形态 ok=false：成功语义为 false（不再视为成功）', () async {
      mockChannel((call) async => <String, Object?>{
            'ok': false,
            'costMs': 7,
            'degraded': '',
          });

      final ok =
          await OhosPlatformBridge.makeCoverThumb('/a.jpg', '/a.thumb.jpg');
      expect(ok, isFalse);
      final r = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg');
      expect(r.ok, isFalse);
      expect(r.costMs, 7);
      expect(r.degraded, isNull); // 空字符串降级标记归一为 null。
    });

    test('未知/null 形态：按失败处理，不向上抛', () async {
      mockChannel((call) async => null);
      final r = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg');
      expect(r.ok, isFalse);
    });

    test('异常与超时的结构化结果：timeout 标记可区分', () async {
      mockChannel((call) async {
        throw PlatformException(code: '500', message: 'boom');
      });
      final err = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg');
      expect(err.ok, isFalse);
      expect(err.timeout, isFalse);

      final never = Completer<Object?>();
      mockChannel((call) => never.future);
      final to = await OhosPlatformBridge.makeCoverThumbDetailed(
          '/a.jpg', '/a.thumb.jpg',
          timeout: const Duration(milliseconds: 20));
      expect(to.ok, isFalse);
      expect(to.timeout, isTrue);
    });
  });

  group('目录持久化授权激活（重启后播放修复）', () {
    test('成功后进程内缓存：重复调用只触发一次 activateDirectory', () async {
      mockChannel((call) async {
        calls.add(call);
        return null;
      });

      const uri = 'file://docs/storage/Users/currentUser/Music';
      expect(await OhosPlatformBridge.ensureDirectoryActivated(uri), isTrue);
      expect(await OhosPlatformBridge.ensureDirectoryActivated(uri), isTrue);

      final activates =
          calls.where((c) => c.method == 'activateDirectory').toList();
      expect(activates, hasLength(1));
      expect(activates.single.arguments, <String, Object?>{'uri': uri});
    });

    test('并发调用单飞：共享同一次原生激活', () async {
      final gate = Completer<Object?>();
      mockChannel((call) {
        calls.add(call);
        return gate.future;
      });

      const uri = 'file://docs/storage/Users/currentUser/Music2';
      final a = OhosPlatformBridge.ensureDirectoryActivated(uri);
      final b = OhosPlatformBridge.ensureDirectoryActivated(uri);
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));

      gate.complete(null);
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(calls, hasLength(1));
    });

    test('激活失败返回 false 且不缓存：下次访问重试', () async {
      var attempts = 0;
      mockChannel((call) async {
        calls.add(call);
        if (call.method != 'activateDirectory') return null;
        attempts++;
        if (attempts == 1) {
          throw PlatformException(
              code: '13900001', message: 'permission denied');
        }
        return null;
      });

      const uri = 'file://docs/storage/Users/currentUser/Music3';
      expect(await OhosPlatformBridge.ensureDirectoryActivated(uri), isFalse);
      expect(await OhosPlatformBridge.ensureDirectoryActivated(uri), isTrue);
      expect(attempts, 2);
    });

    test('resolvePath 首次失败 → 激活 → 重试成功', () async {
      var resolveCalls = 0;
      mockChannel((call) async {
        calls.add(call);
        if (call.method == 'activateDirectory') return null;
        if (call.method == 'resolvePath') {
          resolveCalls++;
          if (resolveCalls == 1) {
            throw PlatformException(code: '13900001', message: 'not activated');
          }
          return '/data/storage/el2/base/Music/a.flac';
        }
        return null;
      });

      const uri = 'file://docs/storage/Users/currentUser/Music4';
      final path = await OhosPlatformBridge.resolvePathWithActivation(
          uri, 'a.flac');

      expect(path, '/data/storage/el2/base/Music/a.flac');
      expect(resolveCalls, 2);
      expect(
          calls.where((c) => c.method == 'activateDirectory'), hasLength(1));
      // 激活成功已缓存：后续解析不再重复激活。
      calls.clear();
      final again = await OhosPlatformBridge.resolvePathWithActivation(
          uri, 'b.flac');
      expect(again, '/data/storage/el2/base/Music/a.flac');
      expect(calls.where((c) => c.method == 'activateDirectory'), isEmpty);
    });

    test('resolvePath 首次成功时不触发激活', () async {
      mockChannel((call) async {
        calls.add(call);
        if (call.method == 'resolvePath') return '/sandbox/a.flac';
        return null;
      });

      const uri = 'file://docs/storage/Users/currentUser/Music5';
      final path = await OhosPlatformBridge.resolvePathWithActivation(
          uri, 'a.flac');

      expect(path, '/sandbox/a.flac');
      expect(calls.where((c) => c.method == 'activateDirectory'), isEmpty);
    });
  });
}
