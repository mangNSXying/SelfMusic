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
/// （取断点→重建队列→置当前曲→置乐观位置）在首帧 build 前完成；之后分两条路径：
/// - 可预载源：暂停态装载 + seek 到断点（旧行为，测试用 debugForceRestorePreload 打开）；
/// - 桌面自建字节流源（SMB/SFTP，经 just_audio 回环代理）或预载失败：延迟到首次播放。
///
/// 本测试不断言 UI，只断言 provider 的同步前缀与两条装载路径：
/// - 未 await 恢复 Future 时，当前曲/乐观位置/回退时长已就绪；
/// - 预载路径恢复完成即真实位置/时长接管；
/// - 延迟路径在首次播放/seek 后才接管，且退出不会把断点清零；
/// - 切换/采用镜像时旧断点不拽回新歌、旧音频不继续响。

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

/// 无原生 URL 的源（模拟桌面 SMB/SFTP）：只能走自建字节流/回环代理。
class _FakeStreamSource extends _FakeSource {
  @override
  DirectStream? directStream(Song song) => null;
}

/// 测试用 MediaProxy 源：file 适配器，验证播放层拿到的 loopback URL。
class _FakeProxySource extends _FakeSource implements MediaProxySource {
  _FakeProxySource(this.path);

  final String path;

  @override
  DirectStream? directStream(Song song) => null;

  @override
  Map<String, Object?>? mediaProxyConfigFor(Song song) => {
        'kind': 'file',
        'sourceKey': key,
        'path': path,
        'size': 0,
        'mime': 'application/octet-stream',
      };
}

/// 自建字节流但已有本地缓存：桌面应允许预载（走 setFilePath）。
class _FakeCachedStreamSource extends _FakeStreamSource {
  _FakeCachedStreamSource(this.path);

  final String path;

  @override
  Future<String?> cachedFilePath(Song song) async => path;
}

class _FakePlatformPlayer extends AudioPlayerPlatform {
  _FakePlatformPlayer(super.id, this._owner);

  final _FakeJustAudio _owner;
  final _events = StreamController<PlaybackEventMessage>.broadcast();

  /// 平台侧实际收到的 play/pause 次数（竞态回归用）。
  int playCalls = 0;
  int pauseCalls = 0;

  /// 最近一次 load 的 URI（验证 MediaProxy loopback URL）。
  String? lastUri;

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
    final msg = request.audioSourceMessage;
    lastUri = msg is UriAudioSourceMessage ? msg.uri : null;
    if (!_owner.loadStarted.isCompleted) _owner.loadStarted.complete();
    final gate = _owner.loadGate;
    if (gate != null) await gate.future;
    _emit(request.initialPosition ?? Duration.zero);
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    playCalls += 1;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauseCalls += 1;
    return PauseResponse();
  }

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

  /// load 已进入（用于在装载挂起时插入用户操作）。
  final loadStarted = Completer<void>();

  /// 非空时 load 阻塞到其完成（模拟启动恢复的慢装载）。
  Completer<void>? loadGate;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      players[request.id] = _FakePlatformPlayer(request.id, this);

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
    // 既有用例覆盖「延迟到首次播放」回退路径；预载用例在用例内显式打开。
    PlayerProvider.debugForceRestorePreload = false;
    // 测试环境没有真实帧：桌面预载直接启动，用例用 debugAwaitRestorePreload 等收尾。
    PlayerProvider.debugRunRestorePreloadImmediately = true;
  });

  tearDown(() {
    JustAudioPlatform.instance = saved;
    PlayerProvider.debugForceRestorePreload = null;
    PlayerProvider.debugRunRestorePreloadImmediately = false;
  });

  /// 建歌单（全部 refs）+ 索引 + provider；返回真实 playlist uuid。
  Future<(LocalIndex, PlayerProvider, String)> setup(
      List<String> playlistRefs,
      {MusicSource? source}) async {
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
      ..attachSourceResolver(
          (key) => key == 'webdav:test' ? (source ?? _FakeSource()) : null)
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
    // 恢复完成：仅恢复状态，媒体仍延迟到首次播放。
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

  test('恢复后用户切歌：旧断点不拽回新歌', () async {
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

    // 首次播放前用户下一首：新歌位置不得再被旧断点 seek 覆盖。
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

  test('恢复后点播放：首次播放才装载，装载完成前不下发 play', () async {
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
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isEmpty, reason: '恢复本身不得触发媒体装载');

    final gate = Completer<void>();
    fake.loadGate = gate;

    final resume = player.resumeFromNotifier();
    await fake.loadStarted.future;
    final fakePlayer = fake.players.values.single;
    expect(fakePlayer.playCalls, 0);

    gate.complete();
    await resume;
    // play() 内部先 await AudioSession.instance，再下发平台 play；放干这条异步链。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakePlayer.playCalls, 1, reason: '装载完成后应下发一次 play');
    expect(fakePlayer.pauseCalls, 0, reason: '装载尾不得把播放请求 pause 掉');
    expect(player.playing, isTrue);
    expect(player.position.inMilliseconds, closeTo(10000, 200));

    // 放干平台事件投递（见上）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('恢复后拖进度条：只更新乐观位置，不触发装载；播放时从新位置装载', () async {
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
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isEmpty, reason: '恢复本身不得触发媒体装载');

    await player.seek(const Duration(milliseconds: 20000));
    expect(fake.players, isEmpty, reason: '暂停态 seek 只更新乐观位置');
    expect(player.position, const Duration(milliseconds: 20000));
    expect(player.playing, isFalse);

    final gate = Completer<void>();
    fake.loadGate = gate;
    final resume = player.resumeFromNotifier();
    await fake.loadStarted.future;
    gate.complete();
    await resume;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(player.position.inMilliseconds, closeTo(20000, 200));
    expect(player.playing, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('恢复后连点两次播放：装载完成后保持暂停，不补发 play', () async {
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
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final gate = Completer<void>();
    fake.loadGate = gate;

    // 第一次点播放：目标态立即翻真，首次装载开始但未完成。
    final first = player.toggle();
    await fake.loadStarted.future;
    final fakePlayer = fake.players.values.single;
    expect(player.playing, isTrue, reason: '等待期按钮目标态应先响应');
    expect(fakePlayer.playCalls, 0);

    // 第二次点播放：目标态翻回暂停，装载尾不应再补发 play。
    await player.toggle();
    expect(player.playing, isFalse);

    gate.complete();
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakePlayer.playCalls, 0, reason: '偶数次连点最终应保持暂停');
    expect(fakePlayer.pauseCalls, 0);
    expect(player.playing, isFalse);

    // 放干平台事件投递（见上）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('恢复后连点两次播控播放：只装载/播放一次', () async {
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
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    final gate = Completer<void>();
    fake.loadGate = gate;

    final first = player.resumeFromNotifier();
    await fake.loadStarted.future;
    final fakePlayer = fake.players.values.single;

    final second = player.resumeFromNotifier();
    await Future<void>.delayed(Duration.zero);
    expect(fakePlayer.playCalls, 0);

    gate.complete();
    await Future.wait([first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakePlayer.playCalls, 1, reason: '连点应合并为一次 play');
    expect(player.playing, isTrue);

    // 放干平台事件投递（见上）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('无播放现场点播放：不构造播放器，不进入假播放态', () async {
    final (index, player, _) = await setup(['/x/a.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    expect(player.debugPlayerBuilt, isFalse);
    await player.resumeFromNotifier();
    expect(player.debugPlayerBuilt, isFalse,
        reason: '无当前曲时 play 不应为了读 processingState 白建播放器');
  });

  test('冷启动预载：可直连源恢复时暂停态装载并 seek 到断点', () async {
    PlayerProvider.debugForceRestorePreload = true;
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
    await player.debugAwaitRestorePreload();
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isNotEmpty, reason: '恢复应完成暂停态媒体装载');
    expect(fake.players.values.single.playCalls, 0, reason: '预载不得起播');
    expect(player.playing, isFalse);
    expect(player.position.inMilliseconds, closeTo(10000, 200));
    expect(player.duration, const Duration(minutes: 3),
        reason: '装载完成后应由真实播放器时长接管');

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('桌面字节流源（SMB/SFTP 形态）：恢复仍延迟到首次播放', () async {
    PlayerProvider.debugForceRestorePreload = null;
    final (index, player, uuid) = await setup(
      ['/x/a.flac', '/x/b.flac'],
      source: _FakeStreamSource(),
    );
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
    await player.debugAwaitRestorePreload();
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isEmpty,
        reason: '自建字节流会经 just_audio 回环代理，启动时不得预载');
    expect(player.position, const Duration(milliseconds: 10000));
  });

  test('延迟态退出：播放器已构造时仍保存乐观断点', () async {
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
    expect(player.debugPlayerBuilt, isFalse);
    // 播放页进度条首帧会访问 player.player，实际运行时播放器一定已构造。
    player.player;
    expect(player.debugPlayerBuilt, isTrue);
    expect(player.player.position, Duration.zero,
        reason: '延迟装载态播放器无音源，position 恒为 0');

    await player.shutdown();
    final st = index.getPlayState();
    expect(st?.positionMs, 10000, reason: '退出不得把恢复断点写成 0');

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('播放中采用更新镜像：先停旧音频，不出现界面/声音脱节', () async {
    final (index, player, uuid) = await setup(['/x/a.flac', '/x/b.flac']);
    addTearDown(index.close);
    addTearDown(player.dispose);

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      playlistUuid: uuid,
      contextKey: PlayerProvider.anchorForPlaylist(uuid),
      resetAnchor: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(player.current?.sourceRef, '/x/a.flac');
    expect(player.playing, isTrue);

    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      source: 'webdav',
      sourceRef: '/x/b.flac',
      positionMs: 30000,
      deepListJson: _deepListJson(['/x/a.flac', '/x/b.flac']),
      updatedAt:
          DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
      deviceId: 'other',
    );

    await player.playQueue(
      [_song('/x/a.flac'), _song('/x/b.flac')],
      playlistUuid: uuid,
      contextKey: PlayerProvider.anchorForPlaylist(uuid),
      resetAnchor: true,
      resumeFromBreakpoint: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(player.current?.sourceRef, '/x/b.flac');
    expect(player.playing, isFalse,
        reason: '采用镜像断点后旧音频必须已暂停，不能界面切新曲但声音还是旧曲');
    expect(player.position, const Duration(milliseconds: 30000));

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('已缓存的 SMB/SFTP：桌面允许预载本地缓存文件', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_cache_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final cached = File('${dir.path}/a.flac');
    await cached.writeAsBytes(List<int>.filled(4096, 0));

    PlayerProvider.debugForceRestorePreload = null;
    final (index, player, uuid) = await setup(
      ['/x/a.flac'],
      source: _FakeCachedStreamSource(cached.path),
    );
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );

    await player.restorePreferRemote();
    await player.debugAwaitRestorePreload();
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isNotEmpty, reason: '本地缓存可直接预载');
    expect(fake.players.values.single.playCalls, 0);
    expect(player.position.inMilliseconds, closeTo(10000, 200));

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('SMB/SFTP 原始流：走 MediaProxy loopback URL，不再进自建字节流', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_proxy_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/a.bin');
    await file.writeAsBytes(List<int>.filled(4096, 0));

    PlayerProvider.debugForceRestorePreload = true;
    final (index, player, uuid) = await setup(
      ['/x/a.flac'],
      source: _FakeProxySource(file.path),
    );
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );

    await player.restorePreferRemote();
    await player.debugAwaitRestorePreload();
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isNotEmpty);
    final fakePlayer = fake.players.values.single;
    expect(fakePlayer.lastUri, startsWith('http://127.0.0.1:'),
        reason: 'SMB/SFTP 应由 MediaProxy 提供 loopback URL');
    expect(fakePlayer.playCalls, 0);
    expect(player.playing, isFalse);
    expect(player.position.inMilliseconds, closeTo(10000, 200));

    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('预载安全边界：只剩自建字节流时中止，不构造播放器', () async {
    PlayerProvider.debugForceRestorePreload = true;
    final (index, player, uuid) = await setup(
      ['/x/a.flac'],
      source: _FakeStreamSource(),
    );
    addTearDown(index.close);
    addTearDown(player.dispose);

    await index.savePlayState(
      jsonEncode([_song('/x/a.flac').toJson()]),
      0,
      10000,
      playlistUuid: uuid,
      anchorKey: 'playlist:$uuid',
    );

    await player.restorePreferRemote();
    await player.debugAwaitRestorePreload();
    final fake = JustAudioPlatform.instance as _FakeJustAudio;
    expect(fake.players, isEmpty,
        reason: '门控被强制打开时，预载仍必须拒绝回落到 DirectAudioSource');
    expect(player.playing, isFalse);
    expect(player.position, const Duration(milliseconds: 10000),
        reason: '预载中止后保持乐观断点，等待首次播放');

    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}
