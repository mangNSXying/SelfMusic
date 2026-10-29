import 'dart:math' as math;

/// 歌词行的排版基准（缩放为 1 时），与 `lyrics_view.dart` 的样式共用。
const double kLyricInactiveFontSize = 16;
const double kLyricActiveFontSize = 19;
const double kLyricLineHeight = 1.5;
const double kLyricRowVerticalPadding = 9;

/// 高 1 时最小的歌词行高：非当前行、无译文——字号 16 × 行高 1.5 +
/// 上下内边距 9 × 2 = 42。当前行字号 19、译文行和长句折行只会更高，
/// 因此按该最小值反推字号时，实际可见行数不会超过目标。
const double kLyricMinRowHeight =
    kLyricInactiveFontSize * kLyricLineHeight + kLyricRowVerticalPadding * 2;

/// 按「歌词区最多显示 [maxLines] 行」计算歌词缩放。
///
/// - [maxLines] <= 0 或高度无效：不限制，返回 [baseScale]；
/// - 只放大不缩小：大屏/小行数时返回更大的缩放，小屏保留原字号；
/// - [viewportHeight] 为歌词列表实际可用高度（不含播放页标题等）。
double lyricScaleForMaxLines({
  required double baseScale,
  required int maxLines,
  required double viewportHeight,
}) {
  if (maxLines <= 0 || !viewportHeight.isFinite || viewportHeight <= 0) {
    return baseScale;
  }
  final target = viewportHeight / (kLyricMinRowHeight * maxLines);
  return math.max(baseScale, target);
}
