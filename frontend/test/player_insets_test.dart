import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/screens/player_screen.dart';

void main() {
  test('全屏切换保护：状态栏可见时捕获当前 inset 作为保留值', () {
    const current = EdgeInsets.only(top: 24, left: 0, right: 0, bottom: 12);
    const previous = EdgeInsets.zero;
    expect(
      reservedPlayerPadding(
          captureNow: true, current: current, reserved: previous),
      current,
    );
  });

  test('全屏切换保护：状态栏隐藏后沿用保留值，忽略引擎回报的 0', () {
    const visible = EdgeInsets.only(top: 24, left: 0, right: 0, bottom: 12);
    const leftInset = EdgeInsets.only(left: 88); // 横屏切角在左
    // 隐藏/旋转期间 insets 变化，但全屏应用期间都不得让布局跟随。
    for (final reported in const [
      EdgeInsets.zero,
      leftInset,
      EdgeInsets.only(bottom: 40)
    ]) {
      expect(
        reservedPlayerPadding(
            captureNow: false, current: reported, reserved: visible),
        visible,
      );
    }
  });

  test('全屏关闭后恢复捕获，保留值跟回当前数值', () {
    const a = EdgeInsets.only(top: 24);
    const b = EdgeInsets.only(top: 30, bottom: 6);
    var reserved = a;
    reserved = reservedPlayerPadding(
        captureNow: false, current: EdgeInsets.zero, reserved: reserved);
    expect(reserved, a);
    // 退出全屏（captureNow=true）后采用当前可见 inset。
    reserved =
        reservedPlayerPadding(captureNow: true, current: b, reserved: reserved);
    expect(reserved, b);
  });
}
