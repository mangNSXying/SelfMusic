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
import 'package:selfmusic/services/playback_guard.dart';
import 'package:sqlite3/open.dart';

/// 静音/断连暂停的端到端接线：守卫事件经 [PlayerProvider.pauseByGuard] 真正
/// 把正在播放的播放器暂停（淡入淡出关闭时直切，避免拖慢测试）。

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

class _FakeGuardPlatform implements AudioGuardPlatform {
  final _controller = StreamController<AudioGuardEvent>.broadcast();
  int? volume = 5;

  @override
  Stream<AudioGuardEvent> get events => _controller.stream;
  @override
  Future<int?> get mediaVolume async => volume;
  void emit(AudioGuardEvent e) => _controller.add(e);
  Future<void> close() => _controller.close();
}

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

  late JustAudioPlatform savedAudio;
  late _FakeJustAudio fakeAudio;
  late Directory dir;
  late LocalIndex index;
  late _FakeGuardPlatform guard;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_guard_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();

    savedAudio = JustAudioPlatform.instance;
    fakeAudio = _FakeJustAudio();
    JustAudioPlatform.instance = fakeAudio;

    guard = _FakeGuardPlatform();
  });

  tearDown(() async {
    JustAudioPlatform.instance = savedAudio;
    await guard.close();
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpUntil(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('音量归零：正在播放的 provider 被暂停', () async {
    final settings = AppSettings(index);
    settings.fadeEnabled = false;
    settings.pauseOnZeroVolume = true;

    final p = PlayerProvider();
    try {
      p.attachAppSettings(settings);
      p.attachAudioGuard(guard);
      await p.playQueue([_song('a.mp3', 'A')], source: _FakeSource());
      expect(p.playing, isTrue);

      guard.emit(const AudioGuardEvent.volume(0));
      await pumpUntil(() => !p.playing);
      expect(p.playing, isFalse);
    } finally {
      p.dispose();
    }
  });

  test('开关关闭时音量归零不暂停', () async {
    final settings = AppSettings(index);
    settings.fadeEnabled = false;
    // pauseOnZeroVolume 默认关。

    final p = PlayerProvider();
    try {
      p.attachAppSettings(settings);
      p.attachAudioGuard(guard);
      await p.playQueue([_song('a.mp3', 'A')], source: _FakeSource());
      expect(p.playing, isTrue);

      guard.emit(const AudioGuardEvent.volume(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(p.playing, isTrue);
    } finally {
      p.dispose();
    }
  });
}
