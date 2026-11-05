import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/navigation_provider.dart';

void main() {
  testWidgets('顶栏条带：隔项切换补滚动动画，邻项变化仍即时跟手', (tester) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final nav = NavigationProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: MaterialApp(
          home: Scaffold(body: TopBar(onSidebarToggle: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal);
    final position = tester.widget<ListView>(listFinder).controller!.position;
    final max = position.maxScrollExtent;
    expect(max, greaterThan(0), reason: '测试窗口需窄到导航条可横向滚动');

    // 挂载后条带对齐当前分组（歌曲 = 3），不停在最左端。
    final page3 = max * 3 / 5;
    expect(position.pixels, moreOrLessEquals(page3, epsilon: 0.6));

    // 歌曲(3) → 歌手(5)：隔项切换时 pageOffset 一步跳两页，
    // 条带必须补一段滚动动画，而不是瞬间跳到终点。
    final frames = <double>[];
    nav.pageOffset.value = 5;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(position.pixels);
    }
    expect(frames.any((v) => v > page3 + 1 && v < max - 1), isTrue,
        reason: '隔项切换应出现中间滚动帧：$frames');
    expect(position.pixels, moreOrLessEquals(max, epsilon: 0.6),
        reason: '动画结束后应停在目标分组');

    // 邻项切换/拖拽的逐帧页码仍即时跟手（不叠 300ms 动画）。
    nav.pageOffset.value = 4.9;
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, moreOrLessEquals(max * 4.9 / 5, epsilon: 1.0));
    await tester.pumpAndSettle();
  });
}
