import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

/// 后台不该有同步轮询：start() 的 2s 定时器此前永不取消（stop() 全项目无人
/// 调用），应用退到后台后仍每 2s 醒来做网络 IO——后台没有前台服务撑着，
/// 纯烧流量/电，Android 后台限制下还大概率失败重试。
/// 前台服务只为播放而开，不该把同步顺带拖进后台。
///
/// 业务副作用：退后台期间积压的 outbox 不再上传，改为回前台补一轮。
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

/// 记录拉取次数，用来确认某段时间内确实（没）发生同步。
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
    return {'applied': [], 'duplicates': []};
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
    tmp = await Directory.systemTemp.createTemp('selfmusic_syncbg_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _CountingApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));

    // 周期缩到 10ms：断言「后台不再发起同步」不必真等生产的 2s。
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(milliseconds: 10);
  });

  tearDown(() async {
    engine.stop();
    engine.setPlaying(false);
    SyncEngine.tickFast = savedTick;
    // 等飞行中的那一轮收尾：否则 close() 把写隔离置空后它再落库 settings 会撞
    // LocalIndex.settingsSet 里的 _writer!（被 _run 的 catch 吞成「同步失败」，
    // 顺带把退避计数推高，后续断言就不稳了）。
    try {
      await engine.syncNow();
      // _dirty 跟进轮是 unawaited 的：再让一拍，等它跑完才 close，
      // 否则它在 close 后读写 _writer! 报 NPE（仅日志噪音，但 deterministic）。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('前台：定时器驱动周期性同步', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pulls, greaterThan(0), reason: '前台应周期性同步');
  });

  test('后台（pause）：定时器停摆，不再有任何同步', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pulls, greaterThan(0), reason: '前置条件：前台确实在同步');

    engine.pause();
    final pullsBefore = api.pulls;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pulls, pullsBefore,
        reason: '退后台后不应再发起同步（烧流量/电，且后台必失败重试）');
    expect(engine.isPolling, isFalse);
  });

  test('回前台（resume）：补一轮，积压的 outbox 传上去', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    engine.pause();

    // 退后台期间产生一条待上推事件：后台定时器停着，它不该被推走。
    await index.enqueueOutbox('song.state', {'a': 1});
    final pushesBefore = api.pushes;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pushes, pushesBefore,
        reason: '后台期间不应上推（outbox 应当积压）');
    expect(await index.pendingOutboxCount(), 1, reason: '事件应仍积压着');

    engine.resume();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pushes, greaterThan(pushesBefore),
        reason: '回前台应立刻补推积压的 outbox');
    expect(engine.isPolling, isTrue);
  });

  test('后台播放中（pause + setPlaying(true)）：继续同步', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pulls, greaterThan(0), reason: '前置条件：前台确实在同步');

    // 退后台但仍在播放：定时器不该停（前台服务保活下网络可用）。
    engine.pause();
    engine.setPlaying(true);
    expect(engine.isPolling, isTrue, reason: '播放中后台应保持轮询');
    // 后台播放产生的新事件应被推走（用 pushes 断言：30s 拉间隔内 tick
    // 只在有积压时才发起同步）。
    await index.enqueueOutbox('song.state', {'a': 1});
    final pushesBefore = api.pushes;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pushes, greaterThan(pushesBefore),
        reason: '播放中后台应继续同步（断点/权重收敛）');

    // 播完/暂停：回落到停表。
    engine.setPlaying(false);
    expect(engine.isPolling, isFalse, reason: '后台且未播放应停表');
    // 停表时可能有一轮同步已在飞行（或 _dirty 收尾补跑）；先等它结束再取基准，
    // 否则会把「停表前已排队的一轮」误判为停表后仍在轮询（全量套件下偶发）。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final pullsAfterStop = api.pulls;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.pulls, pullsAfterStop, reason: '停播后后台不再发起同步');
  });

  test('后台启动后开播（start 前已 pause + setPlaying(true)）：起表', () async {
    engine.pause();
    engine.start();
    expect(engine.isPolling, isFalse, reason: '后台且未播放不应轮询');

    engine.setPlaying(true);
    expect(engine.isPolling, isTrue, reason: '后台开播应开始轮询');
    engine.setPlaying(false);
  });

  test('poke：关键操作后即时同步一轮（合并单飞，不叠加定时器）', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final pullsBefore = api.pulls;
    engine.poke();
    var waited = 0;
    while (api.pulls == pullsBefore && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited++;
    }
    expect(api.pulls, greaterThan(pullsBefore),
        reason: 'poke 应立即触发一轮同步（播放/暂停/切歌）');
    expect(engine.isPolling, isTrue);
  });

  test('setPlaying 幂等，不叠加定时器', () async {
    engine.start();
    engine.setPlaying(true);
    engine.setPlaying(true);
    expect(engine.isPolling, isTrue);
    engine.pause();
    expect(engine.isPolling, isTrue, reason: '播放中后台保持轮询');
    engine.setPlaying(false);
    expect(engine.isPolling, isFalse);
  });

  test('pause/resume 幂等，不叠加定时器', () async {
    engine.start();
    expect(engine.isPolling, isTrue);

    engine.pause();
    engine.pause();
    expect(engine.isPolling, isFalse);

    engine.resume();
    engine.resume();
    expect(engine.isPolling, isTrue, reason: '重复 resume 不应叠加定时器');
  });

  test('后台启动（start 前已 pause）不起表，等 resume', () async {
    engine.pause();
    engine.start();
    expect(engine.isPolling, isFalse,
        reason: '后台收到 start 应等回前台，而不是照样轮询');

    engine.resume();
    expect(engine.isPolling, isTrue);
  });
}