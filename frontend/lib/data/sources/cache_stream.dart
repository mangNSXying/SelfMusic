/// 整曲缓存落盘共用骨架：攒批写 `.tmp-<key>` → `cacheCommit` 原子换入。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../local/local_index.dart';
import 'music_source.dart';

/// 缓存落盘缓冲阈值（攒够才顺序写一次，避免上万次小写入）。
const int kCacheWriteBufBytes = 1 << 20;

/// 把 [stream] 写入缓存临时文件并登记。
///
/// 调用方负责提前 `isCached` 短路与取流（HTTP/源 open）。失败（取消/断流/
/// commit 异常）会删除半截 `.tmp-<key>`；[pace] 用于 SFTP 旧直连每块后的让出。
Future<void> cacheStreamToFile(
  LocalIndex index, {
  required String cacheKey,
  required String sourceKey,
  required String songRef,
  required Stream<List<int>> stream,
  required CacheEntryKind kind,
  bool Function()? shouldAbort,
  Duration? pace,
}) async {
  final tmp = File(p.join(index.cacheDir, '.tmp-$cacheKey'));
  var committed = false;
  try {
    final sink = tmp.openSync(mode: FileMode.write);
    final buf = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final chunk in stream) {
        if (shouldAbort?.call() == true) {
          throw const PreloadAbortedException();
        }
        buf.add(chunk);
        total += chunk.length;
        if (buf.length >= kCacheWriteBufBytes) {
          sink.writeFromSync(buf.takeBytes());
        }
        if (pace != null) await Future<void>.delayed(pace);
      }
      if (buf.isNotEmpty) sink.writeFromSync(buf.takeBytes());
    } finally {
      sink.closeSync();
    }
    await index.cacheCommit(cacheKey, tmp.path, total,
        sourceKey: sourceKey, songRef: songRef, kind: kind);
    committed = true;
  } finally {
    if (!committed && tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
  }
}
