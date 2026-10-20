import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/sftp_worker.dart';

/// worker 路径编译期开关矩阵（`SFTP_WORKER_DIRECT` / `SFTP_WORKER_ISOLATE`）。
/// 纯函数解析，不依赖真实平台与 dart-define。
void main() {
  group('SftpWorker 开关解析', () {
    test('SFTP_WORKER_DIRECT：全平台强制旧直连，优先级最高', () {
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: true, workerIsolate: 'true', os: 'linux'),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: true, workerIsolate: 'false', os: 'ohos'),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: true, workerIsolate: '', os: 'android'),
        isFalse,
      );
    });

    test('SFTP_WORKER_ISOLATE：显式指定优先于平台默认', () {
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'false', os: 'android'),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'true', os: 'ohos'),
        isTrue,
      );
    });

    test('都未指定：OHOS 暂关（等 soak 翻默认），其余平台开', () {
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: '', os: 'ohos'),
        isFalse,
      );
      for (final os in ['android', 'linux', 'macos', 'ios', 'windows']) {
        expect(
          SftpWorker.resolveWorkerEnabled(
              forceDirect: false, workerIsolate: '', os: os),
          isTrue,
          reason: os,
        );
      }
    });

    test('其它取值不改变平台默认（只有 true/false 生效）', () {
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: '1', os: 'ohos'),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'yes', os: 'android'),
        isTrue,
      );
    });
  });
}
