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

/// 跨设备断点（当前曲/进度/深层列表）消费回归测试。
///
/// 根因：`_play()` 起播即 `_saveState`，把本地 `play_state.updated_at` 刷成客户端
/// now；此前 `applyNewerMirrorIfAny`/`_resumeFromMirrorIfAny` 用它判断「远端是否
/// 更新」，于是恢复后远端镜像恒判更旧，跨设备续播永不生效。修复引入独立基准
/// `_breakpointBaselineAt` 并在 `_play` 之前消费镜像。本测试用「基准与镜像时间
/// 夹在恢复前后」构造该场景：镜像比恢复前基准新、但比恢复时写入的 now 旧。

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

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

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

String _deepListJson(List<String> refs) => jsonEncode([
      for (final r in refs) {'source': 'webdav', 'source_ref': r},
    ]);

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

  /// 建歌单（2 首）+ 索引 + provider；返回真实 playlist uuid（= 服务端
  /// `client_uuid`，断点归属与镜像按它对齐）。
  Future<(LocalIndex, PlayerProvider, String)> setup(
      List<String> playlistRefs) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_bpconsume_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final id = await index.createPlaylist('p');
    final uuid = index.playlistUuidOf(id);
    for (final r in playlistRefs) {
      await index.addPlaylistItem(id,
          sourceKey: 'webdav:test', songRef: r, title: r, source: 'webdav');
      // 预置歌词：避免 _loadLyrics 触发同目录 .lrc 网络抓取（测试收尾后的
      // 迟到 notifyListeners 会撞上已 dispose 的 provider）。
      index.setLyrics('webdav:test', r, '[00:00.00]x');
    }
    expect(uuid, isNotNull);
    final player = PlayerProvider()
      ..attachSourceResolver((key) => key == 'webdav:test' ? _FakeSource() : null)
      ..attachPersistence(
        index: index,
        weight: SongWeightStore(index),
        // 吞掉起播后的元数据补读（网络 I/O），保持测试确定性。
        submitCurrentMeta: (_, __) {},
      );
    return (index, player, uuid!);
  }

  test('冷启动：恢复后写入的 now 不得遮蔽比基准新的远端断点（含深层列表）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    // 本地断点：a 在 10s（时间戳记为基准，早于恢复时写入的 now）。
    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    // 恢复前的「中间时刻」：镜像时间取在此之后、恢复写入 now 之前。
    final tMid = DateTime.now();

    // 冷启动：local 较新（此刻尚无镜像）→ 走本机恢复，其 _play 会把
    // play_state.updated_at 刷成 now（> tMid）。基准仍为恢复前的本地时间。
    await player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.position.inMilliseconds, 10000);

    // 首轮同步拉到「比基准新、但比恢复 now 旧」的远端断点。
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt: tMid.toIso8601String(),
    );

    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/b.flac',
        reason: '远端断点必须被套用（修复前因基准被 now 覆盖而恒判更旧）');
    expect(player.position.inMilliseconds, 30000);
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac'],
        reason: '深层列表应随断点套用');
  });

  test('打开歌单点播放：起播前消费远端断点并套用深层列表', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    // 本机该歌单旧断点：a 在 10s。
    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    final tMid = DateTime.now();
    // 远端更新断点：b 在 30s + 深层历史 [a, b]。
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt: tMid.toIso8601String(),
    );

    // 打开歌单「播放」：resetAnchor 清空深层 + 重锚，起播前应先消费远端断点。
    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      index: 0,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
      resetAnchor: true,
      resumeFromBreakpoint: true,
    );

    expect(player.current?.sourceRef, '/x/b.flac',
        reason: '应按远端断点续播（修复前本地 _play 已把时间刷成 now，判为更旧而跳过）');
    expect(player.position.inMilliseconds, 30000);
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac'],
        reason: '打开歌单也应套用远端深层列表');
  });

  test('负例：不比基准新的镜像不套用', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    await player.restorePreferRemote();

    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      updatedAt: '2000-01-01T00:00:00.000',
    );
    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/a.flac',
        reason: '早于基准的远端镜像不应覆盖本机恢复结果');
  });

  test('同歌单：更新的镜像按最新胜出（覆盖本机历史）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    await index.saveDeepList('playlist:$uuid',
        jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]));
    await player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');

    // 远端同歌单更新（更晚），历史更短也应胜出：最新时间口径。
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/b.flac']),
      updatedAt:
          DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
    );
    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/b.flac',
        reason: '同歌单取最新：更新的远端镜像胜出');
    expect(player.position.inMilliseconds, 30000);
  });

  test('同歌单：更早的镜像不覆盖本机较新历史', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    // 本机深层历史仅 1 条。
    await index.saveDeepList(
        'playlist:$uuid', jsonEncode([_song('/x/a.flac').toJson()]));

    // 远端同歌单更早（时间戳早于本机断点）：最新时间口径下不应胜出。
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt:
          DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
    );

    await player.restorePreferRemote();

    expect(player.current?.sourceRef, '/x/a.flac',
        reason: '同歌单取最新：更早的远端镜像不应覆盖本机较新历史');
    expect(player.position.inMilliseconds, 10000);
  });

  test('不同歌单：更新的镜像按最新胜出', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    // 第二个歌单 P2（历史更短）。
    final id2 = await index.createPlaylist('p2');
    final uuid2 = index.playlistUuidOf(id2);
    expect(uuid2, isNotNull);
    for (final r in ['/x/c.flac', '/x/d.flac']) {
      await index.addPlaylistItem(id2,
          sourceKey: 'webdav:test', songRef: r, title: r, source: 'webdav');
      index.setLyrics('webdav:test', r, '[00:00.00]x');
    }

    // 本机断点：P1 + 长历史（2 条）。
    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    await index.saveDeepList('playlist:$uuid',
        jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]));
    await player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');

    // 远端：P2 更新（更晚），历史仅 1 条。
    await index.upsertBreakpointMirror(
      playlistUuid: uuid2!,
      sourceRef: '/x/c.flac',
      source: 'webdav',
      positionMs: 40000,
      deepListJson: _deepListJson(['/x/c.flac']),
      updatedAt:
          DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
    );
    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/c.flac',
        reason: '不同歌单取最新：更新的 P2 胜出');
    expect(player.position.inMilliseconds, 40000);
  });
}
