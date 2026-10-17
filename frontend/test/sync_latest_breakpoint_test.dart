import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 断点快路径（`GET /playstates/latest`，DEVELOPER.md「播放算法与同步协议」）：
/// 1 RTT 直取服务端最新断点 → 落镜像 → 通知播放器套用；
/// 旧服务端无此端点（fetch 返回 null）与网络异常都静默回退到全量 pull，
/// 且不进退避（它是加速器，不是替代）。
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

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_fastbp_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Map<String, dynamic> _playlist() => {
      'client_uuid': 'pl-1',
      'name': '远端歌单',
      'description': null,
      'deleted': false,
      'items': [
        {
          'source_id': 'src-1',
          'source': 'webdav',
          'source_ref': 'dav:/a.mp3',
          'title': 'A',
          'artist': null,
          'album': null,
          'sort_order': 0,
        },
      ],
    };

Map<String, dynamic> _playstate() => {
      'client_uuid': 'pl-1',
      'song_id': null,
      'source_id': 'src-1',
      'source': 'webdav',
      'source_ref': 'dav:/a.mp3',
      'position_ms': 42000,
      'deep_list': [],
      'updated_at': '2026-10-09T12:00:00',
    };

class _FastPathApi extends ApiClient {
  _FastPathApi({this.snapshot, this.throwOnFetch = false});

  Map<String, dynamic>? snapshot;
  bool throwOnFetch;
  int fetches = 0;

  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
  @override
  Future<Map<String, dynamic>?> fetchLatestBreakpoint() async {
    fetches++;
    if (throwOnFetch) throw Exception('network down');
    return snapshot;
  }

  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    return {'applied': [], 'duplicates': []};
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async =>
      {'cursor': cursor + 1, 'has_more': false, 'songs': []};
}

SyncEngine _engine(LocalIndex index, ApiClient api) =>
    SyncEngine(api: api, index: index, settings: AppSettings(index));

void main() {
  test('快路径：本地已有歌单 → 镜像落库并触发回调', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);
    final api = _FastPathApi(snapshot: _playstate());
    final engine = _engine(index, api);
    var fired = 0;
    engine.onBreakpointsApplied = () => fired++;

    await engine.pullLatestBreakpoint();

    expect(api.fetches, 1);
    expect(fired, 1);
    final mirror = index.breakpointMirrorOf('pl-1');
    expect(mirror, isNotNull);
    expect(mirror!.positionMs, 42000);
    expect(engine.lastError, isEmpty);

    engine.stop();
    index.close();
  });

  test('快路径：旧服务端无此端点（null）→ 静默回退，不通知', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);
    final api = _FastPathApi(snapshot: null);
    final engine = _engine(index, api);
    var fired = 0;
    engine.onBreakpointsApplied = () => fired++;

    await engine.pullLatestBreakpoint();

    expect(fired, 0);
    expect(index.breakpointMirrorOf('pl-1'), isNull);
    expect(engine.lastError, isEmpty, reason: '失败不进退避，全量 pull 兜底');

    engine.stop();
    index.close();
  });

  test('快路径：网络异常 → 吞掉不抛，不进退避', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);
    final api = _FastPathApi(snapshot: _playstate(), throwOnFetch: true);
    final engine = _engine(index, api);
    var fired = 0;
    engine.onBreakpointsApplied = () => fired++;

    await engine.pullLatestBreakpoint(); // 不应抛出

    expect(fired, 0);
    expect(engine.lastError, isEmpty);

    engine.stop();
    index.close();
  });

  test('快路径：歌单未同步 → 镜像被丢弃，不通知', () async {
    final index = await _openIndex();
    // 刻意不建歌单（全新设备 / 歌单尚未 pull 到）。
    final api = _FastPathApi(snapshot: _playstate());
    final engine = _engine(index, api);
    var fired = 0;
    engine.onBreakpointsApplied = () => fired++;

    await engine.pullLatestBreakpoint();

    expect(index.breakpointMirrorOf('pl-1'), isNull);
    expect(fired, 0, reason: '镜像没落库就没有可套用的断点，不该惊动播放器');

    engine.stop();
    index.close();
  });

  test('快路径：自写回声（本设备 device_client_id）→ 不落镜像不通知', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);
    final api = _FastPathApi(
        snapshot: {..._playstate(), 'device_client_id': 'test-client'});
    final engine = _engine(index, api);
    var fired = 0;
    engine.onBreakpointsApplied = () => fired++;

    await engine.pullLatestBreakpoint();

    expect(api.fetches, 1);
    expect(fired, 0, reason: '自写回声不该惊动播放器（本机状态不旧于它）');
    expect(index.breakpointMirrorOf('pl-1'), isNull,
        reason: '本设备推上去的断点再拉回来：不入镜像（回退旧曲回路的一环）');

    engine.stop();
    index.close();
  });

  test('快路径：他人快照落库带上来源设备与最后操作时间（F2/F4 字段）', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);
    final api = _FastPathApi(snapshot: {
      ..._playstate(),
      'device_client_id': 'other-client',
      'updated_at': '2026-10-09T12:00:10',
      'last_event_at': '2026-10-09T11:59:30',
    });
    final engine = _engine(index, api);

    await engine.pullLatestBreakpoint();

    final mirror = index.breakpointMirrorOf('pl-1');
    expect(mirror, isNotNull);
    expect(mirror!.deviceId, 'other-client');
    expect(mirror.lastEventAt, '2026-10-09T11:59:30');
    expect(mirror.compareClock, '2026-10-09T11:59:30',
        reason: '比较时钟取最后操作时间，不取上传时间 updated_at');

    engine.stop();
    index.close();
  });

  test('镜像写入守卫：以 last_event_at 为时钟（updated_at 只诊断不参与）', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);

    Map<String, dynamic> snap(String ref, String at, {String? lastEvent}) => {
          'client_uuid': 'pl-1',
          'source': 'webdav',
          'source_ref': ref,
          'position_ms': 111,
          'deep_list': [],
          'updated_at': at,
          if (lastEvent != null) 'last_event_at': lastEvent,
        };
    String ref() => index.breakpointMirrorOf('pl-1')!.sourceRef!;

    await index.applyPlaystateMirror(
        snap('a', '2026-01-01T00:00:20', lastEvent: '2026-01-01T00:00:05'));
    expect(ref(), 'a');

    // 上传时间更晚但最后操作时间更早 → 是旧事件，不得覆盖
    // （修复前按 updated_at 比较会误覆盖，把旧断点写回来）。
    await index.applyPlaystateMirror(
        snap('b', '2026-01-01T00:00:30', lastEvent: '2026-01-01T00:00:01'));
    expect(ref(), 'a', reason: '比较只看最后操作时间：updated_at 更新也压不过旧事件');

    // 最后操作时间更新 → 覆盖（即便上传时间更早）。
    await index.applyPlaystateMirror(
        snap('c', '2026-01-01T00:00:15', lastEvent: '2026-01-01T00:00:09'));
    expect(ref(), 'c');

    // 旧数据（无 last_event_at）回退 updated_at 比较：更早不覆盖、更晚覆盖。
    await index.applyPlaystateMirror(snap('d', '2026-01-01T00:00:08'));
    expect(ref(), 'c');
    await index.applyPlaystateMirror(snap('e', '2026-01-01T00:00:12'));
    expect(ref(), 'e');

    index.close();
  });

  test('镜像写入守卫：更新覆盖、更早不覆盖（最新时间）', () async {
    final index = await _openIndex();
    await index.applyPlaylistSnapshots([_playlist()]);

    Map<String, dynamic> snap(List<String> refs, String at) => {
          'client_uuid': 'pl-1',
          'source': 'webdav',
          'source_ref': refs.isEmpty ? 'dav:/a.mp3' : refs.last,
          'position_ms': 111,
          'deep_list': [
            for (final r in refs) {'source': 'webdav', 'source_ref': r}
          ],
          'updated_at': at,
        };
    String ref() => index.breakpointMirrorOf('pl-1')!.sourceRef!;

    await index.applyPlaystateMirror(snap(['a'], '2026-01-01T00:00:01'));
    expect(ref(), 'a');

    // 更新 → 覆盖（即便历史更短）。
    await index.applyPlaystateMirror(snap([], '2026-01-01T00:00:09'));
    expect(ref(), 'dav:/a.mp3', reason: '更新的镜像应覆盖');

    // 更早 → 不覆盖（即便历史更长）。
    await index.applyPlaystateMirror(snap(['a', 'b'], '2026-01-01T00:00:00'));
    expect(ref(), 'dav:/a.mp3', reason: '更早的镜像不得覆盖');

    index.close();
  });
}
