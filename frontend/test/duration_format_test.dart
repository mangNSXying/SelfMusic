import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/duration_format.dart';

void main() {
  group('formatDuration', () {
    test('空值与无效值返回空串', () {
      expect(formatDuration(null), '');
      expect(formatDuration(0), '');
      expect(formatDuration(-5), '');
    });

    test('分钟秒补零', () {
      expect(formatDuration(59), '00:59');
      expect(formatDuration(60), '01:00');
      expect(formatDuration(200), '03:20');
      expect(formatDuration(3599), '59:59');
    });

    test('满一小时用 h:mm:ss（小时不补零）', () {
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3661), '1:01:01');
      expect(formatDuration(36000), '10:00:00');
    });

    test('可自定义空值占位', () {
      expect(formatDuration(null, empty: '--:--'), '--:--');
      expect(formatDuration(0, empty: '--:--'), '--:--');
    });
  });

  group('formatClock', () {
    test('Duration 版本无效时显示 00:00', () {
      expect(formatClock(null), '00:00');
      expect(formatClock(Duration.zero), '00:00');
      expect(formatClock(const Duration(seconds: -3)), '00:00');
    });

    test('超过一小时保留小时位', () {
      expect(formatClock(const Duration(hours: 1, minutes: 1, seconds: 5)),
          '1:01:05');
      expect(formatClock(const Duration(minutes: 61, seconds: 5)), '1:01:05');
    });
  });
}
