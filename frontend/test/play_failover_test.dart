import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 主→备自动切换回归：
/// - 主线路装载失败（含平台层 Loading interrupted）必须继续试备用线路；
/// - 有备用时主线路不再走退避重试，failover 立即发生；
/// - 鉴权类永久失败退出「延迟恢复装载」循环，点播放改走可跳歌的恢复分支。

class _FakeSource extends MusicSource {
  _FakeSource(this._key);

  final String _key;

  @override
  String get key => _key;
  @override
  String get name => _key;
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;

  @override
  DirectStream? directStream(Song song) =>
      DirectStream('https://example.com/$_key/${song.sourceRef}');
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final loads = <LoadRequest>[];

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void emitReady() {
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
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads.add(request);
    emitReady();
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

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:primary',
      title: '歌',
      source: 'webdav',
      sourceRef: 'a.flac',
      fileSize: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JustAudioPlatform saved;
  final savedBackoff = PlayerProvider.loadBackoff;

  setUp(() {
    saved = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakeJustAudio();
    PlayerProvider.loadBackoff = const [Duration.zero, Duration.zero];
  });

  tearDown(() {
    JustAudioPlatform.instance = saved;
    PlayerProvider.loadBackoff = savedBackoff;
  });

  test('主源装载中断 → 自动继续试备用线路', () async {
    final primary = _FakeSource('webdav:primary');
    final backup = _FakeSource('webdav:backup');
    var primaryLoads = 0;
    var backupLoads = 0;

    final p = PlayerProvider();
    addTearDown(p.dispose);
    p.attachLineCandidates((_) => [(primary, 0), (backup, 1)]);
    p.attachSourceResolver((key) => key == backup.key ? backup : primary);
    p.loadOverride = (s, src) async {
      if (src.key == primary.key) {
        primaryLoads++;
        throw PlayerInterruptedException('Loading interrupted');
      }
      backupLoads++;
    };

    final r = await p.debugLoadDirect(_song(), primary, alive: () => true);
    expect(r.source.key, backup.key, reason: '中断类失败不得终止整条候选链');
    expect(r.line, 1);
    expect(r.failover, isTrue, reason: '自动线路下落到备用即为故障转移');
    expect(primaryLoads, 1, reason: '有备用线路时主源不做退避重试');
    expect(backupLoads, 1);
  });

  test('主源鉴权失败 → 自动切到备用并记录线路', () async {
    final primary = _FakeSource('webdav:primary');
    final backup = _FakeSource('webdav:backup');
    var backupLoads = 0;

    final p = PlayerProvider();
    addTearDown(p.dispose);
    p.attachLineCandidates((_) => [(primary, 0), (backup, 1)]);
    p.loadOverride = (s, src) async {
      if (src.key == primary.key) {
        throw const SourceAuthException('WebDAV 鉴权失败（HTTP 401）');
      }
      backupLoads++;
    };

    final r = await p.debugLoadDirect(_song(), primary, alive: () => true);
    expect(r.source.key, backup.key);
    expect(r.line, 1);
    expect(r.failover, isTrue);
    expect(backupLoads, 1);
  });

  test('单线路鉴权失败直接抛错，不静默吞掉', () async {
    final primary = _FakeSource('webdav:primary');
    final p = PlayerProvider();
    addTearDown(p.dispose);
    p.attachLineCandidates((_) => [(primary, 0)]);
    p.loadOverride = (s, src) async {
      throw const SourceAuthException('WebDAV 鉴权失败（HTTP 401）');
    };

    await expectLater(
      p.debugLoadDirect(_song(), primary, alive: () => true),
      throwsA(isA<SourceAuthException>()),
    );
  });
}
