import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/marquee_text.dart';

Finder _in(Finder f) =>
    find.descendant(of: find.byType(MarqueeText), matching: f);

void main() {
  testWidgets('短文不启用滚动，直接以内联文本渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 300, child: MarqueeText('短标题')),
      ),
    ));

    final text = tester.widget<Text>(_in(find.byType(Text)).first);
    expect(text.data, '短标题');
    expect(_in(find.byType(AnimatedBuilder)), findsNothing);
  });

  testWidgets('超长文启用横向滚动，始终保持单行', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 100, child: MarqueeText('这是一个足够长的标题需要横向滚动展示完整内容')),
      ),
    ));

    await tester.pump();
    expect(_in(find.byType(AnimatedBuilder)), findsOneWidget);

    final text = tester.widget<Text>(
        _in(find.descendant(of: find.byType(Stack), matching: find.byType(Text))));
    expect(text.maxLines, 1);
    expect(text.softWrap, false);
    expect(text.data, '这是一个足够长的标题需要横向滚动展示完整内容');
  });

  testWidgets('滚动位置随时间变化（平移动画生效）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 100, child: MarqueeText('abcdefghijklmnopqrstuvwxyz1234567890')),
      ),
    ));
    await tester.pump();

    Offset offsetAt(WidgetTester t) {
      final tr = t.widget<Transform>(
          _in(find.descendant(of: find.byType(AnimatedBuilder), matching: find.byType(Transform))));
      final v = tr.transform.getTranslation();
      return Offset(v.x, v.y);
    }

    final a = offsetAt(tester);
    await tester.pump(const Duration(seconds: 1));
    final b = offsetAt(tester);
    expect(b, isNot(equals(a)));
  });
}