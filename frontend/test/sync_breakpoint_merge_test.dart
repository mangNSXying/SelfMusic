import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
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

class _MergeApi extends ApiClient {
  final List<List<Map<String, dynamic>>> batches = [];
  List<dynamic>? mergedDeepList;
  List<dynamic>? correctionDeepList;
  String correctionSourceRef = '/s.mp3';
  bool v2 = false;
  String v2HeadRef = '/s.mp3';
  String v2Session = 's-remote';
  int v2HeadRev = 3;
  int v2HistoryRev = 4;
  List<dynamic> v2DeepList = const [];

  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';

  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    batches.add(events);
    final merged = <String, dynamic>{};
    final corrections = <String, dynamic>{};
    for (final e in events) {
      if (e['type'] != 'breakpoint.set') continue;
      final payload = e['payload'];
      if (payload is! Map) continue;
      final uuid = e['event_uuid'];
      if (uuid is! String) continue;
      final deep = mergedDeepList;
      if (deep != null) {
        merged[uuid] = {
          'client_uuid': payload['playlist_uuid'],
          'source': payload['source'],
          'source_ref': payload['source_ref'],
          'device_client_id': clientId,
          'position_ms': payload['position_ms'],
          'last_event_at': '2026-01-01T00:00:00',
          'updated_at': '2026-01-01T00:00:00',
          'deep_list': deep,
        };
      }
      final correctionDeep = correctionDeepList;
      if (correctionDeep != null) {
        corrections[uuid] = {
          'client_uuid': payload['playlist_uuid'],
          'source': 'webdav',
          'source_ref': correctionSourceRef,
          'device_client_id': 'other-device',
          'position_ms': 100,
          'last_event_at': '2027-01-01T00:00:00',
          'updated_at': '2027-01-01T00:00:00',
          'deep_list': correctionDeep,
        };
      }
    }
    final breakpoints = <String, dynamic>{};
    if (v2) {
      for (final e in events) {
        if (e['type'] != 'breakpoint.set') continue;
        final payload = e['payload'];
        if (payload is! Map) continue;
        final uuid = payload['playlist_uuid'];
        if (uuid is! String) continue;
        breakpoints[uuid] = {
          'client_uuid': uuid,
          'source': payload['source'] ?? 'webdav',
          'source_ref': v2HeadRef,
          'device_client_id': 'other-device',
          'position_ms': payload['position_ms'] ?? 0,
          'head_rev': v2HeadRev,
          'history_rev': v2HistoryRev,
          'head_clock': '2000-0-other-device',
          'head_device': 'other-device',
          'head_op_id': 'op-remote',
          'head_session': v2Session,
          'head_playing': true,
          'head_updated_at': '2026-01-02T00:00:00',
          'last_event_at': '2026-01-01T00:00:00',
          'updated_at': '2026-01-01T00:00:00',
          'deep_list': v2DeepList,
        };
      }
    }
    return {
      'applied': [
        for (final e in events)
          if (e['event_uuid'] is String) e['event_uuid'] as String
      ],
      'duplicates': [],
      'corrections': corrections,
      'merged': merged,
      'breakpoints': breakpoints,
      if (v2) 'breakpoint_protocol': 2,
      if (v2) 'server_epoch': 'epoch-test',
    };
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    return {
      'cursor': cursor + 1,
      'has_more': false,
      'songs': const [],
      'playlists': const [],
      'sources': const [],
      'playstates': const [],
    };
  }
}

void main() {
  late LocalIndex index;
  late Directory tmp;
  late SyncEngine engine;
  late _MergeApi api;
  late Duration savedTick;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = await Directory.systemTemp.createTemp('selfmusic_bpmerge_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _MergeApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(seconds: 30);
  });

  tearDown(() async {
    engine.stop();
    SyncEngine.tickFast = savedTick;
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('同歌单断点离线多事件只推最新一条，旧事件随 ack 清理', () async {
    final id = await index.createPlaylist('合并歌单');
    final uuid = index.playlistUuidOf(id)!;
    final e1 = await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/a.mp3',
      'position_ms': 1000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
      ],
      'deep_added': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
      ],
    });
    final e2 = await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/b.mp3',
      'position_ms': 2000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
      'deep_added': [
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
    });

    await engine.syncNow(force: true);

    expect(api.batches, hasLength(1));
    expect(api.batches.single, hasLength(1));
    final sent = api.batches.single.single;
    expect(sent['event_uuid'], e2);
    expect(e1, isNot(e2));
    expect(await index.pendingOutbox(), isEmpty,
        reason: '最新事件 ack 后，被合并的旧事件也应删除');
    expect(index.breakpointBaseDeepList(uuid), contains('/b.mp3'));
  });

  test('merged 回执即使设备号是自己也强制落镜像并回调历史合并', () async {
    final id = await index.createPlaylist('合并回执歌单');
    final uuid = index.playlistUuidOf(id)!;
    api.mergedDeepList = [
      {'source': 'webdav', 'source_ref': '/a.mp3'},
      {'source': 'webdav', 'source_ref': '/s.mp3'},
      {'source': 'webdav', 'source_ref': '/b.mp3'},
    ];
    await index.setBreakpointBaseDeepList(
        uuid,
        '[{"source":"webdav","source_ref":"/a.mp3"},'
        '{"source":"webdav","source_ref":"/b.mp3"}]');
    final eventUuid = await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/b.mp3',
      'position_ms': 3000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
      'deep_added': [
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
    });
    Map<String, dynamic>? gotSnapshot;
    List<dynamic>? gotSent;
    var appliedCalls = 0;
    engine.onBreakpointMerged = (snapshot, sent) async {
      gotSnapshot = snapshot;
      gotSent = sent;
    };
    engine.onBreakpointsApplied = () => appliedCalls++;

    await engine.syncNow(force: true);

    expect(gotSnapshot, isNotNull);
    expect(gotSnapshot!['client_uuid'], uuid);
    expect(gotSent, hasLength(2));
    final mirror = index.breakpointMirrorOf(uuid);
    expect(mirror, isNotNull, reason: 'force 绕过时钟，自写 device 也落库');
    expect(mirror!.sourceRef, '/b.mp3');
    // 本测试回调未真正采用历史：base 必须停在本机 sent 分支，不能盲跟
    // 服务端 merged（否则本机旧列表下次会被误判成非追加分支）。
    expect(index.breakpointBaseDeepList(uuid), contains('/b.mp3'));
    expect(index.breakpointBaseDeepList(uuid), isNot(contains('/s.mp3')));
    expect(await index.pendingOutbox(), isEmpty);
    expect(eventUuid, isNotEmpty);
    expect(appliedCalls, 0, reason: 'merged 回执只补历史，不能触发断点套用/seek');
  });

  test('判输 correction 不把 base 推进到服务端赢家（base 只对齐本机列表）', () async {
    final id = await index.createPlaylist('判输歌单');
    final uuid = index.playlistUuidOf(id)!;
    api.correctionDeepList = [
      {'source': 'webdav', 'source_ref': '/a.mp3'},
      {'source': 'webdav', 'source_ref': '/s.mp3'},
    ];
    await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/b.mp3',
      'position_ms': 3000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
      'deep_added': [
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
    });

    await engine.syncNow(force: true);

    final base = index.breakpointBaseDeepList(uuid);
    expect(base, contains('/b.mp3'));
    expect(base, isNot(contains('/s.mp3')),
        reason: 'base 跟本机已采用列表走；服务端赢家留在镜像，等播放器采用后再推进');
    expect(index.breakpointMirrorOf(uuid)!.sourceRef, '/s.mp3');
    expect(await index.pendingOutbox(), isEmpty);
  });
  test('v2 push 回执按 playlist 回调快照并落 head/history 镜像', () async {
    final id = await index.createPlaylist('v2 歌单');
    final uuid = index.playlistUuidOf(id)!;
    api.v2 = true;
    api.v2HeadRef = '/s.mp3';
    api.v2DeepList = [
      {'source': 'webdav', 'source_ref': '/a.mp3'},
      {'source': 'webdav', 'source_ref': '/s.mp3'},
    ];
    await index.enqueueOutbox('breakpoint.set', {
      'playlist_uuid': uuid,
      'protocol': 2,
      'op_id': 'op-local',
      'op_clock': '1000-0',
      'intent': 'play_track',
      'source': 'webdav',
      'source_ref': '/b.mp3',
      'position_ms': 3000,
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
      'base_deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
      ],
    });
    bool? gotV2;
    String? gotEpoch;
    Map<String, dynamic>? gotSnapshot;
    List<dynamic>? gotSent;
    engine.onBreakpointProtocol = (v2, epoch) async {
      gotV2 = v2;
      gotEpoch = epoch;
    };
    engine.onBreakpointSnapshot = (snapshot, sent) async {
      gotSnapshot = snapshot;
      gotSent = sent;
    };

    await engine.syncNow(force: true);

    expect(gotV2, isTrue);
    expect(gotEpoch, 'epoch-test');
    expect(gotSnapshot, isNotNull);
    expect(gotSnapshot!['head_rev'], 3);
    expect(gotSnapshot!['history_rev'], 4);
    expect(gotSnapshot!['head_op_id'], 'op-remote');
    expect(gotSent, hasLength(2), reason: '回调收到本设备刚推的 deep_list');
    final mirror = index.breakpointMirrorOf(uuid)!;
    expect(mirror.headRev, 3);
    expect(mirror.historyRev, 4);
    expect(mirror.headOpId, 'op-remote');
    expect(mirror.headSession, 's-remote');
    expect(mirror.deepListJson, contains('/s.mp3'));
    // v2 的 base 不盲跟回执，必须由播放器在采用历史后推进。
    expect(index.breakpointBaseDeepList(uuid), isNull);
    expect(await index.pendingOutbox(), isEmpty);
  });

  test('v2 镜像版本防护：旧 head 不回退 head，新 history 仍可前进', () async {
    final id = await index.createPlaylist('v2 版本防护');
    final uuid = index.playlistUuidOf(id)!;
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/new.mp3',
      source: 'webdav',
      positionMs: 5000,
      deepListJson: '[{"source":"webdav","source_ref":"/x/a.mp3"}]',
      updatedAt: '2026-01-01T00:00:00',
      headRev: 5,
      historyRev: 2,
      headClock: '5000-0',
      headOpId: 'op-new',
      headSession: 's-new',
      headPlaying: true,
      headUpdatedAt: '2026-01-01T00:00:00',
    );
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/old.mp3',
      source: 'webdav',
      positionMs: 1000,
      deepListJson: '[{"source":"webdav","source_ref":"/x/a.mp3"},'
          '{"source":"webdav","source_ref":"/x/s.mp3"}]',
      updatedAt: '2026-01-02T00:00:00',
      headRev: 4,
      historyRev: 3,
      headClock: '4000-0',
      headOpId: 'op-old',
      headSession: 's-old',
      headPlaying: false,
      headUpdatedAt: '2026-01-02T00:00:00',
    );

    final row = index.breakpointMirrorOf(uuid)!;
    expect(row.headRev, 5);
    expect(row.headOpId, 'op-new');
    expect(row.sourceRef, '/x/new.mp3');
    expect(row.positionMs, 5000);
    expect(row.historyRev, 3);
    expect(row.deepListJson, contains('/x/s.mp3'));
  });

  test('v2 快照缺 deep_list：只更新 head，不清历史也不推进 history_rev', () async {
    final id = await index.createPlaylist('v2 缺 deep');
    final uuid = index.playlistUuidOf(id)!;
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/a.mp3',
      source: 'webdav',
      positionMs: 1000,
      deepListJson: '[{"source":"webdav","source_ref":"/x/a.mp3"}]',
      updatedAt: '2026-01-01T00:00:00',
      headRev: 2,
      historyRev: 2,
      headClock: '2000-0',
      headOpId: 'op-2',
      headSession: 's-2',
      headPlaying: false,
      headUpdatedAt: '2026-01-01T00:00:00',
    );
    await index.upsertBreakpointMirror(
      playlistUuid: uuid,
      sourceRef: '/x/new.mp3',
      source: 'webdav',
      positionMs: 3000,
      deepListJson: null,
      updatedAt: '2026-01-02T00:00:00',
      headRev: 3,
      historyRev: 3,
      headClock: '3000-0',
      headOpId: 'op-3',
      headSession: 's-3',
      headPlaying: true,
      headUpdatedAt: '2026-01-02T00:00:00',
    );

    final row = index.breakpointMirrorOf(uuid)!;
    expect(row.headRev, 3);
    expect(row.sourceRef, '/x/new.mp3');
    expect(row.historyRev, 2, reason: '缺 deep_list 的快照不得推进历史版本');
    expect(row.deepListJson, contains('/x/a.mp3'));
  });

  test('v2 base history_rev 只随显式对齐推进', () async {
    final id = await index.createPlaylist('v2 base rev');
    final uuid = index.playlistUuidOf(id)!;
    const first = '[{"source":"webdav","source_ref":"/x/a.mp3"}]';
    const second = '[{"source":"webdav","source_ref":"/x/a.mp3"},'
        '{"source":"webdav","source_ref":"/x/s.mp3"}]';
    await index.setBreakpointBaseDeepList(uuid, first, historyRev: 4);
    expect(index.breakpointBaseHistoryRev(uuid), 4);
    await index.setBreakpointBaseDeepList(uuid, first);
    expect(index.breakpointBaseHistoryRev(uuid), 4,
        reason: '普通镜像/只落库路径不得无意推进 base revision');
    await index.setBreakpointBaseDeepList(uuid, second, historyRev: 5);
    expect(index.breakpointBaseHistoryRev(uuid), 5);
    expect(index.breakpointBaseDeepList(uuid), contains('/x/s.mp3'));
  });
}
