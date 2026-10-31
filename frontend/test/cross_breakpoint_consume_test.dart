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
      ..attachServerAvailable(() => true)
      ..attachPersistence(
        index: index,
        weight: SongWeightStore(index),
        // 吞掉起播后的元数据补读（网络 I/O），保持测试确定性。
        submitCurrentMeta: (_, __) {},
      );
    return (index, player, uuid!);
  }

  test('启动恢复不产生 v2 head 事件（恢复不是真实播放操作）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    player.attachSyncHooks(onSyncPoke: () {});

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    await player.restorePreferRemote();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await index.pendingOutbox(), isEmpty,
        reason: '启动恢复/装载只应用状态，不能生成 head 操作');
  });

  test('v2 起播生成 play_track，seek 复用同一会话并标记 seek', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    player.attachSyncHooks(onSyncPoke: () {});

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      index: 0,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
      resetAnchor: true,
      resumeFromBreakpoint: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    var events = await index.pendingOutbox();
    var bps = events.where((e) => e.type == 'breakpoint.set').toList();
    expect(bps, isNotEmpty);
    final first = bps.last.payload;
    expect(first['protocol'], 2);
    expect(first['intent'], 'play_track');
    expect(first['op_clock'], matches(RegExp(r'^\d+-\d+$')));
    final session = (first['head'] as Map)['session_id'] as String;
    expect(session, isNotEmpty);
    expect(first['head']['source_ref'], '/x/a.flac');
    expect(first['head']['playing'], true);

    // 清掉起播事件，只观察 seek 的 head 操作。
    await index.deleteOutbox(bps.map((e) => e.eventUuid));
    await player.seek(const Duration(seconds: 42));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    events = await index.pendingOutbox();
    bps = events.where((e) => e.type == 'breakpoint.set').toList();
    expect(bps, hasLength(1));
    final seek = bps.single.payload;
    expect(seek['intent'], 'seek');
    expect((seek['head']['position_ms'] as num).toDouble(), closeTo(42000, 50));
    expect(seek['head']['session_id'], session,
        reason: 'seek 是同一播放会话内的真实操作');
  });

  test('v2 head 未变时只合并对端历史，不 seek 不打断', () async {
    final (index, player, uuid) =
        await setup(['/x/a.flac', '/x/b.flac', '/x/s.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');

    await index.savePlayState(
      jsonEncode([
        _song('/x/a.flac').toJson(),
        _song('/x/b.flac').toJson(),
        _song('/x/s.flac').toJson(),
      ]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    await index.saveDeepList(
        'playlist:$uuid',
        jsonEncode([
          _song('/x/a.flac').toJson(),
          _song('/x/b.flac').toJson(),
        ]));
    await player.restorePreferRemote();
    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.position.inMilliseconds, 10000);

    final base = <dynamic>[
      {'source': 'webdav', 'source_ref': '/x/a.flac'},
      {'source': 'webdav', 'source_ref': '/x/b.flac'},
    ];
    await player.applyV2BreakpointSnapshot({
      'client_uuid': uuid,
      'head_rev': 1,
      'history_rev': 1,
      'head_op_id': 'op-remote-1',
      'head_session': 's-remote',
      'head_device': 'dev-b',
      'head_clock': '1000-0',
      'source': 'webdav',
      'source_ref': '/x/a.flac',
      'position_ms': 10000,
      'deep_list': base,
      'last_event_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, base);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await player.applyV2BreakpointSnapshot({
      'client_uuid': uuid,
      'head_rev': 1,
      'history_rev': 2,
      'head_op_id': 'op-remote-1',
      'head_session': 's-remote',
      'head_device': 'dev-b',
      'head_clock': '1000-0',
      'source': 'webdav',
      'source_ref': '/x/a.flac',
      'position_ms': 10000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/x/a.flac'},
        {'source': 'webdav', 'source_ref': '/x/b.flac'},
        {'source': 'webdav', 'source_ref': '/x/s.flac'},
      ],
      'last_event_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, base);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(player.current?.sourceRef, '/x/a.flac', reason: 'head 未变不得切歌');
    expect(player.position.inMilliseconds, 10000, reason: '历史合并不得 seek');
    expect(player.queue.map((s) => s.sourceRef).take(3).toList(),
        ['/x/a.flac', '/x/b.flac', '/x/s.flac']);
    final savedBase = index.breakpointBaseDeepList(uuid);
    expect(savedBase, contains('/x/s.flac'));
    final state = index.breakpointSyncStateOf(uuid);
    expect(state?.appliedHistoryRev, 2);
  });

  test('本机 pending head 未被服务端裁决前，远端新 head 被 defer', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    player.attachSyncHooks(onSyncPoke: () {});
    await player.restorePreferRemote();

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      index: 0,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
      resetAnchor: true,
      resumeFromBreakpoint: false,
    );
    // 等起播事件落 pending（push 尚未被模拟服务端确认）。
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (index.breakpointSyncStateOf(uuid)?.pendingHeadOpId == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(index.breakpointSyncStateOf(uuid)?.pendingHeadOpId, isNotNull);

    // 直接停底层播放器，不通过 UI（不产生新的真实操作/head）。
    await player.player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 5000,
      deepListJson:
          '[{"source":"webdav","source_ref":"/x/a.flac"},'
          '{"source":"webdav","source_ref":"/x/b.flac"}]',
      updatedAt: DateTime.now().toIso8601String(),
      lastEventAt: DateTime.now().toIso8601String(),
      headRev: 10,
      historyRev: 10,
      headClock: '9000-0',
      headOpId: 'op-remote',
      headSession: 's-remote',
      headPlaying: false,
      headUpdatedAt: DateTime.now().toIso8601String(),
    );

    await player.applyNewerMirrorIfAny(viaSync: true);
    expect(player.current?.sourceRef, '/x/a.flac',
        reason: '本机 head 未裁决前不得被远端新 head 顶掉');

    final pendingOp = index.breakpointSyncStateOf(uuid)?.pendingHeadOpId;
    expect(pendingOp, isNotNull);
    // 更早的 ack 不能清掉更新的 pending（只有 op_id 匹配才清）。
    await player.onBreakpointAckedOps({uuid: 'stale-op'});
    expect(index.breakpointSyncStateOf(uuid)?.pendingHeadOpId, pendingOp);
    // 对应 ack 清 pending 后立刻采用被 defer 的服务端 head。
    await player.onBreakpointAckedOps({uuid: pendingOp!});
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(index.breakpointSyncStateOf(uuid)?.appliedHeadRev, 10);
  });

  test('server_epoch 变化清空本地已应用 revision（镜像/断点内容保留）', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    await index.saveBreakpointSyncState(
      playlistUuid: uuid,
      appliedHeadRev: 7,
      appliedHistoryRev: 8,
      serverEpoch: 'epoch-1',
    );
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/a.flac',
      source: 'webdav',
      positionMs: 1000,
      deepListJson: '[{"source":"webdav","source_ref":"/x/a.flac"}]',
      updatedAt: DateTime.now().toIso8601String(),
      headRev: 7,
      historyRev: 8,
      headClock: '7000-0',
      headOpId: 'op-local',
      headSession: 's-local',
      headPlaying: true,
      headUpdatedAt: DateTime.now().toIso8601String(),
    );
    await player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    expect(index.breakpointSyncStateOf(uuid)?.appliedHeadRev, 7);

    await player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-2');
    // 全局重置会清空同步状态行（revision 全部作废），镜像内容保留但版本归零。
    expect(index.breakpointSyncStateOf(uuid), isNull);
    final mirror = index.breakpointMirrorOf(uuid);
    expect(mirror, isNotNull);
    expect(mirror!.headRev, 0);
    expect(mirror.historyRev, 0);
    expect(mirror.sourceRef, '/x/a.flac');
  });

  test('网络响应先于本机恢复：按本地记录的 epoch 识别变化并重置', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    await index.saveBreakpointSyncState(
      playlistUuid: uuid,
      appliedHeadRev: 9,
      appliedHistoryRev: 9,
      serverEpoch: 'epoch-old',
    );
    expect(index.breakpointStoredServerEpoch(), 'epoch-old');
    // 模拟进程刚启动、内存还没有 epoch，但网络响应已经到了。
    await player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-new');
    expect(index.breakpointSyncStateOf(uuid), isNull);
    expect(index.breakpointStoredServerEpoch(), isNull);
  });

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
    final base = index.breakpointBaseDeepList(uuid);
    expect(base, contains('/x/a.flac'));
    expect(base, contains('/x/b.flac'), reason: '播放器采用镜像历史后 base 必须对齐本机列表');
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

  test('采用远端断点：当前曲定位回深层尾而非基座副本', () async {
    final (index, player, uuid) =
        await setup(['/x/a.flac', '/x/b.flac', '/x/c.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    player.attachSyncHooks(onSyncPoke: () {});
    await player.restorePreferRemote();

    final now = DateTime.now().toIso8601String();
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/c.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/b.flac', '/x/c.flac']),
      updatedAt: now,
      lastEventAt: now,
      headRev: 5,
      historyRev: 5,
      headClock: '9000-0-test',
      headOpId: 'op-remote-c',
      headSession: 's-remote',
      headUpdatedAt: now,
    );
    await player.applyNewerMirrorIfAny(viaSync: true);

    expect(player.current?.sourceRef, '/x/c.flac');
    expect(player.queue.map((s) => s.sourceRef).toList(),
        ['/x/b.flac', '/x/c.flac', '/x/c.flac'],
        reason: '融合队列 = 深层 ‖ 基座续播段，c 出现两处');
    expect(player.currentIndex, 1,
        reason: '当前曲应落深层尾（下标 1），落到基座副本 2 会把整段基座当成已过去');
  });

  test('孤儿 pending head 启动时清理，远端 head 仍可被采用', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);
    player.setBreakpointProtocolV2(true, serverEpoch: 'epoch-1');
    player.attachSyncHooks(onSyncPoke: () {});

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );
    // 旧版本“先落 pending 再入队”/被合并删除后遗留：DB 有 pending，outbox 无事件。
    await index.saveBreakpointSyncState(
      playlistUuid: uuid,
      pendingHeadOpId: 'op-orphan',
      sessionId: 's-local',
      serverEpoch: 'epoch-1',
    );
    final now = DateTime.now().toIso8601String();
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/b.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt: now,
      lastEventAt: now,
      headRev: 6,
      historyRev: 6,
      headClock: '9000-0-test',
      headOpId: 'op-remote',
      headSession: 's-remote',
      headUpdatedAt: now,
    );

    await player.restorePreferRemote();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(index.breakpointSyncStateOf(uuid)?.pendingHeadOpId, isNull,
        reason: '没有对应 outbox 事件的 pending 是孤儿，会永久挡住远端 head 采用');
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.position.inMilliseconds, 30000);
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

  test('远端明确清空深层历史：空镜像也清空本机并同步 base', () async {
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
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac']);

    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/a.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: '[]',
      updatedAt:
          DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
    );
    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac'],
        reason: '清空历史后从当前曲按歌单基座续播');
    expect(index.breakpointBaseDeepList(uuid), '[]',
        reason: '空镜像表示服务端明确清空，base 必须同步为空');
  });

  test('坏 deep_list_json 不清本机历史', () async {
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
    await index.saveDeepList(
        'playlist:$uuid',
        jsonEncode(
            [_song('/x/a.flac').toJson(), _song('/x/b.flac').toJson()]));
    await player.restorePreferRemote();

    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/a.flac',
      source: 'webdav',
      positionMs: 30000,
      deepListJson: 'not-json',
      updatedAt:
          DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
    );
    await player.applyNewerMirrorIfAny();

    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac'],
        reason: '坏 JSON 不是明确清空，不能抹掉本机历史');
    expect(index.breakpointBaseDeepList(uuid), isNull,
        reason: '坏 JSON 不能被当成“已采用的空列表”写进 base');
  });

  test('push 在途新增：base 取服务端已确认分支，下一轮仍会把本地新增补推', () async {
    final (index, player, uuid) =
        await setup(['/x/a.flac', '/x/b.flac', '/x/s.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac'), _song('/x/s.flac')],
      index: 0,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
      resetAnchor: true,
    );
    await player.next();
    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.queue.map((s) => s.sourceRef).take(2).toList(),
        ['/x/a.flac', '/x/b.flac'],
        reason: '发送时本地历史为 [a,b]');

    // 服务端合并出 [a,s]；sent=[a]，push 在途期间本地又播了 b。
    await player.applyMergedBreakpointHistory(
      {
        'client_uuid': uuid,
        'source': 'webdav',
        'source_ref': '/x/b.flac',
        'position_ms': 1,
        'last_event_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'deep_list': [
          {'source': 'webdav', 'source_ref': '/x/a.flac'},
          {'source': 'webdav', 'source_ref': '/x/s.flac'},
        ],
      },
      [
        {'source': 'webdav', 'source_ref': '/x/a.flac'},
      ],
    );

    expect(player.queue.map((s) => s.sourceRef).take(3).toList(),
        ['/x/a.flac', '/x/s.flac', '/x/b.flac'],
        reason: '本地在途新增 b 必须留在合并结果末尾');
    final base = index.breakpointBaseDeepList(uuid)!;
    expect(base, contains('/x/s.flac'), reason: 'base 必须包含服务端已确认的 s');
    expect(base, isNot(contains('/x/b.flac')),
        reason: 'b 尚未上推，不能进入 base，否则下一轮会漏推');
  });

  test('非当前歌单的 merged 回执不触发自动套用/切歌', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    final otherId = await index.createPlaylist('other');
    final otherUuid = index.playlistUuidOf(otherId)!;
    await index.addPlaylistItem(otherId,
        sourceKey: 'webdav:test',
        songRef: '/x/c.flac',
        title: 'c',
        source: 'webdav');

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      index: 0,
      source: _FakeSource(),
      playlistUuid: uuid,
      contextKey: 'playlist:$uuid',
      resetAnchor: true,
    );
    expect(player.current?.sourceRef, '/x/a.flac');

    // 非当前歌单收到 merged：只补镜像/历史，不允许随后 flush 自动切过去。
    final future = DateTime.now().add(const Duration(seconds: 5));
    await player.applyMergedBreakpointHistory(
      {
        'client_uuid': otherUuid,
        'source': 'webdav',
        'source_ref': '/x/c.flac',
        'position_ms': 1000,
        'last_event_at': future.toIso8601String(),
        'updated_at': future.toIso8601String(),
        'deep_list': [
          {'source': 'webdav', 'source_ref': '/x/c.flac'},
        ],
      },
      const [],
    );
    await index.upsertBreakpointMirror(
      playlistUuid: otherUuid,
      sourceRef: '/x/c.flac',
      source: 'webdav',
      positionMs: 1000,
      deepListJson: _deepListJson(['/x/c.flac']),
      updatedAt: future.toIso8601String(),
    );

    await player.applyNewerMirrorIfAny(viaSync: true);

    expect(player.current?.sourceRef, '/x/a.flac',
        reason: '非当前歌单的合并回执只补历史，不能把正在播放的歌单切走');
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
