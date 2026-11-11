/// 扫描结果 → 本地库的统一提交路径（四个直连源共用）。
library;

import 'dart:typed_data';

import '../local/local_index.dart';
import 'music_source.dart';
import 'scan_worker.dart';

/// 单条扫描结果的落库动作（增量统计用）。
enum ScanItemKind { added, updated, unchanged }

/// worker 产出：一行待落库数据 + 可选封面字节 + 动作分类。
class ScannedSong {
  final DirectSongRow row;
  final Uint8List? cover;
  final ScanItemKind kind;

  const ScannedSong({required this.row, this.cover, required this.kind});
}

/// 把一组扫描结果提交到索引：计数、封面落盘、批量 upsert、清理消失行。
///
/// [guardEmpty] 为 true 时启用「0 结果防误清库」数据安全闸（远端源默认开启；
/// 本地目录为空是合法状态，调用方传 false）。
Future<ScanSummary> commitScan(
  LocalIndex index, {
  required String sourceKey,
  required List<ScannedSong> items,
  required Map<String, ScanFingerprint> known,
  bool cancelled = false,
  bool guardEmpty = true,
}) async {
  if (guardEmpty && items.isEmpty && known.isNotEmpty && !cancelled) {
    throw ScanWorkerException('扫描结果为 0，但本地库已有 ${known.length} 首；'
        '为防止误清库已中止。如确认服务器目录已清空，请删除并重建该源');
  }

  final alive = <String>[];
  final toWrite = <DirectSongRow>[];
  var added = 0, updated = 0, unchanged = 0;
  for (final item in items) {
    alive.add(item.row.ref);
    switch (item.kind) {
      case ScanItemKind.unchanged:
        unchanged++;
        continue;
      case ScanItemKind.added:
        added++;
      case ScanItemKind.updated:
        updated++;
    }
    final coverPath = item.cover == null || item.cover!.isEmpty
        ? null
        : index.persistCover(item.cover!, item.row.ref);
    toWrite.add(item.row.withCoverPath(coverPath ?? item.row.coverPath));
  }
  await index.upsertSongs(toWrite);
  // 取消的半途扫描不能把未遍历到的清单项标成 missing：本轮只提交已扫到的
  // 新增/更新，不做 missing diff。否则一次取消就会误清大量歌曲（并触发
  // 播放器把队列里的歌当成已删除）。
  if (cancelled) {
    return ScanSummary(
      added: added,
      updated: updated,
      unchanged: unchanged,
      total: alive.length,
      cancelled: true,
    );
  }
  final aliveSet = alive.toSet();
  final missingRefs = [
    for (final ref in known.keys)
      if (!aliveSet.contains(ref)) ref,
  ];
  await index.markMissingExcept(sourceKey, alive);
  final removed = await index.clearMissing(sourceKey);
  return ScanSummary(
    added: added,
    removed: removed,
    updated: updated,
    unchanged: unchanged,
    total: alive.length,
    missingRefs: missingRefs,
  );
}
