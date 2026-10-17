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

/// F1 启动收敛闸门 + F4 镜像比较时钟回归测试。
///
/// 事故背景：冷启动恢复出的本机旧断点（A）在「远端已被其他设备更新到 B」
/// 的情况下仍被盖上 now 的 occurred_at 推上服务端（毒源），随后本机又把自己
/// 的回声拉回来，界面回退到 A，并继续向对端扩散。
///
/// 修复语义：
/// - 恢复发起即关闸：首个 `applyNewerMirrorIfAny` 跑完（或 30s 兜底）前，
///   断点一律不入队；暂停/停止的强制断点被挡下后开闸时**补跑一次**；
/// - 补跑推的是「开闸时的当前态」（已采用远端 B 则为 B），本机旧断点 A
///   绝不会被推上去；
/// - 镜像「谁更新」的比较时钟 = `last_event_at ?? updated_at`（F4），
///   updated_at（上传时间）不参与比较。

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

  /// 建歌单（全部 refs）+ 索引 + provider（注入同步钩子，onSyncPoke 计数）。
  Future<(LocalIndex, PlayerProvider, String)> setup(
      List<String> playlistRefs) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_bootgate_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final id = await index.createPlaylist('p');
    final uuid = index.playlistUuidOf(id);
    for (final r in playlistRefs) {
      await index.addPlaylistItem(id,
          sourceKey: 'webdav:test', songRef: r, title: r, source: 'webdav');
      index.setLyrics('webdav:test', r, '[00:00.00]x');
    }
    expect(uuid, isNotNull);
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
    var pokes = 0;
    final player = PlayerProvider()
      ..attachSourceResolver((key) => key == 'webdav:test' ? _FakeSource() : null)
      ..attachPersistence(
        index: index,
        weight: SongWeightStore(index),
        submitCurrentMeta: (_, __) {},
      )
      ..attachSyncHooks(onSyncPoke: () => pokes++)
      ..attachServerAvailable(() => true);
    addTearDown(index.close);
    addTearDown(player.dispose);
    return (index, player, uuid!);
  }

  /// 等写隔离落库（_saveState → savePlayState + outbox 入队）。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  test('闸门关闭：本机断点不推；首个镜像判定后补跑强制断点（推本机态）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );

    await player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');
    await settle();
    expect(await index.pendingOutboxCount(), 0,
        reason: '恢复装载期间的断点保存必须被启动闸门挡下（毒源防线）');

    // 暂停（用户最终断点，强制入队）：闸门未开 → 只记待办，不进 outbox。
    await player.pauseFromNotifier();
    await settle();
    expect(await index.pendingOutboxCount(), 0,
        reason: '闸门关闭期间的强制断点同样不得入队');
    expect(player.current?.sourceRef, '/x/a.flac');

    // 首个镜像判定跑完（无镜像 → 判定本机最新）→ 开闸 → 补跑强制断点。
    await player.applyNewerMirrorIfAny();
    await settle();
    final pending = await index.pendingOutbox();
    expect(pending.length, 1, reason: '开闸后补跑一次被挡下的强制断点');
    expect(pending.single.type, 'breakpoint.set');
    expect(pending.single.payload['source_ref'], '/x/a.flac');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('闸门关闭：远端 B 更新时采用 B；开闸后补推 B，绝不推本机旧断点 A（F4 时钟）',
      () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    // F4：镜像的「最后操作时间」比本机新（= 远端后来在别的设备上切到了 B），
    // 但 updated_at（服务端上传时间）刻意做成更早——比较必须只看 lastEventAt。
    final now = DateTime.now();
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt: now.subtract(const Duration(seconds: 30)).toIso8601String(),
      lastEventAt: now.add(const Duration(seconds: 1)).toIso8601String(),
    );

    await player.restorePreferRemote();
    await settle();
    expect(player.current?.sourceRef, '/x/b.flac',
        reason: '远端最后操作时间更新 → 启动即采用 B（F4 不看 updated_at）');
    expect(await index.pendingOutboxCount(), 0,
        reason: '采用远端期间不得推任何断点（闸门关闭）');

    await player.pauseFromNotifier();
    await settle();
    expect(await index.pendingOutboxCount(), 0,
        reason: '闸门关闭期间暂停：强制断点被挡下');

    await player.applyNewerMirrorIfAny();
    await settle();
    final pending = await index.pendingOutbox();
    expect(pending.length, 1);
    expect(pending.single.payload['source_ref'], '/x/b.flac',
        reason: '补推的是当前态（已采用的 B），本机旧断点 A 绝不外推');
    expect((pending.single.payload['position_ms'] as num).toInt(),
        greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('无恢复路径时不关闸：普通起播立即可入队（回归保护）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
    );
    await settle();
    expect(await index.pendingOutboxCount(), greaterThan(0),
        reason: '未走启动恢复（断点续播关）时闸门默认已开，不许回归出「永不推断点」');
    await player.pauseFromNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
}
