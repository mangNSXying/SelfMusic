import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 启动先拉后推（P3）：`start()` 的首轮是 pullOnly——push 不参与断点恢复，
/// 却会多占一个 RTT 挡在启动拉取前面；积压 outbox 由后续全量轮补推。
/// `firstPull()` 同样 pullOnly，启动序里 push 永远排在 pull 之后。
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
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('start 首轮只拉不推，积压 outbox 留给后续全量轮', () async {
    await index.enqueueOutbox('song.state', {'a': 1});

    engine.start();

    // 等首轮（pullOnly）完成。
    var waited = 0;
    while (api.pulls == 0 && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited++;
    }
    expect(api.pulls, greaterThan(0), reason: '启动首轮应立即拉取');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.pushes, 0,
        reason: 'P3：启动首轮先拉后推，push 不该挡在断点拉取前面');
    expect(await index.pendingOutboxCount(), 1, reason: '事件仍积压待补推');

    // 手动全量轮（等价下一 tick 的 pendingOutboxCount>0 触发）→ 补推。
    await engine.syncNow(force: true);
    expect(api.pushes, 1, reason: '积压 outbox 应由全量轮补推');
    expect(await index.pendingOutboxCount(), 0);
  });

  test('firstPull 同样 pullOnly：启动序不被 push 挡住', () async {
    await index.enqueueOutbox('song.state', {'a': 1});

    await engine.firstPull();

    expect(api.pulls, greaterThan(0));
    expect(api.pushes, 0, reason: 'firstPull 只负责把断点拉回来');
    expect(await index.pendingOutboxCount(), 1);
  });
}
