import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/screens/player_screen.dart';

void main() {
  test('横屏布局分流：桌面平台恒双栏；手机窄横屏三列；超宽屏双栏', () {
    // 手机横屏（窄屏）：三列紧凑。
    expect(useDesktopLandscape(const Size(800, 480),
        isDesktopPlatform: false), isFalse);
    // 桌面平台即使窗口不长：双栏居中。
    expect(useDesktopLandscape(const Size(800, 480),
        isDesktopPlatform: true), isTrue);
    // 超宽屏（大平板横屏，Android）：双栏。
    expect(useDesktopLandscape(const Size(1440, 900),
        isDesktopPlatform: false), isTrue);
    // 临界值 1000。
    expect(useDesktopLandscape(const Size(999, 600),
        isDesktopPlatform: false), isFalse);
    expect(useDesktopLandscape(const Size(1000, 600),
        isDesktopPlatform: false), isTrue);
  });
}
