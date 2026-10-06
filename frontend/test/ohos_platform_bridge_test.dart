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

  setUp(calls.clear);

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
}
