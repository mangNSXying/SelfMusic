import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/layout/mini_player_bar.dart';

void main() {
  group('队列按钮区上滑判定 isQueueUpSwipe', () {
    test('向上速度足够 → true（与整条上滑打开播放页同一阈值）', () {
      expect(isQueueUpSwipe(-800, 300, 200), isTrue);
      expect(isQueueUpSwipe(-1200, 300, 250), isTrue);
    });

    test('累计上移距离足够 → true（velocity 缺失的拖动环境兜底）', () {
      expect(isQueueUpSwipe(null, 300, 200), isTrue); // 位移 100 > 40
      expect(isQueueUpSwipe(0, 300, 240), isTrue); // 位移 60 > 40
    });

    test('非上滑（下移/微小位移/向上速度不足）→ false，点按不误触', () {
      expect(isQueueUpSwipe(0, 200, 200), isFalse); // 无位移 = 点按
      expect(isQueueUpSwipe(null, 200, 200), isFalse);
      expect(isQueueUpSwipe(300, 200, 250), isFalse); // 向下速度
      expect(isQueueUpSwipe(-500, 300, 300), isFalse); // 速度不足且无位移
      expect(isQueueUpSwipe(-500, 300, 280), isFalse); // 速度不足 + 位移 20 < 40
    });
  });
}