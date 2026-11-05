/// `play_meta` 行的唯一映射 / 读写入口（主连接与写隔离共用）。
library;

import 'package:sqlite3/sqlite3.dart';

/// 列的**固定顺序**（INSERT 的值顺序与 SELECT 映射共用）。
const String kPlayMetaColumns =
    'source_key, song_ref, like_streak, dislike_streak, factor, frozen, '
    'is_favorite, song_json, play_sec, progress_hist';

const String _kInsertSql =
    'INSERT INTO play_meta($kPlayMetaColumns) VALUES(?,?,?,?,?,?,?,?,?,?)';

/// 一首歌的播放元数据（权重 / 收藏 / 播放统计）。
class PlayMetaRow {
  final String sourceKey;
  final String songRef;
  final int likeStreak;
  final int dislikeStreak;
  final double factor;
  final bool frozen;
  final bool favorite;
  final String? songJson;

  /// 累计播放时长（秒，整数）。播放次数由它派生：playSec / 歌曲时长（1 位小数）。
  final int playSec;

  /// 播放进度直方图原始 JSON（0..100 共 101 桶）；无样本为 null。
  final String? progressHist;

  const PlayMetaRow({
    required this.sourceKey,
    required this.songRef,
    required this.likeStreak,
    required this.dislikeStreak,
    required this.factor,
    required this.frozen,
    required this.favorite,
    this.songJson,
    this.playSec = 0,
    this.progressHist,
  });

  /// 空行默认值（权重 1.0、无收藏/样本）。
  factory PlayMetaRow.empty(String sourceKey, String songRef,
          {double factor = 1.0}) =>
      PlayMetaRow(
        sourceKey: sourceKey,
        songRef: songRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: factor,
        frozen: false,
        favorite: false,
      );

  PlayMetaRow copyWith({
    int? likeStreak,
    int? dislikeStreak,
    double? factor,
    bool? frozen,
    bool? favorite,
    Object? songJson = _unset,
    int? playSec,
    Object? progressHist = _unset,
  }) =>
      PlayMetaRow(
        sourceKey: sourceKey,
        songRef: songRef,
        likeStreak: likeStreak ?? this.likeStreak,
        dislikeStreak: dislikeStreak ?? this.dislikeStreak,
        factor: factor ?? this.factor,
        frozen: frozen ?? this.frozen,
        favorite: favorite ?? this.favorite,
        songJson:
            identical(songJson, _unset) ? this.songJson : songJson as String?,
        playSec: playSec ?? this.playSec,
        progressHist: identical(progressHist, _unset)
            ? this.progressHist
            : progressHist as String?,
      );
}

const Object _unset = Object();

/// 行 → 模型（列顺序与 [kPlayMetaColumns] 一致）。
PlayMetaRow playMetaRowFromRow(Row r) => PlayMetaRow(
      sourceKey: r['source_key'] as String,
      songRef: r['song_ref'] as String,
      likeStreak: r['like_streak'] as int,
      dislikeStreak: r['dislike_streak'] as int,
      factor: (r['factor'] as num).toDouble(),
      frozen: (r['frozen'] as int) != 0,
      favorite: (r['is_favorite'] as int) != 0,
      songJson: r['song_json'] as String?,
      playSec: (r['play_sec'] as int?) ?? 0,
      progressHist: r['progress_hist'] as String?,
    );

/// 读一行；不存在返回默认行（不建行）。
PlayMetaRow readPlayMetaOrDefault(
    Database db, String sourceKey, String songRef) {
  final rs = db.select(
      'SELECT $kPlayMetaColumns FROM play_meta WHERE source_key=? AND song_ref=?',
      [sourceKey, songRef]);
  return rs.isEmpty
      ? PlayMetaRow.empty(sourceKey, songRef)
      : playMetaRowFromRow(rs.first);
}

/// 冲突时要覆盖的列。
enum PlayMetaField {
  likeStreak,
  dislikeStreak,
  factor,
  frozen,
  favorite,
  songJson,
  playSec,
  progressHist,
}

/// Upsert：INSERT 始终写全 10 列（新行与旧默认值一致），冲突时只覆盖
/// [update] 指定的列。`songJson` 恒用 COALESCE（null 不覆盖旧值）。
///
/// [addPlaySec] 非空时 `play_sec` 改为增量：`COALESCE(play_meta.play_sec,0)+?`。
void upsertPlayMetaRow(
  Database db,
  PlayMetaRow row, {
  required Set<PlayMetaField> update,
  int? addPlaySec,
}) {
  final sets = <String>[];
  final extraArgs = <Object?>[];
  for (final f in PlayMetaField.values) {
    if (!update.contains(f)) continue;
    switch (f) {
      case PlayMetaField.likeStreak:
        sets.add('like_streak=excluded.like_streak');
      case PlayMetaField.dislikeStreak:
        sets.add('dislike_streak=excluded.dislike_streak');
      case PlayMetaField.factor:
        sets.add('factor=excluded.factor');
      case PlayMetaField.frozen:
        sets.add('frozen=excluded.frozen');
      case PlayMetaField.favorite:
        sets.add('is_favorite=excluded.is_favorite');
      case PlayMetaField.songJson:
        sets.add('song_json=COALESCE(excluded.song_json, play_meta.song_json)');
      case PlayMetaField.playSec:
        if (addPlaySec != null) {
          sets.add('play_sec=COALESCE(play_meta.play_sec,0)+?');
          extraArgs.add(addPlaySec);
        } else {
          sets.add('play_sec=excluded.play_sec');
        }
      case PlayMetaField.progressHist:
        sets.add('progress_hist=excluded.progress_hist');
    }
  }
  final conflict = sets.isEmpty
      ? 'ON CONFLICT(source_key, song_ref) DO NOTHING'
      : 'ON CONFLICT(source_key, song_ref) DO UPDATE SET ${sets.join(', ')}';
  db.execute('$_kInsertSql $conflict', [
    row.sourceKey,
    row.songRef,
    row.likeStreak,
    row.dislikeStreak,
    row.factor,
    row.frozen ? 1 : 0,
    row.favorite ? 1 : 0,
    row.songJson,
    // 增量模式下新行也要落本次增量（冲突时走 SET 的「旧值 + ?」）。
    addPlaySec ?? row.playSec,
    row.progressHist,
    ...extraArgs,
  ]);
}
