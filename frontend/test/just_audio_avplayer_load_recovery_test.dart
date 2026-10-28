import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/platform/harmonyos/just_audio_avplayer.dart';

/// 鸿蒙 AVPlayer 装载期 404「播放器不存在」的自愈契约：
/// 原生实例丢失时 just_audio 不会自行重建平台，适配层必须补一次
/// createPlayer 再重试装载，否则只能重启应用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('selfmusic/avplayer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  LoadRequest requestFor(String sourceId) => LoadRequest(
        audioSourceMessage: ProgressiveAudioSourceMessage(
          id: sourceId,
          uri: 'https://example.com/a.flac',
        ),
      );

  test('load 404 播放器不存在：重建原生实例后重试一次', () async {
    final calls = <String>[];
    var loadCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'load') {
        loadCount++;
        if (loadCount == 1) {
          throw PlatformException(code: '404', message: '播放器不存在: p1');
        }
        return <String, dynamic>{'durationMs': 1234};
      }
      return null;
    });

    final handle = AvPlayerHandle('p1');
    final response = await handle.load(requestFor('src1'));

    expect(calls, ['load', 'createPlayer', 'load']);
    expect(response.duration, const Duration(milliseconds: 1234));
  });

  test('其他装载错误不重建实例，原样上抛', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'load', message: '置源失败');
    });

    final handle = AvPlayerHandle('p2');
    await expectLater(
      handle.load(requestFor('src2')),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['load']);
  });
}
