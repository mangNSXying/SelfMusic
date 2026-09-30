import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/providers/player_provider.dart';

void main() {
  group('PlayerProvider.nextIndexAfterRemove（移除非当前曲后当前下标修正）', () {
    test('移除位在当前位置之前 → 左移一位', () {
      expect(PlayerProvider.nextIndexAfterRemove(2, 0), 1);
      expect(PlayerProvider.nextIndexAfterRemove(2, 1), 1);
      expect(PlayerProvider.nextIndexAfterRemove(1, 0), 0);
    });

    test('移除位在当前位置之后 → 原位不动', () {
      expect(PlayerProvider.nextIndexAfterRemove(2, 3), 2);
      expect(PlayerProvider.nextIndexAfterRemove(2, 9), 2);
      expect(PlayerProvider.nextIndexAfterRemove(0, 1), 0);
    });
  });
}