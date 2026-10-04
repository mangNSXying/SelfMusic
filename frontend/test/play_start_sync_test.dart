import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/services/selfmusic_audio_handler.dart';

/// 播放开始时的媒体会话回推（后台保活回归）。
///
/// just_audio 的 `play()` Future 要等本曲播完/被暂停才 complete（Android 插件把
/// playResult 延迟到 STATE_ENDED/pause）。`_play` 之前 `await player.play()`，
/// 导致其后的 `_syncSystemMedia()`——audio_service 前台服务 + 播放期 wake lock 的
/// 唯一驱动——被推迟到曲末，正常播放期间根本没有前台服务，息屏/Doze 下进程被
/// 冻结回收（「放着放着就没声了」）。
///
/// 假平台按 Android 语义实现：`play()` 返回一个直到 `pause()` 才完成的 Future。
/// 若 `_play` 再次 await 它，本测试会超时失败。

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:test';
  @override
  String get name => 'test';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  Completer<void>? _playDone;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(minutes: 3),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  /// Android 语义：play 的 Future 在播放结束/暂停前不完成。
  @override
  Future<PlayResponse> play(PlayRequest request) {
    _playDone = Completer<void>();
    return _playDone!.future.then((_) => PlayResponse());
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playDone?.complete();
    _playDone = null;
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  Future<void> close() => _events.close();
}

class _FakeJustAudio extends JustAudioPlatform {
  final players = <String, _FakePlatformPlayer>{};

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      players[request.id] = _FakePlatformPlayer(request.id);

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players.remove(request.id)?.close();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (final p in players.values) {
      await p.close();
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: '歌',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JustAudioPlatform saved;

  setUp(() {
    saved = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakeJustAudio();
  });

  tearDown(() {
    JustAudioPlatform.instance = saved;
  });

  test('开始播放不等待 play() Future：playing 状态立即回推媒体会话', () async {
    final p = PlayerProvider();
    try {
      final handler = SelfMusicAudioHandler();
      p.attachAudioHandler(handler);

      // play() 永不完成（直到 pause）：修复前这里会一直挂住。
      await p
          .playQueue([_song()], source: _FakeSource())
          .timeout(const Duration(seconds: 2));

      expect(handler.playbackState.value.playing, isTrue,
          reason: 'playing 必须立即回推：audio_service 据此进前台服务 + 持 wake lock');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(handler.mediaItem.valueOrNull?.title, '歌');
    } finally {
      p.dispose();
    }
  });
}
