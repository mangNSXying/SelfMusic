import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 切歌并发回归（Windows 全局热键连发/按住自动重复）：
///
/// - 用户切歌必须串行：同一时刻只有一次音源装载在飞。just_audio 不会中断
///   并发 setUrl，桌面 media_kit 适配层的装载状态是跨 load 共享的，叠发装载
///   会出现「界面已经切到新曲、声音还在旧曲」。
/// - 连按合并成一格待办：不会因为按住热键堆积几十首的装载队列。
/// - 新曲装载失败时旧音源不能继续响（界面已显示新曲，声音必须一致）。

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:test';
  @override
  String get name => 'test';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
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

  late JustAudioPlatform savedPlatform;
  late _FakeJustAudio fake;
  late List<Duration> savedBackoff;

  setUp(() {
    savedPlatform = JustAudioPlatform.instance;
    fake = _FakeJustAudio();
    JustAudioPlatform.instance = fake;
    savedBackoff = PlayerProvider.loadBackoff;
    // 失败用例不等真实退避。
    PlayerProvider.loadBackoff = const [Duration.zero, Duration.zero];
  });

  tearDown(() {
    JustAudioPlatform.instance = savedPlatform;
    PlayerProvider.loadBackoff = savedBackoff;
  });

  test('连按下一首：装载串行且只保留一格待办', () async {
    final source = _FakeSource();
    final p = PlayerProvider();
    addTearDown(p.dispose);

    var inFlight = 0;
    var maxInFlight = 0;
    var loads = 0;
    p.loadOverride = (s, src) async {
      loads++;
      inFlight++;
      maxInFlight = math.max(maxInFlight, inFlight);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      inFlight--;
    };

    await p.playQueue(
      [_song('a'), _song('b'), _song('c'), _song('d'), _song('e')],
      index: 0,
      source: source,
    );
    expect(loads, 1);

    // 连发四次（模拟按住全局热键的自动重复）。
    final futures = [p.next(), p.next(), p.next(), p.next()];
    await Future.wait(futures).timeout(const Duration(seconds: 2));

    expect(maxInFlight, 1, reason: '同一时刻只能有一次装载在飞');
    // 一次立即推进 + 连按合并成一格待办：a → b → c。
    expect(loads, 3);
    expect(p.current?.sourceRef, 'c');
  });

  test('新曲装载失败：暂停旧音源，不让它继续响', () async {
    final source = _FakeSource();
    final p = PlayerProvider();
    addTearDown(p.dispose);

    var failNext = false;
    p.loadOverride = (s, src) async {
      if (failNext) throw StateError('source unavailable');
    };

    await p.playQueue([_song('a'), _song('b')], index: 0, source: source);
    await Future<void>.delayed(Duration.zero);
    expect(p.current?.sourceRef, 'a');
    expect(p.playing, isTrue);

    failNext = true;
    await p.next().timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);

    expect(p.current?.sourceRef, 'b', reason: '界面已切到新曲');
    expect(p.playing, isFalse, reason: '旧音源必须停下，界面与声音保持一致');
  });
}
