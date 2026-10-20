import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// 测试中强制走真实后台 isolate（默认测试环境内联）：
/// widget 测试跑在 FakeAsync 区域，子 isolate 的回包不会在 pump 期间送达，
/// `pumpAndSettle` 会一直等不到异步 loading 结束。纯 Dart 测试需要验证
/// isolate 路径时把它置 true（`library_snapshot_test`）。
bool forceOffThreadIsolateInTests = false;

/// 编译期强制内联（应急回退）：`--dart-define=OFF_THREAD_DIRECT=true`。
const bool forceOffThreadDirect = bool.fromEnvironment('OFF_THREAD_DIRECT');

/// 把纯 Dart 重活（JSON 编解码、大列表建模/分组、目录遍历）放到后台 isolate，
/// 避免阻塞 UI isolate。
///
/// 全平台（含 OHOS）走真实后台 isolate；测试环境默认内联（见
/// [forceOffThreadIsolateInTests]）。OHOS 子 isolate 可用已由 `runScan`
/// 与 SFTP 长活 worker 真机验证；涉及 sqlite3 的调用点在子 isolate 内通过
/// `openIsolateDatabase` 重新注入 OHOS override，不依赖主 isolate 的
/// `open.overrideForAll`。
///
/// **调用点复核（R-5，T014）**：全部调用点均为**启动/刷新/落库后处理**，不在
/// 过渡/滚动动画的每帧路径上——
/// - `local_index`：启动一次性回填重置、库快照 / 歌手分组（后台 isolate 建模）；
/// - `library_provider`：库加载与快照刷新（首帧后 postFrame 触发，仅数据变更时）；
/// - `cover_thumb`：非 ohos 纯 Dart 缩略图编码（ohos 走原生桥，不经此路径）。
/// 因此无需把现有调用改为分帧；若后续新增**动画/滚动敏感路径**上的长同步块，
/// 应改用 [runChunked]（`utils/chunked_scheduler.dart`）切片让出，或继续放到
/// 子 isolate，避免任何平台上的根 isolate 长块。
Future<T> runOffThread<T>(T Function() body) {
  if (forceOffThreadDirect ||
      (!forceOffThreadIsolateInTests &&
          Platform.environment.containsKey('FLUTTER_TEST'))) {
    return Future<T>.value(body());
  }
  return Isolate.run(body);
}
