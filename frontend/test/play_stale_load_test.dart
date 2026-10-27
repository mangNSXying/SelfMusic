import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 离线切歌竞态回归：旧曲的缓存查找/装载晚于新曲完成时，不得再把
/// 播放器音源换回旧曲（UI 显示新曲、实际播放旧曲）。

class _DelayedCacheSource extends MusicSource {
  final _aLookupStarted = Completer<void>();
  final _releaseA = Completer<void>();

  Future<void> get aLookupStarted => _aLookupStarted.future;

  void releaseA() => _releaseA.complete();

  @override
  String get key => 'webdav:test';
  @override
  String get name => 'test';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;

  @override
  Future<String?> cachedFilePath(Song song) async {
    if (song.sourceRef == 'a.mp3') {
      if (!_aLookupStarted.isCompleted) _aLookupStarted.complete();
      await _releaseA.future;
    }
    return '/cache/${song.sourceRef}';
  }
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();

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

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
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
  final loadedUris = <String>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      players[request.id] = _RecordingPlatformPlayer(request.id, loadedUris);

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

class _RecordingPlatformPlayer extends _FakePlatformPlayer {
  _RecordingPlatformPlayer(super.id, this.loadedUris);

  final List<String> loadedUris;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is UriAudioSourceMessage) loadedUris.add(source.uri);
    return super.load(request);
  }
}

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: ref,
      source: 'webdav',
      sourceRef: ref,
      fileSize: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JustAudioPlatform saved;
  late _FakeJustAudio fake;

  setUp(() {
    saved = JustAudioPlatform.instance;
    fake = _FakeJustAudio();
    JustAudioPlatform.instance = fake;
  });

  tearDown(() {
    JustAudioPlatform.instance = saved;
  });

  test('旧曲缓存装载迟到：不覆盖已切到的新曲音源', () async {
    final source = _DelayedCacheSource();
    final p = PlayerProvider();
    addTearDown(p.dispose);

    final oldPlay = p.playQueue([_song('a.mp3')], source: source);
    await source.aLookupStarted.timeout(const Duration(seconds: 1));

    await p.playQueue([_song('b.mp3')],
        source: source).timeout(const Duration(seconds: 1));
    expect(p.current?.sourceRef, 'b.mp3');
    expect(fake.loadedUris, ['file:///cache/b.mp3']);

    source.releaseA();
    await oldPlay.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(p.current?.sourceRef, 'b.mp3');
    expect(fake.loadedUris, ['file:///cache/b.mp3'],
        reason: '旧曲 a.mp3 的装载已被令牌作废，不得再下发播放器');
  });
}
