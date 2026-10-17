import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 启动先拉后推：`start()` 的首轮只做全量拉（pullOnly）——先掌握远端最新，
/// 积压 outbox 不抢在远端状态之前上推；推由后续全量轮承担：首轮在飞行时 tick
/// 被单飞挡下，收尾后首个 tick 见积压才发全量轮（先推后拉）。断点恢复仍有
/// `pullLatestBreakpoint` 快路径 1 RTT 先行。`awaitFirstPull()` 等在飞行首轮
/// 收尾，不叠加新一轮。Root 只等在飞行首轮收尾。
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

class _CountingApi extends ApiClient {
  int pulls = 0;
  int pushes = 0;

  /// 非空时 pull 挂起直到测试放行：用来观察「在飞行」时的等待语义。
  Completer<void>? pullGate;

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
    final gate = pullGate;
    if (gate != null) await gate.future;
    return {'cursor': cursor + 1, 'has_more': false, 'songs': []};
  }
}

void main() {
  late LocalIndex index;
  late Directory tmp;
  late SyncEngine engine;
  late _CountingApi api;
  late Duration savedTick;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = await Directory.systemTemp.createTemp('selfmusic_startorder_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _CountingApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));

    // 首轮观察期内不让 tick 干扰（tick 补推是另一层保证）。
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(seconds: 30);
  });

  tearDown(() async {
    engine.stop();
    SyncEngine.tickFast = savedTick;
    try {
      await engine.syncNow(force: true); // 收尾：把积压 outbox 推掉
      // _dirty 跟进轮是 unawaited 的：等它跑完才 close，避免 close 后
      // 读写 _writer! 报 NPE。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('start 首轮只拉不推：积压 outbox 不进启动轮，后续全量轮带走', () async {
    await index.enqueueOutbox('song.state', {'a': 1});

    engine.start();

    // 等启动首轮（纯拉）完全收尾。
    var waited = 0;
    while (api.pulls == 0 && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.pulls, greaterThan(0), reason: '启动首轮应立即拉取');
    expect(api.pushes, 0, reason: '冷启动首轮只拉不推：先掌握远端再上报积压');
    expect(await index.pendingOutboxCount(), 1, reason: '积压未被启动轮带走');

    // 后续全量轮（tick/poke/手动同口径）：积压照常先推后拉带走。
    await engine.syncNow(force: true);
    expect(api.pushes, greaterThan(0), reason: '后续全量轮补推积压');
    expect(await index.pendingOutboxCount(), 0, reason: '事件已被全量轮带走');
  });

  test('全量轮顺序：push 先于 pull（旧快照不覆盖本地脏行）', () async {
    final order = <String>[];
    final api = _OrderApi(order);
    final eng = SyncEngine(
        api: api, index: index, settings: AppSettings(index));
    await index.enqueueOutbox('song.state', {'a': 1});

    eng.start();
    // 等启动首轮（纯拉）完全收尾，再验证后续全量轮的推拉顺序。
    var waited = 0;
    while (order.isEmpty && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(order, ['pull'], reason: '冷启动首轮只拉');
    order.clear();

    await eng.syncNow(force: true);
    expect(order, ['push', 'pull'],
        reason: '本机优先：全量轮 push 必须先于 pull，否则旧快照先落库覆盖脏行');
    eng.stop();
  });

  test('awaitFirstPull 同样 pullOnly：启动序不被 push 挡住', () async {
    await index.enqueueOutbox('song.state', {'a': 1});

    await engine.awaitFirstPull();

    expect(api.pulls, greaterThan(0));
    expect(api.pushes, 0, reason: 'awaitFirstPull 只负责把断点拉回来');
    expect(await index.pendingOutboxCount(), 1);
  });

  test('awaitFirstPull 在飞行时只等待，不叠加新一轮（旧 firstPull 会整轮重跑）', () async {
    final gate = Completer<void>();
    api.pullGate = gate;

    engine.start();
    var waited = 0;
    while (api.pulls == 0 && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited++;
    }
    expect(api.pulls, 1, reason: 'start 首轮已发起');

    final waiting = engine.awaitFirstPull();
    gate.complete();
    await waiting;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(api.pulls, 1, reason: '等待在飞行首轮不应再发起新一轮');
    expect(api.pushes, 0, reason: '本轮无积压 outbox，无需上推');
  });
}

/// 记录 push/pull 相对顺序的 Api（全量轮先推后拉顺序断言用）。
class _OrderApi extends ApiClient {
  final List<String> order;
  _OrderApi(this.order);
  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    order.add('push');
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
    order.add('pull');
    return {'cursor': cursor + 1, 'has_more': false, 'songs': []};
  }
}
