import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/screens/settings/settings_focus.dart';

void main() {
  testWidgets('定位请求滚动到目标并短暂高亮', (tester) async {
    final focus = SettingsFocusController();
    final scroll = ScrollController();
    addTearDown(focus.dispose);
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      SettingsFocusScope(
        controller: focus,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: const Column(
                children: [
                  SizedBox(height: 1200),
                  SettingsFocusAnchor(
                    id: 'system/目标',
                    child: SizedBox(height: 40, child: Text('目标')),
                  ),
                  SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(scroll.offset, 0);

    focus.request('system/目标');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(focus.pending.value, isNull);
    expect(focus.highlight.value, 'system/目标');
    expect(scroll.offset, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 1700));
    expect(focus.highlight.value, isNull);
  });

  testWidgets('目标不存在时 pending 超时清理', (tester) async {
    final focus = SettingsFocusController();
    addTearDown(focus.dispose);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    focus.request('missing/target');
    await tester.pump();
    expect(focus.pending.value, 'missing/target');

    await tester.pump(const Duration(seconds: 3));
    expect(focus.pending.value, isNull);
  });
}
