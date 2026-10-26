import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/play_progress.dart';

PlayProgressHistogram _hist(List<int> percents) {
  var h = PlayProgressHistogram.empty();
  for (final p in percents) {
    h = h.record(p);
  }
  return h;
}

void main() {
  group('PlayProgressHistogram', () {
    test('空直方图：无样本、无中位数、序列化为 null', () {
      final h = PlayProgressHistogram.empty();
      expect(h.total, 0);
      expect(h.isEmpty, isTrue);
      expect(h.medianPercent, isNull);
      expect(h.toJsonOrNull(), isNull);
    });

    test('奇数样本取中间桶', () {
      final h = _hist([40, 100, 100]);
      expect(h.total, 3);
      expect(h.medianPercent, 100);
    });

    test('偶数样本取中间两桶均值', () {
      final h = _hist([40, 40, 100, 100]);
      expect(h.medianPercent, 70);
    });

    test('record 对越界百分比钳制到 0..100', () {
      final h = PlayProgressHistogram.empty().record(-5).record(120);
      expect(h.total, 2);
      expect(h.toList()[0], 1);
      expect(h.toList()[100], 1);
    });

    test('JSON 字符串/数组解析，坏数据回落空直方图', () {
      expect(
          PlayProgressHistogram.fromJson(_hist([1, 2, 3]).toJsonOrNull()).total,
          3);
      expect(PlayProgressHistogram.fromJson([0, 1, 0]).total, 1);
      expect(PlayProgressHistogram.fromJson('not-json').total, 0);
      expect(PlayProgressHistogram.fromJson({'x': 1}).total, 0);
    });

    test('mergeMax 按桶取 max（不累加）', () {
      final a = _hist([40, 40, 100]);
      final b = _hist([40, 100]);
      final merged = a.mergeMax(b);
      expect(merged.total, 3);
      expect(merged.toList()[40], 2);
      expect(merged.toList()[100], 1);
    });
  });

  group('离开进度百分比', () {
    const dur = Duration(minutes: 4);

    test('自然结束固定 100%，即使时长未知', () {
      expect(progressPercentOf(null, Duration.zero, completed: true), 100);
      expect(
          progressPercentOf(dur, const Duration(seconds: 1), completed: true),
          100);
    });

    test('按 position/duration 向下取整', () {
      expect(progressPercentOf(dur, const Duration(minutes: 2)), 50);
      expect(
          progressPercentOf(dur, const Duration(minutes: 3, seconds: 50)), 95);
    });

    test('越界钳制，未知时长且非结束返回 null', () {
      expect(progressPercentOf(dur, const Duration(minutes: 10)), 100);
      expect(progressPercentOf(dur, const Duration(seconds: -1)), 0);
      expect(progressPercentOf(null, const Duration(seconds: 1)), isNull);
      expect(
          progressPercentOf(Duration.zero, const Duration(seconds: 1)), isNull);
    });
  });

  group('中位升权闸门', () {
    test('门槛随目标档位递增，目标 <=1.0 不设闸门', () {
      expect(requiredMedianPercent(1.0), isNull);
      expect(requiredMedianPercent(1.05), 47.5);
      expect(requiredMedianPercent(1.1), 50);
      expect(requiredMedianPercent(1.2), 55);
      expect(requiredMedianPercent(1.5), 70);
    });

    test('目标 <=1.0 无样本也放行', () {
      expect(allowsUpgrade(PlayProgressHistogram.empty(), 1.0), isTrue);
      expect(allowsUpgrade(PlayProgressHistogram.empty(), 0.9), isTrue);
    });

    test('1.1 需 >=3 条样本且中位 >=50%', () {
      expect(allowsUpgrade(PlayProgressHistogram.empty(), 1.1), isFalse);
      expect(allowsUpgrade(_hist([100, 100]), 1.1), isFalse);
      expect(allowsUpgrade(_hist([49, 49, 100]), 1.1), isFalse);
      expect(allowsUpgrade(_hist([50, 50, 100]), 1.1), isTrue);
    });

    test('1.2 需中位 >=55%', () {
      expect(allowsUpgrade(_hist([54, 54, 100]), 1.2), isFalse);
      expect(allowsUpgrade(_hist([55, 55, 100]), 1.2), isTrue);
    });

    test('展示格式', () {
      expect(formatMedianProgress(null), '—');
      expect(formatMedianProgress(87), '87%');
      expect(formatMedianProgress(87.5), '87.5%');
    });
  });
}
