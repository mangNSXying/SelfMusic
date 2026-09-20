import 'dart:convert';

import '../local/local_index.dart';
import '../../models/song.dart';
import 'sync_event_types.dart';

/// 歌曲权重与收藏的统一点（stage2.md §1.5 / §2.1）。
///
/// - factor 连续取值 0.5 ≤ factor ≤ 1.5，步长 0.1，初始 1.0。
/// - 事件（complete/skip/liked/unfavorite/reset）驱动 factor 调整，写回 play_meta。
/// - 收藏状态统一收口到 play_meta（直连 + 服务器一致）。
class SongWeightStore {
  static const double minFactor = 0.5;
  static const double maxFactor = 1.5;
  static const double step = 0.1;
  static const double defaultFactor = 1.0;

  final LocalIndex index;
  SongWeightStore(this.index);

  PlayMetaRow metaOf(Song s) => index.playMetaOf(s.sourceKey, s.sourceRef);

  double factorOf(Song s) => metaOf(s).factor;

  bool isFavorite(Song s) => metaOf(s).favorite;

  /// 完整播放（≥70% 自然结束）：like_streak++，dislike 清零；streak≥3 → factor+0.1（≤1.5）并清零。
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

  /// 中途跳过（<70% 被打断）：dislike_streak++，like 清零；streak≥3 → factor−0.1（≥0.5）并清零。
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

  /// 阶段5：仅服务器模式歌曲进 outbox（直连歌曲只活本机，见 DESIGN §7.2）。
  /// legacy/未知 source 一律跳过（服务端按 source_ref 兜底只处理条目类事件）。
  void _emit(Song s, String type, [Map<String, dynamic>? extra]) {
    if (s.sourceKey != 'server' || s.source.isEmpty || s.source == 'server') {
      return;
    }
    index.enqueueOutbox(type, {
      'source': s.source,
      'source_ref': s.sourceRef,
      if (extra != null) ...extra,
    });
  }

  static double _clamp(double v) => v.clamp(minFactor, maxFactor).toDouble();
}