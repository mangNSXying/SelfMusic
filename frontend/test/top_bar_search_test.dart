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
}
