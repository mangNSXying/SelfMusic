import 'dart:convert';

import '../local/local_index.dart';
import '../../models/song.dart';
import 'sync_event_types.dart';

/// 歌曲权重与收藏的统一点（stage2.md §1.5 / §2.1）。
///
/// - factor 连续取值 0.5 ≤ factor ≤ 1.5，步长 0.1，初始 1.0。
/// - 事件（complete/skip/liked/unfavorite/reset）驱动 factor 调整，写回 play_meta。
/// - 完播/跳过按「播放时长 >95% 记完播、<30% 记跳过」（30%~95% 不记）由上层判定后
///   分发到 [onCompleted]/[onSkipped]；同一首歌的完播与跳过次数互斥——每次事件
///   都会清零另一侧计数（后来者覆盖先前值），不会同时累计。
/// - 收藏状态统一收口到 play_meta（直连 + 服务器一致）。
class SongWeightStore {
  static const double minFactor = 0.5;
  static const double maxFactor = 1.5;
  static const double step = 0.1;
  static const double defaultFactor = 1.0;

  final LocalIndex index;

  /// 服务器可达性门控（DirectSourceManager 注入 `isServerAvailable`）：
  /// 直连歌曲仅在连着服务器时进 outbox，避免未配对用户 outbox 无限积压。
  final bool Function()? serverAvailable;

  SongWeightStore(this.index, {this.serverAvailable});

  PlayMetaRow metaOf(Song s) => index.playMetaOf(s.sourceKey, s.sourceRef);

  double factorOf(Song s) => metaOf(s).factor;

  bool isFavorite(Song s) => metaOf(s).favorite;

  /// 完播（播放时长 >95%，通常为自然结束）：like_streak++，dislike 清零（覆盖先前跳过）；
  /// streak≥3 → factor+0.1（≤1.5）并清零。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权（权重锁定最低）。
  void onCompleted(Song s) {
    final m = metaOf(s);
    var streak = m.likeStreak + 1;
    var factor = m.factor;
    if (!m.frozen && streak >= 3) {
      streak = 0;
      factor = _clamp(m.factor + step);
    }
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: streak,
        dislikeStreak: 0,
        factor: factor,
        frozen: m.frozen);
    _emit(s, SyncEventTypes.songComplete);
  }

  /// 中途跳过（播放时长 <30% 被打断）：dislike_streak++，like 清零（覆盖先前完播）；
  /// streak≥3 → factor−0.1（≥0.5）并清零。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权。
  void onSkipped(Song s) {
    final m = metaOf(s);
    var streak = m.dislikeStreak + 1;
    var factor = m.factor;
    if (!m.frozen && streak >= 3) {
      streak = 0;
      factor = _clamp(m.factor - step);
    }
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: streak,
        factor: factor,
        frozen: m.frozen);
    _emit(s, SyncEventTypes.songSkipped);
  }

  /// 主动喜欢 / 收藏：factor 直接拉到 1.5，同时解除「不喜欢」锁定。
  void setLiked(Song s) {
    index.setFavorite(s.sourceKey, s.sourceRef, true,
        songJson: jsonEncode(s.toJson()));
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: maxFactor,
        frozen: false);
    _emit(s, SyncEventTypes.songLiked);
  }

  /// 取消喜欢 / 收藏：非锁定态 factor 回落 1.0；「不喜欢」锁定态保持最低权重。
  void setUnliked(Song s) {
    final m = metaOf(s);
    index.setFavorite(s.sourceKey, s.sourceRef, false);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: m.frozen ? m.factor : defaultFactor,
        frozen: m.frozen);
    _emit(s, SyncEventTypes.songUnfavorite);
  }

  /// 是否处于「不喜欢」态（权重锁定最低）。
  bool isDisliked(Song s) => metaOf(s).frozen;

  /// 手动「不喜欢」开关：开 → 权重直接降到最低并锁定（跳过自动调权）；
  /// 关 → 解锁并回到 1.0；不影响收藏状态。
  void setDisliked(Song s, bool disliked) {
    final m = metaOf(s);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: disliked ? minFactor : defaultFactor,
        frozen: disliked,
        favorite: m.favorite);
    _emit(s, SyncEventTypes.songDisliked, {'enabled': disliked});
  }

  /// 手动重置：双 streak 清零，factor=1.0，解除「不喜欢」锁定。
  void reset(Song s) {
    final m = metaOf(s);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: defaultFactor,
        frozen: false,
        favorite: m.favorite);
    _emit(s, SyncEventTypes.songReset);
  }

  /// 阶段5：有歌曲身份（source/sourceRef 非空、可解析）即进 outbox；服务端按
  /// (source, source_ref) 解析，直连歌曲无行则建影子行（DESIGN §7.2）。
  /// 服务器模式行恒进（行存在即配过服务器）；直连歌曲需连着服务器
  ///（[serverAvailable] 为假时跳过，避免未配对用户 outbox 积压）。
  /// source=='server' 占位（归属源未知）仍跳过，避免跨源误归属。
  void _emit(Song s, String type, [Map<String, dynamic>? extra]) {
    if (s.source.isEmpty || s.source == 'server' || s.sourceRef.isEmpty) {
      return;
    }
    if (s.sourceKey != 'server' && !(serverAvailable?.call() ?? false)) {
      return;
    }
    final sourceId = index.sourceUuidOf(s.sourceKey);
    index.enqueueOutbox(type, {
      'source': s.source,
      'source_ref': s.sourceRef,
      if (sourceId != null) 'source_id': sourceId,
      if (extra != null) ...extra,
    });
  }

  static double _clamp(double v) => v.clamp(minFactor, maxFactor).toDouble();

  /// 补推存量权重（配对前数据无事件用）：为非默认 play_meta 行补 song.state
  /// 绝对态事件（streak/factor/frozen/favorite 全量，服务端 LWW）。
  /// source_key=='server' 的行走常规 outbox（恒进事件），跳过；
  /// 门控与 [_emit] 一致。返回补推歌曲数。
  int backfill() {
    var n = 0;
    for (final m in index.listDirtyPlayMeta()) {
      if (m.sourceKey == 'server') continue;
      final protocol = index.getSource(m.sourceKey)?.kind ?? '';
      if (protocol.isEmpty || protocol == 'server') continue;
      if (!(serverAvailable?.call() ?? false)) continue;
      final sourceId = index.sourceUuidOf(m.sourceKey);
      index.enqueueOutbox(SyncEventTypes.songState, {
        'source': protocol,
        'source_ref': m.songRef,
        if (sourceId != null) 'source_id': sourceId,
        'like_streak': m.likeStreak,
        'dislike_streak': m.dislikeStreak,
        'weight': m.factor,
        'frozen': m.frozen,
        'is_favorite': m.favorite,
      });
      n++;
    }
    return n;
  }
}