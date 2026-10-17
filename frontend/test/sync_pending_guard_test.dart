import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/sync_entity_key.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 本机优先：pull 快照命中“本地还有未推事件”的实体时跳过，不覆盖本地脏行；
/// push ack 后下一轮自然收敛。
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

/// 可配 pull 快照的 Api：push 全部 ack（applied 原样返回）。
class _GuardApi extends ApiClient {
  int pulls = 0;
  int pushes = 0;
  List<Map<String, dynamic>> pullSongs = const [];
  List<Map<String, dynamic>> pullPlaylists = const [];
  List<Map<String, dynamic>> pullSources = const [];
  List<Map<String, dynamic>> pullStates = const [];

  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    pushes++;
    return {
      'applied': [
        for (final e in events)
          if (e['event_uuid'] is String) e['event_uuid'] as String
      ],
      'duplicates': [],
    };
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    pulls++;
    return {
      'cursor': cursor + 1,
      'has_more': false,
      'songs': pullSongs,
      'playlists': pullPlaylists,
      'sources': pullSources,
      'playstates': pullStates,
    };
  }
}

void main() {
  late LocalIndex index;
  late Directory tmp;
  late SyncEngine engine;
  late _GuardApi api;
  late Duration savedTick;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = await Directory.systemTemp.createTemp('selfmusic_pendingguard_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _GuardApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(seconds: 30);
  });

  tearDown(() async {
    engine.stop();
    SyncEngine.tickFast = savedTick;
    try {
      await engine.syncNow(force: true);
      // _dirty 跟进轮是 unawaited 的：等它跑完才 close，避免 close 后
      // 读写 _writer! 报 NPE。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('entityKey 与服务端同规则：song legacy 回退 / 歌单双键 / 断点', () {
    expect(
        syncEntityKey('song.liked', {
          'source_id': 'uuid-1',
          'source_ref': '/a.mp3',
        }),
        'song|uuid-1|/a.mp3');
    expect(
        syncEntityKey('song.state', {
          'source': 'webdav',
          'source_ref': '/m/b.flac',
        }),
        'song|legacy:webdav|/m/b.flac');
    // server 占位按空键（只用于比较，不建行）
    expect(
        syncEntityKey('song.skip', {
          'source': 'server',
          'source_ref': '/x.mp3',
        }),
        'song||/x.mp3');
    expect(syncEntityKey('song.skip', {}), isNull);
    expect(
        syncEntityKey('playlist.update', {'client_uuid': 'p-1'}),
        'playlist|p-1');
    expect(
        syncEntityKey('playlist.item_add', {'playlist_uuid': 'p-2'}),
        'playlist|p-2');
    expect(
        syncEntityKey('breakpoint.set', {'playlist_uuid': 'p-3'}),
        'breakpoint|p-3');
    expect(
        syncEntityKey('source.update', {'client_uuid': 's-1'}),
        'source|s-1');
    expect(syncEntityKey('unknown.type', {'a': 1}), isNull);
  });

  test('歌曲：有未推事件时旧快照不覆盖本地脏行，ack 后收敛', () async {
    // 本地脏行：喜欢 + 1.5。
    await index.applySongSnapshot(
      songRef: 'g/x.flac',
      source: 'webdav',
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.5,
      frozen: false,
      favorite: true,
    );
    // 未推事件（同身份）。
    final uuid = await index.enqueueOutbox('song.liked', {
      'source_id': 'uuid-9',
      'source': 'webdav',
      'source_ref': 'g/x.flac',
    });
    // 远端旧快照（同身份不喜欢 + 一个干净实体）。
    api.pullSongs = [
      {
        'source_id': 'uuid-9',
        'source': 'webdav',
        'source_ref': 'g/x.flac',
        'like_streak': 0,
        'dislike_streak': 0,
        'weight': 1.0,
        'frozen': false,
        'is_favorite': false,
        'play_sec': 0,
      },
      {
        'source_id': 'uuid-clean',
        'source': 'webdav',
        'source_ref': 'c/y.flac',
        'like_streak': 0,
        'dislike_streak': 0,
        'weight': 1.5,
        'frozen': false,
        'is_favorite': true,
        'play_sec': 0,
      },
    ];

    // pullOnly：push 不执行，guard 生效。
    await engine.syncNow(pullOnly: true, force: true);

    expect(index.playMetaOf('server', 'g/x.flac').favorite, isTrue,
        reason: '有未推事件的歌：旧快照不得覆盖本地脏行');
    expect(index.playMetaOf('server', 'g/x.flac').factor, 1.5);
    expect(index.playMetaOf('server', 'c/y.flac').favorite, isTrue,
        reason: '无未推事件的干净实体照常收敛');

    // push ack（删队）后下一轮收敛到远端。
    await index.deleteOutbox([uuid]);
    await engine.syncNow(pullOnly: true, force: true);
    expect(index.playMetaOf('server', 'g/x.flac').favorite, isFalse,
        reason: 'ack 后 guard 解除，远端快照正常落库');
  });

  test('歌单：有未推改名时旧快照不覆盖，ack 后收敛', () async {
    final id = await index.createPlaylist('本地名');
    final uuid = index.playlistUuidOf(id)!;
    final pending = await index.enqueueOutbox('playlist.update', {
      'client_uuid': uuid,
      'name': '本地新名',
    });
    api.pullPlaylists = [
      {
        'client_uuid': uuid,
        'name': '远端旧名',
        'description': null,
        'deleted': false,
        'items': [],
      },
    ];

    await engine.syncNow(pullOnly: true, force: true);
    expect(
        index.listPlaylists().firstWhere((p) => p.id == id).name, '本地名',
        reason: '有未推事件的歌单：旧快照不得覆盖');

    await index.deleteOutbox([pending]);
    await engine.syncNow(pullOnly: true, force: true);
    expect(index.listPlaylists().firstWhere((p) => p.id == id).name,
        '远端旧名');
  });

  test('断点：有未推 breakpoint.set 时旧镜像不落库，ack 后收敛', () async {
    final id = await index.createPlaylist('断点歌单');
    final uuid = index.playlistUuidOf(id)!;
    final pending = await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/a.mp3',
      'position_ms': 1000,
    });
    api.pullStates = [
      {
        'client_uuid': uuid,
        'source': 'webdav',
        'source_ref': '/b.mp3',
        'position_ms': 99999,
        'updated_at': '2026-01-01T00:00:00',
        'deep_list': [],
      },
    ];

    await engine.syncNow(pullOnly: true, force: true);
    expect(index.breakpointMirrorOf(uuid), isNull,
        reason: '有未推断点事件时旧镜像不得落库');

    await index.deleteOutbox([pending]);
    await engine.syncNow(pullOnly: true, force: true);
    expect(index.breakpointMirrorOf(uuid)!.positionMs, 99999);
  });

  test('断点：自写回声（device=本设备）不入镜像；他人快照照常收敛（F2）', () async {
    final id = await index.createPlaylist('回声歌单');
    final uuid = index.playlistUuidOf(id)!;
    api.pullStates = [
      {
        'client_uuid': uuid,
        'source': 'webdav',
        'source_ref': '/self.mp3',
        'position_ms': 111,
        'updated_at': '2026-01-01T00:00:10',
        'last_event_at': '2026-01-01T00:00:05',
        'device_client_id': 'test-client',
        'deep_list': [],
      },
    ];
    await engine.syncNow(pullOnly: true, force: true);
    expect(index.breakpointMirrorOf(uuid), isNull,
        reason: '本设备自己的断点快照不回流（本机状态不旧于它）');

    api.pullStates = [
      {
        'client_uuid': uuid,
        'source': 'webdav',
        'source_ref': '/other.mp3',
        'position_ms': 222,
        'updated_at': '2026-01-01T00:00:20',
        'last_event_at': '2026-01-01T00:00:15',
        'device_client_id': 'other-client',
        'deep_list': [],
      },
    ];
    await engine.syncNow(pullOnly: true, force: true);
    final mirror = index.breakpointMirrorOf(uuid);
    expect(mirror, isNotNull, reason: '他人设备的快照照常落库');
    expect(mirror!.positionMs, 222);
    expect(mirror.deviceId, 'other-client');
    expect(mirror.lastEventAt, '2026-01-01T00:00:15');
    expect(mirror.compareClock, '2026-01-01T00:00:15');
  });

  test('播放源：有未推事件时旧快照不建行，ack 后收敛', () async {
    final pending = await index.enqueueOutbox('source.create', {
      'client_uuid': 'src-1',
      'kind': 'webdav',
      'name': '本地源',
      'address': 'https://x/dav',
    });
    api.pullSources = [
      {
        'client_uuid': 'src-1',
        'kind': 'webdav',
        'name': '远端旧名',
        'address': 'https://x/dav',
        'config': {},
        'enabled': true,
        'deleted': false,
      },
    ];

    await engine.syncNow(pullOnly: true, force: true);
    expect(index.listSources().where((s) => s.name == '远端旧名'), isEmpty,
        reason: '有未推事件的源：旧快照不得建行');

    await index.deleteOutbox([pending]);
    await engine.syncNow(pullOnly: true, force: true);
    expect(index.listSources().where((s) => s.name == '远端旧名'),
        isNotEmpty);
  });
}
