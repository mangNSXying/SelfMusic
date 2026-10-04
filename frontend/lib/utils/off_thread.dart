import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// 把纯 Dart 重活（JSON 编解码、大列表建模/分组、目录遍历）放到后台 isolate，
/// 避免阻塞 UI isolate。
///
/// ohos：fork 引擎不能可靠 spawn 子 isolate（见 db_writer 的
/// `_InlineDbWriter` 头注释），退化为同 isolate 执行——与写层口径一致。
Future<T> runOffThread<T>(T Function() body) {
  if (Platform.operatingSystem == 'ohos') {
    return Future<T>.value(body());
  }
  return Isolate.run(body);
}
