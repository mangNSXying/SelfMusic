import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// 测试中强制走真实后台 isolate（默认测试环境内联）：
/// widget 测试跑在 FakeAsync 区域，子 isolate 的回包不会在 pump 期间送达，
/// `pumpAndSettle` 会一直等不到异步 loading 结束。纯 Dart 测试需要验证
/// isolate 路径时把它置 true（`library_snapshot_test`）。
bool forceOffThreadIsolateInTests = false;

/// 把纯 Dart 重活（JSON 编解码、大列表建模/分组、目录遍历）放到后台 isolate，
/// 避免阻塞 UI isolate。
///
/// ohos：fork 引擎不能可靠 spawn 子 isolate（见 db_writer 的
/// `_InlineDbWriter` 头注释），退化为同 isolate 执行——与写层口径一致。
/// 测试环境默认同样内联（见 [forceOffThreadIsolateInTests]）。
Future<T> runOffThread<T>(T Function() body) {
  if (!forceOffThreadIsolateInTests &&
      (Platform.operatingSystem == 'ohos' ||
          Platform.environment.containsKey('FLUTTER_TEST'))) {
    return Future<T>.value(body());
  }
  return Isolate.run(body);
}
