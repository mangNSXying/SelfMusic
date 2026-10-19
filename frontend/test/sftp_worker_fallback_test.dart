import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/sftp_common.dart';
import 'package:selfmusic/data/sources/sftp_worker.dart';

/// worker 启动失败自动降级旧直连（不依赖真实 SFTP 服务端）：
/// - 首次启动失败：本次操作立即转旧直连，不把启动错误抛给播放链路；
/// - 连续 2 次失败：该实例永久降级，后续操作不再尝试 spawn；
/// - 降级只在「命令未下发」时发生（由传输层保证，这里验证错误来源）。
void main() {
  tearDown(() {
    SftpIsolateTransport.debugStartOverride = null;
  });

  /// 未监听端口：旧直连建连会立即失败，用来区分「走到了直连」。
  SftpIsolateTransport buildTransport() => SftpIsolateTransport(
        host: '127.0.0.1',
        port: 1,
        username: 'u',
        authMethod: SftpAuthMethod.password,
        password: 'p',
        keyPem: '',
        keyPassphrase: '',
        pinnedFp: 'SHA256:test',
      );

  Future<Object?> captureError(Future<void> Function() op) async {
    try {
      await op();
      return null;
    } catch (e) {
      return e;
    }
  }

  test('worker 启动失败：当次转旧直连，连续 2 次后永久降级', () async {
    var spawns = 0;
    SftpIsolateTransport.debugStartOverride = () async {
      spawns++;
      throw const SftpWorkerUnavailableException('测试注入：spawn 失败');
    };
    final transport = buildTransport();

    // 第 1 次：spawn 失败 → 当次操作已转旧直连（错误来自直连而非 worker）。
    final err1 = await captureError(() => transport.probe('/a'));
    expect(spawns, 1);
    expect(err1, isA<SftpStatusException>());
    expect(err1, isNot(isA<SftpWorkerUnavailableException>()));

    // 第 2 次：仍给 worker 一次机会（瞬态失败不立刻永久降级）。
    final err2 = await captureError(() => transport.probe('/a'));
    expect(spawns, 2);
    expect(err2, isA<SftpStatusException>());
    expect(err2, isNot(isA<SftpWorkerUnavailableException>()));

    // 第 3 次起：已永久降级，不再 spawn，直接走旧直连。
    final err3 = await captureError(() => transport.probe('/a'));
    expect(spawns, 2);
    expect(err3, isA<SftpStatusException>());
    expect(err3, isNot(isA<SftpWorkerUnavailableException>()));

    await transport.close();
  });

  test('upload：启动失败发生在消费源流之前，可整次转旧直连', () async {
    SftpIsolateTransport.debugStartOverride = () async {
      throw const SftpWorkerUnavailableException('测试注入：spawn 失败');
    };
    final transport = buildTransport();

    // 若源流已被 worker 路径消费，直连再挂同一条流会抛 StateError
    // （Stream has already been listened to）；这里必须仍是直连错误。
    final err = await captureError(() =>
        transport.upload('/x.mp3', Stream<List<int>>.value([1, 2, 3]), 3));
    expect(err, isA<SftpStatusException>());
    expect(err, isNot(isA<SftpWorkerUnavailableException>()));

    await transport.close();
  });
}
