import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 简易应用内日志缓冲区：捕获 [debugPrint]/[print] 输出，按时间保留最近
/// 的日志条目，用于「收集日志」功能导出最近一分钟的日志。
class LogEntry {
  final DateTime time;
  final String level;
  final String message;

  LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  String toLine() {
    final ts = _formatTime(time);
    return '[$ts][$level] $message';
  }

  static String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// 日志缓冲管理器（单例）。
class LogBuffer {
  LogBuffer._internal();

  static final LogBuffer instance = LogBuffer._internal();

  /// 最大保留日志行数（环形裁剪，避免内存无限增长）。
  static const int _maxEntries = 5000;

  final List<LogEntry> _entries = <LogEntry>[];

  /// 初始是否已完成（用于避免重复初始化）。
  bool _initialized = false;

  /// 初始化日志缓冲：劫持 [debugPrint] 与 [print]，并接入未处理异常。
  void init() {
    if (_initialized) return;
    _initialized = true;

    // 保存原始 debugPrint，既保留 Flutter 调试行为，也能写入缓冲区。
    final originalDebugPrint = debugPrint;

    debugPrint = (String? message, {int? wrapWidth}) {
      _append('DEBUG', message ?? '');
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };

    // 捕获 Zone 中未处理的异常日志。
    FlutterError.onError = (FlutterErrorDetails details) {
      final msg = details.exceptionAsString();
      final stack = details.stack?.toString() ?? '';
      _append('ERROR', msg);
      if (stack.isNotEmpty) {
        _append('ERROR', stack);
      }
      FlutterError.presentError(details);
    };

    // Zone 外未处理异常也尽量记录（runZonedGuarded 已在 main 接入）。
    // 此处不覆盖，main 中会调用 recordError。
  }

  /// 记录 Zone 外/未处理异常。
  void recordError(Object error, StackTrace stackTrace) {
    _append('ERROR', error.toString());
    _append('ERROR', stackTrace.toString());
  }

  /// 手动追加日志（不影响原有 print 行为）。
  void append(String level, String message) {
    _append(level, message);
  }

  void _append(String level, String message) {
    final lines = const LineSplitter().convert(message);
    if (lines.isEmpty) {
      _pushEntry(level, message);
    } else {
      for (final l in lines) {
        _pushEntry(level, l);
      }
    }
  }

  void _pushEntry(String level, String message) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level.toUpperCase(),
      message: message,
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      // 简单环形裁剪：移除最早的一半，减少频繁 removeAt(0)。
      final removeCount = (_entries.length - _maxEntries);
      _entries.removeRange(0, removeCount);
    }
  }

  /// 获取最近一段时间内的日志，按时间升序返回纯文本。
  String recentLogs({Duration? since}) {
    final cutoff = since == null
        ? null
        : DateTime.now().subtract(since);
    final buf = StringBuffer();
    for (final e in _entries) {
      if (cutoff != null && e.time.isBefore(cutoff)) {
        continue;
      }
      buf.writeln(e.toLine());
    }
    return buf.toString();
  }

  /// 导出日志到指定路径（覆盖写入）。
  Future<File> exportToPath(String path, {Duration? since}) async {
    final file = File(path);
    await file.create(recursive: true);
    final content = recentLogs(since: since);
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// 清空缓冲（调试/测试用）。
  void clear() {
    _entries.clear();
  }
}

/// 包装 [print] 以写入日志缓冲区（perfLog/debugPrint 已走 debugPrint）。
void logPrint(Object? object) {
  LogBuffer.instance.append('PRINT', object?.toString() ?? '');
  // 忽略原始 print，避免双重（项目主要用 debugPrint/perfLog）
}
