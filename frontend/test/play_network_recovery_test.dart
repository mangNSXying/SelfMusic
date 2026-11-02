import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/media_proxy.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 断网恢复回归：
/// - 播放错误/卡死后的重载必须保留进度（旧实现从头重播）；
/// - 位置停滞看门狗能在“playing 但无声”时主动恢复；
/// - 网络类失败进入挂起，探针恢复后自动续播；
/// - 装载失败后点播放会重新装载，而不是对 idle 播放器空转。

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

  bool probeFails = false;
  int probeCalls = 0;

  @override
  Future<void> probe(Song song) async {
    probeCalls++;
    if (probeFails) {
      throw const SocketException('Network is unreachable');
    }
  }
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(this.owner, super.id);

  final _FakeJustAudio owner;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final loads = <LoadRequest>[];
  final seeks = <SeekRequest>[];

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void emitProgress(Duration position, {Duration? buffered}) {
    _events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: buffered ?? position,
      duration: owner.duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads.add(request);
    final err = owner.loadError;
    if (err != null) throw err;
    emitProgress(Duration.zero);
    return LoadResponse(duration: owner.duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request);
    emitProgress(request.position ?? Duration.zero);
    return SeekResponse();
  }

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

  /// 历史上创建过的全部平台实例（load 失败会 dispose 后重建，必须跨实例统计）。
  final all = <_FakePlatformPlayer>[];

  /// 非空时所有 `load` 直接抛错（模拟断网/坏源）。
  Object? loadError;
  Duration duration = const Duration(minutes: 5);

  Iterable<LoadRequest> get allLoads => all.expand((p) => p.loads);
  Iterable<SeekRequest> get allSeeks => all.expand((p) => p.seeks);
  _FakePlatformPlayer get current => players.values.last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = _FakePlatformPlayer(this, request.id);
    players[request.id] = p;
    all.add(p);
    return p;
  }

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

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

int _seekSeconds(SeekRequest s) => (s.position ?? Duration.zero).inSeconds;

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JustAudioPlatform savedPlatform;
  final savedBackoff = PlayerProvider.loadBackoff;
  final savedStall = PlayerProvider.stallTimeout;
  final savedStallTick = PlayerProvider.stallCheckInterval;
  final savedProbeInterval = PlayerProvider.netProbeInterval;
  final savedProbeTimeout = PlayerProvider.netProbeTimeout;

  setUp(() {
    savedPlatform = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakeJustAudio();
    PlayerProvider.loadBackoff = const [Duration.zero, Duration.zero];
    PlayerProvider.stallTimeout = const Duration(seconds: 12);
    PlayerProvider.stallCheckInterval = const Duration(seconds: 2);
    PlayerProvider.netProbeInterval = const Duration(seconds: 4);
    PlayerProvider.netProbeTimeout = const Duration(seconds: 1);
  });

  tearDown(() {
    JustAudioPlatform.instance = savedPlatform;
    PlayerProvider.loadBackoff = savedBackoff;
    PlayerProvider.stallTimeout = savedStall;
    PlayerProvider.stallCheckInterval = savedStallTick;
    PlayerProvider.netProbeInterval = savedProbeInterval;
    PlayerProvider.netProbeTimeout = savedProbeTimeout;
  });

  test('网络类失败判定：连接/超时为真，鉴权/永久不可用为假', () {
    expect(PlayerProvider.isNetworkFailure(const SocketException('x')), isTrue);
    expect(PlayerProvider.isNetworkFailure(TimeoutException('t')), isTrue);
    expect(
        PlayerProvider.isNetworkFailure(
            PlayerException(1003, 'Source error: connection reset')),
        isTrue);
    expect(
        PlayerProvider.isNetworkFailure(const SourceAuthException('401')),
        isFalse);
    expect(
        PlayerProvider.isNetworkFailure(
            const MediaProxyUnavailableException('文件不存在')),
        isFalse);
    expect(PlayerProvider.isNetworkFailure(StateError('404 not found')), isFalse);
  });

  test('播放错误后的恢复保留进度（不回到 0）', () async {
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final p = PlayerProvider();
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: _FakeSource());
    fake.current.emitProgress(const Duration(seconds: 60));
    await _settle();

    p.debugPlaybackError(PlayerException(1003, 'Source error'));

    await _waitFor(() => fake.allSeeks.any((s) => _seekSeconds(s) >= 50));
    final seek = fake.allSeeks.lastWhere((s) => _seekSeconds(s) >= 50);
    expect(_seekSeconds(seek), inInclusiveRange(59, 62),
        reason: '恢复必须从错误时的位置继续，而不是从头重播');
  });

  test('停滞看门狗：playing 但位置不前进时触发重载', () async {
    PlayerProvider.stallTimeout = const Duration(milliseconds: 60);
    PlayerProvider.stallCheckInterval = const Duration(milliseconds: 20);
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final p = PlayerProvider();
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: _FakeSource());
    fake.current.emitProgress(const Duration(seconds: 30));
    final before = fake.allLoads.length;

    await _waitFor(() => fake.allLoads.length > before,
        timeout: const Duration(seconds: 3));
    final seek = fake.allSeeks.lastWhere((s) => _seekSeconds(s) >= 25);
    expect(_seekSeconds(seek), inInclusiveRange(29, 32));
  });

  test('缓冲位置冻结但原生位置在走：不判停滞（鸿蒙 CACHED_DURATION 稀疏）', () async {
    PlayerProvider.stallTimeout = const Duration(milliseconds: 120);
    PlayerProvider.stallCheckInterval = const Duration(milliseconds: 20);
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final p = PlayerProvider();
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: _FakeSource());
    final before = fake.allLoads.length;
    // buffered 冻在 5s（模拟鸿蒙只在起播上报一次 CACHED_DURATION），
    // 但原生位置持续前进——不得误判为断流重载。
    for (var i = 1; i <= 30; i++) {
      fake.current.emitProgress(Duration(seconds: i),
          buffered: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(fake.allLoads.length, before, reason: '位置在走就不该重载');
  });

  test('停滞恢复落点用原生位置：不回到缓冲冻结时的旧位置', () async {
    PlayerProvider.stallTimeout = const Duration(milliseconds: 60);
    PlayerProvider.stallCheckInterval = const Duration(milliseconds: 20);
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final p = PlayerProvider();
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: _FakeSource());
    // buffered 早早冻在 5s，而原生位置已走到 40s；随后两者都停 → 判停滞。
    fake.current.emitProgress(const Duration(seconds: 5),
        buffered: const Duration(seconds: 5));
    await _settle();
    fake.current.emitProgress(const Duration(seconds: 40),
        buffered: const Duration(seconds: 5));
    await _settle();

    await _waitFor(() => fake.allSeeks.any((s) => _seekSeconds(s) >= 30),
        timeout: const Duration(seconds: 3));
    final seek = fake.allSeeks.lastWhere((s) => _seekSeconds(s) >= 30);
    expect(_seekSeconds(seek), inInclusiveRange(39, 42),
        reason: '恢复应从真实播放位置继续，而不是缓冲冻结时的 5s');
  });

  test('网络失败进入挂起，探针恢复后自动从原进度续播', () async {
    PlayerProvider.netProbeInterval = const Duration(milliseconds: 30);
    PlayerProvider.netProbeTimeout = const Duration(milliseconds: 200);
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final src = _FakeSource();
    final p = PlayerProvider();
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: src);
    fake.current.emitProgress(const Duration(seconds: 42));
    await _settle();
    expect(p.position.inSeconds, greaterThanOrEqualTo(40),
        reason: '测试前提：位置事件应已生效');

    // 断网：装载失败 + 探针不可达。
    fake.loadError = PlatformException(
        code: 'load', message: 'Network is unreachable');
    src.probeFails = true;
    p.debugPlaybackError(PlayerException(1003, 'Source error'));

    await _waitFor(() => p.reconnecting);
    expect(p.reconnecting, isTrue, reason: '网络类失败应挂起等待恢复');

    // 网络恢复：探针成功 → 自动续播。
    final loadsWhenSuspended = fake.allLoads.length;
    fake.loadError = null;
    src.probeFails = false;

    await _waitFor(() => !p.reconnecting);
    expect(fake.allLoads.length, greaterThan(loadsWhenSuspended),
        reason: '恢复后必须重新装载，而不是停在原状');
    final seek = fake.allSeeks.lastWhere((s) => _seekSeconds(s) >= 35);
    expect(_seekSeconds(seek), inInclusiveRange(41, 44));
    expect(p.reconnecting, isFalse);
  });

  test('装载失败后点播放会重新装载（不是空转）', () async {
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final src = _FakeSource();
    final p = PlayerProvider();
    addTearDown(p.dispose);

    // 先成功播一次，创建播放器；再让下一次装载失败（非网络类：404）。
    await p.playQueue([_song()], source: src);
    fake.loadError = PlatformException(code: 'load', message: '404 not found');
    await p.playQueue([_song()], source: src);
    expect(fake.allLoads, isNotEmpty);

    // 失败后播放器停在 idle/loading；恢复后点播放必须重新装载。
    fake.loadError = null;
    final before = fake.allLoads.length;
    await p.toggle();
    await _waitFor(() => fake.allLoads.length > before);
    expect(fake.allLoads.length, greaterThan(before),
        reason: '点了播放应重新装载，而不是对空播放器空转');
  });
}
