import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/navigation_provider.dart';

void main() {
  testWidgets('顶栏搜索输入后保持焦点（controller 不重建）', (tester) async {
    final nav = NavigationProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: MaterialApp(
          home: Scaffold(
            body: TopBar(onSidebarToggle: () {}),
          ),
        ),
      ),
    );

    final ctrlBefore =
        tester.widget<TextField>(find.byType(TextField)).controller;
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();

    expect(nav.search, 'abc');
    final ctrlAfter =
        tester.widget<TextField>(find.byType(TextField)).controller;
    expect(identical(ctrlBefore, ctrlAfter), isTrue,
        reason: 'build 中不应重建 TextEditingController');

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue, reason: '输入后应保持焦点');

    // 连续输入不丢焦点；清空按钮只清文本、保留焦点。
    await tester.enterText(find.byType(TextField), 'abcd');
    await tester.pump();
    expect(nav.search, 'abcd');
    expect(editable.focusNode.hasFocus, isTrue);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(nav.search, '');
    expect(editable.focusNode.hasFocus, isTrue);
  });

  testWidgets('顶栏搜索：点击搜索框外 / 键盘提交后失焦，还原输入法收起',
      (tester) async {
    final nav = NavigationProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TopBar(onSidebarToggle: () {}),
                const Expanded(child: Center(child: Text('空白区'))),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    var editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);

    // 点击搜索框外 → 失焦（onTapOutside）。
    await tester.tapAt(tester.getCenter(find.text('空白区')));
    await tester.pump();
    editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);

    // 再次聚焦并键盘「搜索」提交 → 与手动收起输入框等价，失焦。
    await tester.tap(find.byType(TextField));
    await tester.pump();
    editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);
    expect(nav.search, 'abc');
  });
}
