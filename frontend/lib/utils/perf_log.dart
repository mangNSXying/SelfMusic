// 临时性能埋点（冷启动 UI 阻塞定位）：统一输出 `[perf]` 前缀，便于
// hilog / logcat 过滤。定位完成后整体删除本文件与全部调用点。
//
// 纯 Dart 不依赖 foundation：db_writer.dart 明确要求无 Flutter 依赖。

const bool kPerfLog = true;

int _perfBaseMs = 0;

void perfLog(String tag, [Object? extra]) {
  if (!kPerfLog) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (_perfBaseMs == 0) _perfBaseMs = now;
  final rel = now - _perfBaseMs;
  print('[perf] +${rel}ms $tag${extra == null ? '' : ' $extra'}');
}
