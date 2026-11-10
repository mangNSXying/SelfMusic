import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/layout/mini_player_bar.dart';

void main() {
  test('宽屏播控随中列自适应：窄列收紧，宽列放大，上限封顶', () {
    final narrow = miniTransportMetrics(238);
    expect(narrow.play, 44);
    expect(narrow.skip, 28);
    expect(narrow.gap, closeTo(14.28, 0.01));

    final wide = miniTransportMetrics(425);
    expect(wide.play, 48);
    expect(wide.skip, 34);
    expect(wide.gap, closeTo(25.5, 0.01));

    final huge = miniTransportMetrics(900);
    expect(huge.play, 48);
    expect(huge.skip, 34);
    expect(huge.gap, 26);
  });

  test('固定高度与回退阈值', () {
    expect(kMiniPlayerBarHeightWide, 88);
    expect(kMiniPlayerBarHeight, 72);
    expect(kMiniWideMinWidth, 550);
  });
}
