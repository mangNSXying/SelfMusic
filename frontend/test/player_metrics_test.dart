import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/layout/player_metrics.dart';

void main() {
  test('桌面 1080p 铺满、1440p/4K 按 85% 留白', () {
    final fhd = PlayerMetrics.desktop(const Size(1920, 1080));
    final qhd = PlayerMetrics.desktop(const Size(2560, 1440));
    final uhd = PlayerMetrics.desktop(const Size(3840, 2160));

    expect(fhd.uiScale, closeTo(1.0, 0.001));
    expect(qhd.uiScale, closeTo(4 / 3, 0.001));
    expect(uhd.uiScale, closeTo(2.0, 0.001));

    for (final entry in [
      (fhd, const Size(1920, 1080), 1.0),
      (qhd, const Size(2560, 1440), 0.85),
      (uhd, const Size(3840, 2160), 0.85),
    ]) {
      final m = entry.$1;
      final size = entry.$2;
      expect(m.contentMaxWidth / size.width, closeTo(entry.$3, 0.005));
      expect(
        (m.targetCover + m.fixedContentHeight) / size.height,
        closeTo(0.757, 0.005),
      );
      expect(
        m.contentMaxWidth,
        closeTo(
          m.leftColumnWidth + m.lyricsMaxWidth + m.lyricsPadding * 2,
          0.01,
        ),
      );
      expect(m.lyricsMaxWidth, greaterThan(1000 * m.uiScale));
    }

    expect(fhd.contentMaxWidth, 1920);
    expect(fhd.lyricsMaxWidth, closeTo(1356.8, 0.01));
    expect(qhd.lyricsMaxWidth, closeTo(1425.07, 0.01));
    expect(uhd.lyricsMaxWidth, closeTo(2137.6, 0.01));
    expect(uhd.targetCover, closeTo(950.4, 0.01));
    expect(uhd.leftColumnWidth, closeTo(1030.4, 0.01));
  });

  test('1080p 与逻辑 1080p 的 4K@200% 使用同一套尺寸', () {
    final native = PlayerMetrics.desktop(const Size(1920, 1080));
    final scaled = PlayerMetrics.desktop(const Size(1920, 1080));

    expect(scaled.uiScale, native.uiScale);
    expect(scaled.contentMaxWidth, native.contentMaxWidth);
    expect(scaled.targetCover, native.targetCover);
  });

  test('窄桌面铺满，超过 1920 才收窄，并平滑过渡', () {
    final laptop = PlayerMetrics.desktop(const Size(1440, 900));
    expect(laptop.contentMaxWidth, 1440);
    expect(laptop.lyricsMaxWidth, closeTo(956, 0.01));

    final fhd = PlayerMetrics.desktop(const Size(1920, 1080));
    expect(fhd.contentMaxWidth, 1920);

    final mid = PlayerMetrics.desktop(const Size(2000, 1100));
    expect(mid.contentMaxWidth, 1920);

    final qhd = PlayerMetrics.desktop(const Size(2560, 1440));
    expect(qhd.contentMaxWidth, closeTo(2176, 0.01));
  });

  test('小桌面窗口不缩字号，内容仍放得下', () {
    final m = PlayerMetrics.desktop(const Size(800, 360));

    expect(m.uiScale, 1.0);
    expect(m.leftColumnWidth, 320.0);
    expect(m.targetCover, closeTo(158.4, 0.01));
    expect(m.contentMaxWidth, 800);
    expect(m.lyricsMaxWidth, closeTo(432, 0.01));
    expect(m.contentMaxWidth, lessThanOrEqualTo(800));
    expect(m.rightPaneWidth(800), 336);
  });

  test('竖屏手机保持原内容宽度，平板/竖屏 4K 放大', () {
    final phone = PlayerMetrics.portrait(const Size(360, 800));
    final tablet = PlayerMetrics.portrait(const Size(800, 1280));
    final uhd = PlayerMetrics.portrait(const Size(2160, 3840));

    expect(phone.uiScale, 1.0);
    expect(phone.contentMaxWidth, 312.0);
    expect(phone.edgePadding, 24.0);

    expect(tablet.uiScale, closeTo(1.6, 0.001));
    expect(tablet.contentMaxWidth, closeTo(723.2, 0.01));
    expect(tablet.targetCover, closeTo(640, 0.01));

    expect(uhd.uiScale, closeTo(2.4, 0.001));
    expect(uhd.contentMaxWidth, closeTo(1632, 0.01));
  });

  test('分栏右窗随 uiScale 放大且不超过可用宽度', () {
    final fhd = PlayerMetrics.desktop(const Size(1920, 1080));
    final uhd = PlayerMetrics.desktop(const Size(3840, 2160));

    expect(fhd.rightPaneWidth(1920), 440);
    expect(uhd.rightPaneWidth(3840), 880);
    expect(uhd.rightPaneWidth(600), 560);
    expect(uhd.rightPaneWidth(500), 500);
  });
}
