import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/platform/harmonyos/just_audio_avplayer.dart';

/// 鸿蒙 AVPlayer 适配层的原生事件契约（不触发 MethodChannel）：
/// - audioInterrupt 必须回传焦点事件，并把真实停顿位置/playing=false
///   同步给 just_audio；
/// - completed 不得翻 playing=false，否则 PlayerProvider 的自动续播失效。
void main() {
  test('audioInterrupt pause：位置回退到原生停顿点且 playing=false', () async {
    final handle = AvPlayerHandle('focus-test-1');
    final data = <PlayerDataMessage>[];
    final playback = <PlaybackEventMessage>[];
    final focus = <AvPlayerFocusEvent>[];
    final dataSub = handle.playerDataMessageStream.listen(data.add);
    final playbackSub = handle.playbackEventMessageStream.listen(playback.add);
    final focusSub = avPlayerFocusEvents
        .where((e) => e.playerId == 'focus-test-1')
        .listen(focus.add);
    try {
      handle.handleEvent({'type': 'state', 'state': 'playing'});
      await Future<void>.delayed(Duration.zero);
      expect(data.last.playing, isTrue);

      handle.handleEvent({
        'type': 'audioInterrupt',
        'hint': 'pause',
        'forced': 1,
        'wasPlaying': 1,
        'positionMs': 12345,
      });
      await Future<void>.delayed(Duration.zero);

      expect(focus.single.hint, AvPlayerFocusHint.pause);
      expect(focus.single.forced, isTrue);
      expect(focus.single.wasPlaying, isTrue);
      expect(focus.single.position, const Duration(milliseconds: 12345));
      expect(data.last.playing, isFalse);
      expect(playback.last.updatePosition, const Duration(milliseconds: 12345));
      expect(playback.last.processingState, ProcessingStateMessage.ready);
    } finally {
      await dataSub.cancel();
      await playbackSub.cancel();
      await focusSub.cancel();
    }
  });

  test('原生 paused 回传真实停顿位置且 playing=false', () async {
    final handle = AvPlayerHandle('focus-test-2');
    final data = <PlayerDataMessage>[];
    final playback = <PlaybackEventMessage>[];
    final dataSub = handle.playerDataMessageStream.listen(data.add);
    final playbackSub = handle.playbackEventMessageStream.listen(playback.add);
    try {
      handle.handleEvent({'type': 'state', 'state': 'playing'});
      await Future<void>.delayed(Duration.zero);
      handle.handleEvent({
        'type': 'state',
        'state': 'paused',
        'positionMs': 9876,
      });
      await Future<void>.delayed(Duration.zero);
      expect(data.last.playing, isFalse);
      expect(playback.last.updatePosition, const Duration(milliseconds: 9876));
    } finally {
      await dataSub.cancel();
      await playbackSub.cancel();
    }
  });

  test('completed 不翻 playing=false（自动续播依赖 playing=true）', () async {
    final handle = AvPlayerHandle('focus-test-3');
    final data = <PlayerDataMessage>[];
    final sub = handle.playerDataMessageStream.listen(data.add);
    try {
      handle.handleEvent({'type': 'state', 'state': 'playing'});
      await Future<void>.delayed(Duration.zero);
      handle.handleEvent({'type': 'state', 'state': 'completed'});
      await Future<void>.delayed(Duration.zero);
      expect(data.where((m) => m.playing != null).last.playing, isTrue);
    } finally {
      await sub.cancel();
    }
  });

  test('焦点 resume 只上报事件，不自行改 playing', () async {
    final handle = AvPlayerHandle('focus-test-4');
    final data = <PlayerDataMessage>[];
    final focus = <AvPlayerFocusEvent>[];
    final dataSub = handle.playerDataMessageStream.listen(data.add);
    final focusSub = avPlayerFocusEvents
        .where((e) => e.playerId == 'focus-test-4')
        .listen(focus.add);
    try {
      handle.handleEvent({'type': 'state', 'state': 'playing'});
      await Future<void>.delayed(Duration.zero);
      final before = data.length;
      handle.handleEvent({
        'type': 'audioInterrupt',
        'hint': 'resume',
        'forced': 0,
        'wasPlaying': 1,
        'positionMs': 12345,
      });
      await Future<void>.delayed(Duration.zero);
      expect(focus.single.hint, AvPlayerFocusHint.resume);
      expect(data.length, before);
    } finally {
      await dataSub.cancel();
      await focusSub.cancel();
    }
  });
}
