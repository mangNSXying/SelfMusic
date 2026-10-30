import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

class _FakeApi {
  final transcodeRequests = <String>[];
  String get baseUrl => 'https://backend.test';
  Future<String?> getAccessToken() async => null;
  String? transcodeStreamUrl(String origin, int bitrate,
      {String loudnorm = 'off'}) {
    transcodeRequests.add('$origin|$bitrate|$loudnorm');
    return 'https://backend.test/api/v1/transcode/stream?origin=$origin';
  }
}

class _ProxiedSource extends MusicSource {
  _ProxiedSource({this.userCache});

  final String? userCache;

  @override
  String get key => 'webdav:test';
  @override
  String get name => 'test';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  SourceRoute get route => SourceRoute.proxy;
  @override
  bool get supportsDirect => true;

  @override
  Future<String?> userCachedFilePath(Song song) async => userCache;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://origin.test/a.flac');
  @override
  String? proxyOrigin(Song song) => 'https://origin.test/a.flac';
  @override
  Future<Map<String, String>> proxyAuthHeaders(Song song) async => const {};
}

class _RecordingPlatformPlayer extends AudioPlayerPlatform {
  _RecordingPlatformPlayer(super.id, this.loadedUris);

  final List<String> loadedUris;
  final _events = StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is UriAudioSourceMessage) loadedUris.add(source.uri);
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
  final players = <String, _RecordingPlatformPlayer>{};
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

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: 'a.flac',
      source: 'webdav',
      sourceRef: 'a.flac',
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

  test('转码开启但已用户缓存：加载本地缓存，不请求转码流', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_cache_first_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    addTearDown(index.close);
    final settings = AppSettings(index)..transcodeEnabled = true;

    final api = _FakeApi();
    final source = _ProxiedSource(userCache: '/cache/user.dat');
    final p = PlayerProvider()
      ..attachAppSettings(settings)
      ..attachApi(api);
    addTearDown(p.dispose);

    await p.playQueue([_song()], source: source).timeout(
      const Duration(seconds: 2),
    );

    expect(fake.loadedUris, ['file:///cache/user.dat']);
    expect(api.transcodeRequests, isEmpty, reason: '用户缓存优先于转码设置');
  });
}
