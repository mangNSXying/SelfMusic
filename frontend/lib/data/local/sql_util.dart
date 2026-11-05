/// 本地 SQLite 层的纯 Dart 工具（主连接与写隔离共用）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

/// 事件 uuid（服务端 event_uuid 幂等键；36 列内唯一即可，不需标准 UUID 形态）。
String newEventUuid() {
  final r = Random.secure();
  final tail = List.generate(
      3, (_) => r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0')).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${tail.substring(0, 12)}';
}

/// 从 source_key（`webdav:name`）取协议名（`webdav`）。
String protocolOf(String sourceKey) {
  final i = sourceKey.indexOf(':');
  return i > 0 ? sourceKey.substring(0, i) : sourceKey;
}

/// 按源实例 uuid 反查本地源 key（未配置对应源返回 null）。
String? sourceKeyOfUuid(Database db, String uuid) {
  if (uuid.isEmpty) return null;
  final rs = db.select('SELECT key FROM sources WHERE client_uuid=?', [uuid]);
  return rs.isEmpty ? null : rs.first['key'] as String;
}

/// DB 行里的 JSON 数组（容错：损坏/非数组返回空列表）。
List<Map<String, dynamic>> jsonMapList(Object? raw) {
  if (raw == null) return const [];
  try {
    return (jsonDecode(raw as String) as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// 按 [size] 切连续子块（[size] < 1 时按 1）。
Iterable<List<T>> chunksOf<T>(List<T> list, [int size = 500]) sync* {
  final step = size < 1 ? 1 : size;
  for (var start = 0; start < list.length; start += step) {
    final end = start + step < list.length ? start + step : list.length;
    yield list.sublist(start, end);
  }
}

/// `?,?,…`（长度 [n]）。
String sqlPlaceholders(int n) => List.filled(n, '?').join(',');

/// 分片执行 `IN (…)` 查询：每片复用 [sql] 生成语句，参数为
/// `[...leadingArgs, ...chunk]`。
Iterable<Row> selectInChunks(
  Database db,
  List<String> refs, {
  required List<Object?> leadingArgs,
  required String Function(String placeholders) sql,
  int chunkSize = 500,
}) sync* {
  for (final chunk in chunksOf(refs, chunkSize)) {
    yield* db
        .select(sql(sqlPlaceholders(chunk.length)), [...leadingArgs, ...chunk]);
  }
}
