import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/layout/mini_player_bar.dart';

void main() {
  test('三列播控比回退更小，随中列宽在小区间内自适应', () {
    final narrow = miniTransportMetrics(238);
    expect(narrow.play, 38);
    expect(narrow.skip, 34);
    expect(narrow.gap, closeTo(13.09, 0.01));

    final wide = miniTransportMetrics(425);
    expect(wide.play, 39);
    expect(wide.skip, closeTo(36.125, 0.01));
    expect(wide.gap, 22);
    expect(wide.play, lessThan(42)); // 回退态播放键 42

    final huge = miniTransportMetrics(900);
    expect(huge.play, 39);
    expect(huge.skip, 38);
    expect(huge.gap, 22);
  });

  test('回退态正常保持 42，极窄才收紧到 34；封面始终 48', () {
    final normal = compactTransportMetrics(390);
    expect(normal.play, 42);
    expect(normal.skipHit, 46);
    expect(normal.queueHit, 48);

    final tight = compactTransportMetrics(224);
    expect(tight.play, 34);
    expect(tight.skipHit, 30);
    expect(tight.queueHit, 30);

    expect(kMiniBarCoverSize, 48);
  });

  test('条高固定 72，三列封面列与中列同占 48，上下各 12', () {
    expect(kMiniPlayerBarHeight, 72);
    expect(kMiniWideContentHeight, 48);
    expect(kMiniBarCoverSize, kMiniWideContentHeight);
    expect((kMiniPlayerBarHeight - kMiniWideContentHeight) / 2, 12);
    expect(kMiniWideMinWidth, 550);
  });

  test('右列模式/音量/队列统一 44 命中、22 图标、2 间距', () {
    expect(kMiniToolButtonSize, 44);
    expect(kMiniToolIconSize, 22);
    expect(kMiniToolGap, 2);
    expect(3 * kMiniToolButtonSize + 2 * kMiniToolGap, lessThan(550 / 3.5));
  });
}
