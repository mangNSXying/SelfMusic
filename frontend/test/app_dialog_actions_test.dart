import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/app_dialog_actions.dart';

void main() {
  const scheme = ColorScheme.light(
    primary: Color(0xFF006A60),
    onPrimary: Colors.white,
    error: Color(0xFFBA1A1A),
    onError: Colors.white,
  );
  final theme = ThemeData(useMaterial3: true, colorScheme: scheme);

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool destructive,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => AlertDialog(
              title: const Text('标题'),
              content: const Text('内容'),
              actions: appDialogActions(
                context,
                confirmLabel: '删除',
                destructive: destructive,
                onCancel: () {},
                onConfirm: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('取消在左（TextButton）、确认在右（FilledButton）', (tester) async {
    await pumpDialog(tester, destructive: false);

    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '删除'), findsOneWidget);
    final cancelX = tester.getCenter(find.byType(TextButton)).dx;
    final confirmX = tester.getCenter(find.byType(FilledButton)).dx;
    expect(cancelX, lessThan(confirmX));
  });

  testWidgets('危险确认使用 error 背景 + onError 前景', (tester) async {
    await pumpDialog(tester, destructive: true);

    final style = tester.widget<FilledButton>(find.byType(FilledButton)).style!;
    expect(style.backgroundColor?.resolve({}), scheme.error);
    expect(style.foregroundColor?.resolve({}), scheme.onError);
  });
}
