import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/lyric_scale.dart';

void main() {
  group('歌词最大行数缩放', () {
    test('不限制或高度无效时沿用基础缩放', () {
      expect(
          lyricScaleForMaxLines(
              baseScale: 1.2, maxLines: 0, viewportHeight: 1000),
          1.2);
      expect(
          lyricScaleForMaxLines(
              baseScale: 1.2, maxLines: 10, viewportHeight: 0),
          1.2);
      expect(
          lyricScaleForMaxLines(
              baseScale: 1.2, maxLines: 10, viewportHeight: double.infinity),
          1.2);
    });

    test('大屏按上限放大，目标行数内可容纳', () {
      const height = 1050.0;
      const maxLines = 10;
      final scale = lyricScaleForMaxLines(
          baseScale: 1, maxLines: maxLines, viewportHeight: height);

      expect(scale, closeTo(2.5, 1e-9));
      final visible = height / (kLyricMinRowHeight * scale);
      expect(visible, lessThanOrEqualTo(maxLines));
    });

    test('只放大不缩小：目标字体小于基础字号时保留原字号', () {
      final scale = lyricScaleForMaxLines(
          baseScale: 2, maxLines: 10, viewportHeight: 600);
      expect(scale, 2);
    });

    test('上限越小字号越大', () {
      final six = lyricScaleForMaxLines(
          baseScale: 1, maxLines: 6, viewportHeight: 1050);
      final twelve = lyricScaleForMaxLines(
          baseScale: 1, maxLines: 12, viewportHeight: 1050);
      expect(six, greaterThan(twelve));
    });
  });
}
