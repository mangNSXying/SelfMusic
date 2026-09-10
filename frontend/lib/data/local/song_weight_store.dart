import 'dart:convert';

import '../local/local_index.dart';
import '../../models/song.dart';

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
  void onCompleted(Song s) {
    final m = metaOf(s);
    var streak = m.likeStreak + 1;
    var factor = m.factor;
    if (streak >= 3) {
      streak = 0;
      factor = _clamp(m.factor + step);
    }
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: streak,
        dislikeStreak: 0,
        factor: factor,
        frozen: m.frozen);
  }

  /// 中途跳过（<70% 被打断）：dislike_streak++，like 清零；streak≥3 → factor−0.1（≥0.5）并清零。
  void onSkipped(Song s) {
    final m = metaOf(s);
    var streak = m.dislikeStreak + 1;
    var factor = m.factor;
    if (streak >= 3) {
      streak = 0;
      factor = _clamp(m.factor - step);
    }
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: streak,
        factor: factor,
        frozen: m.frozen);
  }

  /// 主动喜欢 / 收藏：factor 直接拉到 1.5。
  void setLiked(Song s) {
    final m = metaOf(s);
    index.setFavorite(s.sourceKey, s.sourceRef, true,
        songJson: jsonEncode(s.toJson()));
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: maxFactor,
        frozen: m.frozen);
  }

  /// 取消喜欢 / 收藏：factor 回落 1.0。
  void setUnliked(Song s) {
    final m = metaOf(s);
    index.setFavorite(s.sourceKey, s.sourceRef, false);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: defaultFactor,
        frozen: m.frozen);
  }

  /// 手动重置：双 streak 清零，factor=1.0。
  void reset(Song s) {
    final m = metaOf(s);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: defaultFactor,
        frozen: m.frozen,
        favorite: m.favorite);
  }

  /// 手动「不喜欢」：factor 立即 −0.1（≥0.5），双 streak 清零；不影响收藏状态。
  void dislike(Song s) {
    final m = metaOf(s);
    index.upsertPlayMeta(s.sourceKey, s.sourceRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: _clamp(m.factor - step),
        frozen: m.frozen,
        favorite: m.favorite);
  }

  static double _clamp(double v) => v.clamp(minFactor, maxFactor).toDouble();
}