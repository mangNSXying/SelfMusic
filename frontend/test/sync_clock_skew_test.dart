import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 时钟校准：push/pull 回包带 `server_time`，引擎据此更新偏移，
/// 后续入队时间戳按偏移修正；修正值回跳时本机单调 guard 兜住。
/// 旧服务端无该字段时退化为本地钟。
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

/// 回包时间可配的 Api：serverOffset 为空表示旧服务端（无 server_time）。
class _SkewApi extends ApiClient {
  Duration? serverOffset = Duration.zero;
  int pulls = 0;
  int pushes = 0;

  String? _serverTime() {
    final off = serverOffset;
    if (off == null) return null;
    return DateTime.now().add(off).toIso8601String();
  }

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
      'server_time': _serverTime(),
    };
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    pulls++;
    return {
      'cursor': cursor + 1,
      'has_more': false,
      'songs': [],
      'server_time': _serverTime(),
    };
  }
}

void main() {
  late LocalIndex index;
  late Directory tmp;
  late SyncEngine engine;
  late _SkewApi api;
  late Duration savedTick;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = await Directory.systemTemp.createTemp('selfmusic_clockskew_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _SkewApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(seconds: 30);
  });

  tearDown(() async {
    engine.stop();
    SyncEngine.tickFast = savedTick;
    try {
      await engine.syncNow(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('服务端快 5 分钟：后续入队时间戳按偏移修正', () async {
    api.serverOffset = const Duration(minutes: 5);
    final before = DateTime.now();
    // 空 outbox 时 push 早退无回包，但 pull 照常更新偏移。
    await engine.syncNow(force: true);
    expect(api.pulls, greaterThan(0));

    await index.enqueueOutbox('song.liked', {'a': 1});
    final row = (await index.pendingOutbox()).single;
    final occurred = DateTime.parse(row.occurredAt);
    final skew = occurred.difference(before);
    // 修正后 ≈ +5min（容差 60s：测试机调度抖动）。
    expect(skew.inSeconds, greaterThan(4 * 60));
    expect(skew.inSeconds, lessThan(6 * 60));
  });

  test('旧服务端（无 server_time）：退化为本地钟', () async {
    api.serverOffset = null;
    final before = DateTime.now();
    await engine.syncNow(force: true);

    await index.enqueueOutbox('song.liked', {'a': 1});
    final row = (await index.pendingOutbox()).single;
    final skew = DateTime.parse(row.occurredAt).difference(before);
    expect(skew.inSeconds.abs(), lessThan(60));
  });

  test('偏移回跳：本机单调 guard 兜住（后入队不早于前入队）', () async {
    api.serverOffset = const Duration(minutes: -10);
    await engine.syncNow(force: true);
    await index.enqueueOutbox('song.liked', {'a': 1});
    final first =
        DateTime.parse((await index.pendingOutbox()).single.occurredAt);

    // 服务端时间回跳（或换网/校时）：修正值会更小，guard 应抬到上次 +1ms。
    api.serverOffset = const Duration(minutes: -20);
    await engine.syncNow(force: true);
    await index.enqueueOutbox('song.liked', {'b': 2});
    final rows = await index.pendingOutbox();
    final second = DateTime.parse(rows.last.occurredAt);

    expect(second.isAfter(first), isTrue,
        reason: '同设备事件时间戳必须单调递增，否则服务端 LWW 自家乱序');
  });

  test('push 回包同样更新偏移（有积压时首轮即修正）', () async {
    api.serverOffset = const Duration(minutes: 5);
    await index.enqueueOutbox('song.liked', {'a': 1});
    await engine.syncNow(force: true);
    expect(api.pushes, 1);

    await index.enqueueOutbox('song.liked', {'b': 2});
    final rows = await index.pendingOutbox();
    final skew =
        DateTime.parse(rows.last.occurredAt).difference(DateTime.now());
    expect(skew.inSeconds, greaterThan(4 * 60));
  });
}
