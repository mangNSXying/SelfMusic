import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:sqlite3/open.dart';

/// 播放队列 6 场景 + 队尾重开回归测试（用户例子：基座 [s1..s6]）。
///
/// 语义（DESIGN 深层列表段）：手动点播一律替换深层尾（不增长），自动推进才
/// 推入；队列恒为「深层 ‖ 基座续播段」；顺序推进越过接缝复本；顺序播到队尾
/// 深层清零从头播放；删当前曲播下一首（基座后一位）。
/// 全流程经真实 `_play`（fake 音频平台 + fake 直连源），不断言深层私有状态，
/// 只断言公开的 `current` 与 `queue`（面板所见即所得）。

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

  void _emit(Duration position) {
    _events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: position,
      duration: const Duration(minutes: 3),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _emit(request.initialPosition ?? Duration.zero);
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _emit(request.position ?? Duration.zero);
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

List<Song> _songs6() => [for (var i = 1; i <= 6; i++) _song('s$i')];

List<String> _refs(PlayerProvider p) =>
    [for (final s in p.queue) s.sourceRef];

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

  /// 建 6 首歌单 + 索引 + provider（顺序模式默认）。
  Future<(LocalIndex, PlayerProvider, String, int)> setup() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_qscenario_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final pid = await index.createPlaylist('p');
    final uuid = index.playlistUuidOf(pid);
    for (var i = 1; i <= 6; i++) {
      final r = 's$i';
      await index.addPlaylistItem(pid,
          sourceKey: 'webdav:test', songRef: r, title: r, source: 'webdav');
      index.setLyrics('webdav:test', r, '[00:00.00]x');
    }
    expect(uuid, isNotNull);
    final player = PlayerProvider()
      ..attachSourceResolver(
          (key) => key == 'webdav:test' ? _FakeSource() : null)
      ..attachPersistence(
        index: index,
        weight: SongWeightStore(index),
        submitCurrentMeta: (_, __) {},
      );
    return (index, player, uuid!, pid);
  }

  /// 同歌单点播（手动）：换尾不增长。
  Future<void> tap(PlayerProvider p, String uuid, int index) => p.playQueue(
        _songs6(),
        index: index,
        source: _FakeSource(),
        playlistUuid: uuid,
        contextKey: 'playlist:$uuid',
      );

  group('用户例子全链', () {
    test('点播换尾 + 推进越过接缝复本', () async {
      final (index, player, uuid, _) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0); // 首播 s1：深层 [s1]
      expect(player.current?.sourceRef, 's1');
      expect(_refs(player), ['s1', 's2', 's3', 's4', 's5', 's6']);

      await player.next(); // 自动到 s2：深层 [s1,s2]
      expect(player.current?.sourceRef, 's2');

      await tap(player, uuid, 4); // 点播 s5：换尾，深层 [s1,s5]
      expect(player.current?.sourceRef, 's5');
      expect(_refs(player), ['s1', 's5', 's3', 's4', 's5', 's6']);

      await tap(player, uuid, 2); // 点播 s3：换尾，深层 [s1,s3]
      expect(player.current?.sourceRef, 's3');
      expect(_refs(player), ['s1', 's3', 's3', 's4', 's5', 's6'],
          reason: '接缝复本不断言去重，但深层不再随点播增长');

      await player.next(); // 越过接缝 s3 → s4（推入，深层 [s1,s3,s4]）
      expect(player.current?.sourceRef, 's4',
          reason: '下一首不得原地打转重播 s3');
      expect(_refs(player), ['s1', 's3', 's4', 's4', 's5', 's6']);
    });

    test('顺序播到队尾：深层清零从头播放', () async {
      final (index, player, uuid, _) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0);
      await player.next(); // s2
      await tap(player, uuid, 4); // s5（换尾）
      await tap(player, uuid, 2); // s3（换尾）
      await player.next(); // s4
      await player.next(); // s5
      await player.next(); // s6
      expect(player.current?.sourceRef, 's6');
      expect(_refs(player), ['s1', 's3', 's4', 's5', 's6', 's6'],
          reason: '用户预期：深层 1 3 4 5 6，面板 1 3 4 5 6 6');

      await player.next(); // 队尾 → 清零重开
      expect(player.current?.sourceRef, 's1',
          reason: '队尾不清零就会停住（旧 _finishQueue 口径）');
      expect(_refs(player), ['s1', 's2', 's3', 's4', 's5', 's6'],
          reason: '用户预期：深层回到 1，面板回到 1 2 3 4 5 6');
    });
  });

  group('删歌联动', () {
    test('删已播非当前曲：不断播，续播不错位', () async {
      final (index, player, uuid, pid) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0);
      await player.next(); // s2，当前 s2@1
      await index.removePlaylistItem(pid, 'webdav:test', 's1');
      await player.onPlaylistSongRemoved(uuid, _song('s1'),
          newPlaylistCount: 5);

      expect(player.current?.sourceRef, 's2');
      expect(_refs(player), ['s2', 's3', 's4', 's5', 's6'],
          reason: '旧基座会把 s2 顶到当前曲后面接出 [s3,s2,…]');
    });

    test('删当前曲播下一首', () async {
      final (index, player, uuid, pid) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0);
      await player.next(); // s2，当前 s2@1
      await index.removePlaylistItem(pid, 'webdav:test', 's2');
      await player.onPlaylistSongRemoved(uuid, _song('s2'),
          newPlaylistCount: 5);

      expect(player.current?.sourceRef, 's3',
          reason: '用户预期：删当前改播下一首（不再回放上一首）');
      expect(_refs(player), ['s1', 's3', 's4', 's5', 's6'],
          reason: '用户预期：深层 1 3（此处为 1 3 结构类比），已删的 s2 不复活');
    });

    test('删当前曲且是基座末尾 → 退回播新尾', () async {
      final (index, player, uuid, pid) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0);
      for (var i = 0; i < 5; i++) {
        await player.next(); // 一路播到 s6
      }
      expect(player.current?.sourceRef, 's6');
      await index.removePlaylistItem(pid, 'webdav:test', 's6');
      await player.onPlaylistSongRemoved(uuid, _song('s6'),
          newPlaylistCount: 5);

      expect(player.current?.sourceRef, 's5');
      expect(_refs(player), ['s1', 's2', 's3', 's4', 's5']);
    });
  });

  group('上一首 / 下一首播放', () {
    test('上一首弹栈回自动历史', () async {
      final (index, player, uuid, _) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0);
      await player.next(); // s2
      await player.prev();
      expect(player.current?.sourceRef, 's1');
      expect(_refs(player), ['s1', 's2', 's3', 's4', 's5', 's6']);
    });

    test('下一首播放占当前曲后一位，播后出队', () async {
      final (index, player, uuid, _) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0); // 深层 [s1]
      expect(player.playNext(_song('s6')), isTrue);
      expect(_refs(player), ['s1', 's6', 's3', 's4', 's5', 's6'],
          reason: '预载换人不加位：顶掉原下一首 s2');

      await player.next();
      expect(player.current?.sourceRef, 's6');
      expect(_refs(player), ['s1', 's6', 's3', 's4', 's5', 's6'],
          reason: 's6 出队进入深层，原被顶的 s2 不复活');
    });
  });

  group('复本定位（只亮新播行）', () {
    test('复播旧歌：currentIndex 指深层尾，下一首从尾后续播', () async {
      final (index, player, uuid, _) = await setup();
      addTearDown(index.close);
      addTearDown(player.dispose);

      await tap(player, uuid, 0); // s1：深层 [s1]
      await player.next(); // s2：深层 [s1,s2]
      await tap(player, uuid, 0); // 点播 s1：换尾，深层 [s1,s1]
      expect(player.current?.sourceRef, 's1');
      expect(player.currentIndex, 1,
          reason: '旧口径 indexWhere 会指回旧复本 0，面板两行同亮且接续错位');
      expect(_refs(player), ['s1', 's1', 's3', 's4', 's5', 's6']);

      await player.next(); // 应播 s3，而非重播 s1 原地打转
      expect(player.current?.sourceRef, 's3');
      expect(player.currentIndex, 2);
    });
  });
}
