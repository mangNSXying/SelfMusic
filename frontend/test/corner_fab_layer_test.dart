import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/corner_add_button.dart';

/// 右下角按钮的滚动显隐：向下浏览收起、向上浏览出现，横向翻页不触发。
void main() {
  Widget build() => MaterialApp(
        home: Scaffold(
          body: CornerFabLayer(
            content: Column(
              children: [
                SizedBox(
                  height: 80,
                  child: ListView(
                    key: const ValueKey<String>('hlist'),
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < 30; i++)
                        SizedBox(width: 60, child: Text('列$i')),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    key: const ValueKey<String>('vlist'),
                    itemCount: 100,
                    itemExtent: 60,
                    itemBuilder: (c, i) => Text('行$i'),
                  ),
                ),
              ],
            ),
            fab: CornerAddButton(tooltip: '添加', onPressed: () {}),
          ),
        ),
      );

  double opacityOf(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.descendant(
        of: find.byType(CornerFabLayer),
        matching: find.byType(AnimatedOpacity),
      ))
      .opacity;

  testWidgets('向下浏览隐藏，向上浏览出现', (tester) async {
    await tester.pumpWidget(build());
    expect(opacityOf(tester), 1);

    final list = find.byKey(const ValueKey<String>('vlist'));

    // 手指上推 = 看后面的内容（向下浏览）→ 收起。
    await tester.drag(list, const Offset(0, -200));
    await tester.pump();
    expect(opacityOf(tester), 0);

    // 停手保持收起。
    await tester.pumpAndSettle();
    expect(opacityOf(tester), 0);

    // 手指下拉 = 往回看（向上浏览）→ 出现。
    await tester.drag(list, const Offset(0, 200));
    await tester.pump();
    expect(opacityOf(tester), 1);
  });

  testWidgets('横向翻页不触发显隐', (tester) async {
    await tester.pumpWidget(build());
    await tester.drag(find.byKey(const ValueKey<String>('hlist')),
        const Offset(-200, 0));
    await tester.pump();
    expect(opacityOf(tester), 1);
  });
}
