import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 睡眠定时曲末停止（2026）：停止恰好落在曲末时，不再停在旧曲末尾，而是
/// 按当前播放模式预切到下一首并**立即暂停**（位置 0，不发声）；单曲循环则
/// 同一首回到开头并暂停。列表结尾没有下一首，维持原地暂停。
///
/// 假平台按 Android 语义实现：`play()` 的 Future 直到 `pause()` 才完成，
/// `playing` 由 play/pause 客户端侧维护；分辨率/进度由事件消息驱动。

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
      DirectStream('https://example.com/${song.sourceRef}');
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  Completer<void>? _playDone;

  /// 最近一次 seek 目标（区分「回到开头」与「原地暂停」）。
  Duration? soughtTo;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  PlaybackEventMessage _event(ProcessingStateMessage state) =>
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: const Duration(minutes: 3),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      );

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _events.add(_event(ProcessingStateMessage.ready));
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  /// 模拟当前曲自然播放结束：平台上报 completed（playing 客户端侧仍为 true）。
  void emitCompleted() => _events.add(_event(ProcessingStateMessage.completed));

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
  Future<SeekResponse> seek(SeekRequest request) async {
    soughtTo = request.position;
    return SeekResponse();
  }
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

Song _song(String ref, String title) => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: title,
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

  _FakePlatformPlayer lastPlayer() => fake.players.values.last;

  Future<void> pumpUntil(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('指定曲数到点：切到下一首并立即暂停（不发声）', () async {
    final p = PlayerProvider();
    try {
      final s1 = _song('a.mp3', 'A');
      final s2 = _song('b.mp3', 'B');
      await p.playQueue([s1, s2], source: _FakeSource());
      expect(p.playing, isTrue);
      expect(p.current?.sourceRef, 'a.mp3');

      p.setSleepCount(1);
      expect(p.sleepTimerActive, isTrue);

      lastPlayer().emitCompleted();
      await pumpUntil(() => (p.current?.sourceRef ?? '') == 'b.mp3');

      expect(p.current?.sourceRef, 'b.mp3', reason: '应切到下一首');
      expect(p.playing, isFalse, reason: '切歌后必须保持暂停，不得自动播放');
      expect(p.sleepTimerActive, isFalse, reason: '定时已收口');
    } finally {
      p.dispose();
    }
  });

  test('单曲循环到点：同一首回到开头并暂停', () async {
    final p = PlayerProvider();
    try {
      final s1 = _song('a.mp3', 'A');
      final s2 = _song('b.mp3', 'B');
      await p.playQueue([s1, s2], source: _FakeSource());
      p.setMode(PlayMode.loopOne);
      p.setSleepCount(1);

      lastPlayer().emitCompleted();
      await pumpUntil(() => !p.playing);

      expect(p.current?.sourceRef, 'a.mp3', reason: '单曲循环仍是同一首');
      expect(lastPlayer().soughtTo, Duration.zero, reason: '回到开头而非停在曲末');
      expect(p.playing, isFalse);
      expect(p.sleepTimerActive, isFalse);
    } finally {
      p.dispose();
    }
  });
}
