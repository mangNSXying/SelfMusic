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

/// 断点首帧预热回归测试。
///
/// 需求：冷启动首帧即渲染上次断点（歌曲/封面/进度），而非「未在播放」占位。
/// 实现：`restorePreferRemote()` 在启动 initState 内同步发起，其同步前缀
/// （取断点→重建队列→置当前曲→置乐观位置）在首帧 build 前完成；音频装载/
/// seek 在后台继续，完成后乐观值退场切真实值。
///
/// 本测试不断言 UI，只断言 provider 的同步前缀语义：
/// - 未 await 恢复 Future 时，当前曲/乐观位置/回退时长已就绪；
/// - 恢复完成后真实值接管且无缝一致；
/// - 恢复装载期用户切歌时，旧断点不拽回新歌。

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
      duration: 240,
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

  /// 建歌单（全部 refs）+ 索引 + provider；返回真实 playlist uuid。
  Future<(LocalIndex, PlayerProvider, String)> setup(
      List<String> playlistRefs) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_bpprime_');
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
    // 模拟已扫描入库（含时长）：真实恢复走融合基座 + 索引实时行，时长随行可得。
    await index.upsertSongs([
      for (final r in playlistRefs)
        DirectSongRow(
          sourceKey: 'webdav:test',
          ref: r,
          title: r,
          duration: 240,
          size: 1024,
          mtime: 0,
        ),
    ]);
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

  test('首帧预热：restore 未 await 时当前曲/乐观位置/时长已就绪', () async {
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

    // 启动路径：initState 内同步发起，不 await（首帧 build 即读这些值）。
    final f = player.restorePreferRemote();
    expect(player.hasCurrent, isTrue,
        reason: '同步前缀必须在首帧前置好当前曲，否则播放页仍是占位');
    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.position, const Duration(milliseconds: 10000),
        reason: '装载完成前进度条应显示乐观断点位置');
    expect(player.duration, const Duration(seconds: 240),
        reason: '装载完成前总时长应回退到歌曲元数据时长');

    await f;
    // 恢复完成：真实装载 + seek 接管，值无缝一致。
    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.position, const Duration(milliseconds: 10000));
    // 放干平台事件投递（fake 播放器广播事件的异步链），避免收尾投递撞上
    // 已 close 的索引。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('远端更新镜像：首帧即按镜像预热', () async {
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
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt:
          DateTime.now().add(const Duration(seconds: 1)).toIso8601String(),
    );

    final f = player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/b.flac',
        reason: '更新的远端断点应在首帧即被采用，避免先闪旧曲再跳');
    expect(player.position, const Duration(milliseconds: 30000));

    await f;
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.position, const Duration(milliseconds: 30000));
    // 放干平台事件投递（见上）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('恢复装载期用户切歌：旧断点不拽回新歌', () async {
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

    final f = player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');

    // 装载完成前用户下一首：新歌位置不得再被旧断点 seek 覆盖。
    // 注：next() 即起播，真值按挂钟插值有毫秒级漂移，只断言远离旧断点。
    await player.next();
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.position.inMilliseconds, lessThan(2000),
        reason: '已切到新歌，旧曲的乐观位置必须失效');

    await f;
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.position.inMilliseconds, lessThan(5000));
    // 放干平台事件投递（见上）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}
