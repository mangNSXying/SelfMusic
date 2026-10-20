import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/sftp_worker.dart';

/// worker 路径编译期开关矩阵（`SFTP_WORKER_DIRECT` / `SFTP_WORKER_ISOLATE`）。
/// 纯函数解析，不依赖真实平台与 dart-define。
/// 2026-10-20 起全平台（含 OHOS）默认启用 worker。
void main() {
  group('SftpWorker 开关解析', () {
    test('SFTP_WORKER_DIRECT=true：全平台强制旧直连，优先级最高', () {
      expect(
        SftpWorker.resolveWorkerEnabled(forceDirect: true, workerIsolate: ''),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: true, workerIsolate: 'true'),
        isFalse,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: true, workerIsolate: 'false'),
        isFalse,
      );
    });

    test('SFTP_WORKER_ISOLATE=false：显式关闭 worker', () {
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'false'),
        isFalse,
      );
    });

    test('默认全平台启用 worker（含 OHOS）', () {
      expect(
        SftpWorker.resolveWorkerEnabled(forceDirect: false, workerIsolate: ''),
        isTrue,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'true'),
        isTrue,
      );
    });

    test('其它取值按默认（只有 false 显式关闭、DIRECT 显式回退）', () {
      expect(
        SftpWorker.resolveWorkerEnabled(forceDirect: false, workerIsolate: '1'),
        isTrue,
      );
      expect(
        SftpWorker.resolveWorkerEnabled(
            forceDirect: false, workerIsolate: 'yes'),
        isTrue,
      );
    });
  });
}
