import 'dart:async';
import 'dart:convert';
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

/// 删源（本机删除 / 其它设备同步删除）对**运行时**队列的影响：
///
/// 源一旦删掉，它的歌就再也解析不到播放源（`sourceByKey` 为 null），留在
/// 队列/融合基座/深层历史里只会变成「播到就报错」的死引用。库侧的同一事实
/// 由 `LocalIndex.deleteSource` 收口（play_state / deep_lists），这里断言
/// 播放器侧的运行态与 UI 所见（`current` / `queue`）。
///
/// 全流程经真实 `_play`（fake 音频平台 + fake 直连源），同 queue_scenarios_test。
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
  _FakeSource(this.key);
  @override
  final String key;
  @override
  String get name => key;
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

const _deadKey = 'webdav:test';
const _liveKey = 'local:other';

Song _song(String sourceKey, String ref) => Song(
      id: 0,
      sourceKey: sourceKey,
      title: ref,
      source: sourceKey.split(':').first,
      sourceRef: ref,
      fileSize: 0,
    );

List<String> _refs(PlayerProvider p) =>
    [for (final s in p.queue) '${s.sourceKey}|${s.sourceRef}'];

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

  Future<(LocalIndex, PlayerProvider, String)> setup() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_srcremove_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final pid = await index.createPlaylist('p');
    final uuid = index.playlistUuidOf(pid)!;
    final player = PlayerProvider()
      ..attachSourceResolver((key) =>
          (key == _deadKey || key == _liveKey) ? _FakeSource(key) : null)
      ..attachPersistence(
        index: index,
        weight: SongWeightStore(index),
        submitCurrentMeta: (_, __) {},
      );
    return (index, player, uuid);
  }

  test('删源：队列剔除该源全部歌曲，当前曲被删则续播其后存活曲', () async {
    final (index, player, uuid) = await setup();
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue(
        [_song(_deadKey, 'a1'), _song(_liveKey, 'b1'), _song(_deadKey, 'a2')],
        index: 0,
        contextKey: 'playlist:$uuid',
        playlistUuid: uuid);
    expect(player.current?.sourceRef, 'a1');
    expect(_refs(player),
        ['$_deadKey|a1', '$_liveKey|b1', '$_deadKey|a2']);
    // 「下一首播放」也排着该源的歌：删源后同样不能留在预载槽里。
    expect(player.playNext(_song(_deadKey, 'a2')), isTrue);

    await player.onSourceRemoved(_deadKey);

    expect(_refs(player), ['$_liveKey|b1'],
        reason: '该源的歌（含预载槽里的那首）应被整源剔除');
    expect(player.current?.sourceRef, 'b1',
        reason: '当前曲随源删除后按「删当前曲」口径续播其后存活曲');
    // 深层历史（持久化）同样不再引用该源。
    final raw = index.loadDeepList('playlist:$uuid');
    if (raw != null && raw.isNotEmpty) {
      expect(
          (jsonDecode(raw) as List)
              .where((e) => (e as Map)['sourceKey'] == _deadKey),
          isEmpty);
    }
  });

  test('删源：队列里全是该源的歌 → 收尾停止并清断点', () async {
    final (index, player, uuid) = await setup();
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue([_song(_deadKey, 'a1'), _song(_deadKey, 'a2')],
        index: 0, contextKey: 'playlist:$uuid', playlistUuid: uuid);
    expect(player.current?.sourceRef, 'a1');

    await player.onSourceRemoved(_deadKey);

    expect(player.queue, isEmpty);
    expect(player.current, isNull, reason: '无存活曲应收尾停止，而不是留着死引用');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(index.getPlayState(), isNull,
        reason: '收尾会清断点，重启不该恢复出死引用队列');
  });

  test('删源：只有「下一首播放」槽指向该源时也清空该槽', () async {
    final (index, player, uuid) = await setup();
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue([_song(_liveKey, 'b1'), _song(_liveKey, 'b2')],
        index: 0, contextKey: 'playlist:$uuid', playlistUuid: uuid);
    // 排一首**不在基座里**的被删源歌曲：它只占预载槽，不进深层/基座。
    expect(player.playNext(_song(_deadKey, 'x')), isTrue);
    expect(_refs(player), ['$_liveKey|b1', '$_deadKey|x']);

    await player.onSourceRemoved(_deadKey);

    expect(_refs(player), ['$_liveKey|b1', '$_liveKey|b2'],
        reason: '预载槽里的死引用清掉后应由基座续播段补位');
    expect(player.current?.sourceRef, 'b1');
  });

  test('删源：当前曲不属于被删源时只剔歌、不打断播放', () async {
    final (index, player, uuid) = await setup();
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue([
      _song(_liveKey, 'b1'),
      _song(_deadKey, 'a1'),
      _song(_liveKey, 'b2'),
    ], index: 0, contextKey: 'playlist:$uuid', playlistUuid: uuid);
    expect(player.current?.sourceRef, 'b1');

    await player.onSourceRemoved(_deadKey);

    expect(player.current?.sourceRef, 'b1',
        reason: '当前曲不属于被删源，不该被打断');
    expect(_refs(player), ['$_liveKey|b1', '$_liveKey|b2']);
  });
}
