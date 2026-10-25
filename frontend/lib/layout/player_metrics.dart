import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 播放页自适应尺寸：按视口算出封面/栏宽/歌词区/字号缩放。
///
/// 目标不是整体等比放大（留白占比不会变），而是让播放内容随屏幕一起
/// 占据更多面积：1080p 起封面约占屏高 44%，内容块约占屏宽 85%，
/// 歌词列吃掉左栏之外的剩余宽度；4K 保持同一观感比例。小窗口 uiScale
/// 下限锁 1，避免字号/控件缩到不可读，同时保留原有可滚动兜底。
@immutable
class PlayerMetrics {
  /// 字号、图标、间距、进度条等的统一缩放系数（1.0 起）。
  final double uiScale;

  /// 桌面双栏内容块的最大宽度（左播放列 + 右歌词列 + 内边距）。
  final double contentMaxWidth;

  /// 桌面左播放列宽度。
  final double leftColumnWidth;

  /// 封面目标边长（实际布局还会受所在列宽/可用高约束）。
  final double targetCover;

  /// 桌面歌词列内容最大宽度。
  final double lyricsMaxWidth;

  /// 桌面歌词列水平内边距。
  final double lyricsPadding;

  /// 桌面左播放列水平/垂直内边距。
  final double columnPadding;

  /// 封面以外控件的近似固定高度（用于把剩余高度留给封面）。
  final double fixedContentHeight;

  /// 空态封面边长。
  final double emptyCoverSize;

  /// 竖屏页面外边距。
  final double edgePadding;

  const PlayerMetrics._({
    required this.uiScale,
    required this.contentMaxWidth,
    required this.leftColumnWidth,
    required this.targetCover,
    required this.lyricsMaxWidth,
    required this.lyricsPadding,
    required this.columnPadding,
    required this.fixedContentHeight,
    required this.emptyCoverSize,
    required this.edgePadding,
  });

  /// 桌面/超宽屏横屏双栏。
  factory PlayerMetrics.desktop(Size viewport) {
    final w = math.max(1.0, viewport.width);
    final h = math.max(1.0, viewport.height);
    final uiScale = _clamp(
      math.min(w / 1920, h / 1080),
      1.0,
      2.2,
    );
    final columnPadding = 20.0 * uiScale;
    final targetCover = h * 0.44;
    final contentMaxWidth = w * 0.85;
    final leftColumnWidth = math.min(
      math.max(targetCover + columnPadding * 2, 320.0 * uiScale),
      contentMaxWidth * 0.55,
    );
    final lyricsPadding = 24.0 * uiScale;
    // 歌词区吃满左栏之外的剩余宽度，避免内容向中间缩成一团。
    final lyricsMaxWidth = math.max(
      0.0,
      contentMaxWidth - leftColumnWidth - lyricsPadding * 2,
    );
    return PlayerMetrics._(
      uiScale: uiScale,
      contentMaxWidth: contentMaxWidth,
      leftColumnWidth: leftColumnWidth,
      targetCover: targetCover,
      lyricsMaxWidth: lyricsMaxWidth,
      lyricsPadding: lyricsPadding,
      columnPadding: columnPadding,
      fixedContentHeight: 342.0 * uiScale,
      emptyCoverSize: _clamp(
        h * 0.32,
        120.0 * uiScale,
        200.0 * uiScale,
      ),
      edgePadding: 0,
    );
  }

  /// 竖屏（手机/平板/竖屏桌面窗口）。
  factory PlayerMetrics.portrait(Size viewport) {
    final w = math.max(1.0, viewport.width);
    final h = math.max(1.0, viewport.height);
    final uiScale = _clamp(
      math.min(w / 400, h / 800),
      1.0,
      2.4,
    );
    final edgePadding = 24.0 * uiScale;
    final contentMaxWidth = math.max(
      0.0,
      math.min(
        w - edgePadding * 2,
        680.0 * uiScale,
      ),
    );
    return PlayerMetrics._(
      uiScale: uiScale,
      contentMaxWidth: contentMaxWidth,
      leftColumnWidth: 0,
      targetCover: h * 0.50,
      lyricsMaxWidth: 0,
      lyricsPadding: 0,
      columnPadding: 0,
      fixedContentHeight: 342.0 * uiScale,
      emptyCoverSize: _clamp(
        h * 0.30,
        96.0 * uiScale,
        180.0 * uiScale,
      ),
      edgePadding: edgePadding,
    );
  }

  /// 桌面横屏分栏右窗宽度（按栏内可用宽度，不按全屏宽直算）。
  double rightPaneWidth(double availableWidth) => math.min(
        availableWidth,
        math.max(
          280.0 * uiScale,
          math.min(440.0 * uiScale, availableWidth * 0.42),
        ),
      );

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);
}
