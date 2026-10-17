// 临时性能埋点（冷启动 UI 阻塞定位）：统一输出 `[perf]` 前缀，便于
// hilog / logcat 过滤。定位完成后整体删除本文件与全部调用点。
//
// 纯 Dart 不依赖 foundation：db_writer.dart 明确要求无 Flutter 依赖。
//
// 控制台输出走 `print`（logcat/hilog 可见）；App 内「收集日志」导出依赖
// [perfLogSink]——由 LogBuffer.init() 注入（本文件不能反向 import Flutter 侧）。
// 未注入（如写隔离 isolate 内）时仅控制台输出。

const bool kPerfLog = true;

/// 额外日志出口（注入后每行 `[perf] ...` 原文一并交予，如 LogBuffer）。
/// 默认 null：只走控制台，不影响纯 Dart 场景。
void Function(String line)? perfLogSink;

int _perfBaseMs = 0;

void perfLog(String tag, [Object? extra]) {
  if (!kPerfLog) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (_perfBaseMs == 0) _perfBaseMs = now;
  final rel = now - _perfBaseMs;
  final line = '[perf] +${rel}ms $tag${extra == null ? '' : ' $extra'}';
  print(line);
  perfLogSink?.call(line);
}
