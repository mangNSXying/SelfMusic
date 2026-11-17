import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/confirm_dialog.dart';

void main() {
  const scheme = ColorScheme.light(
    primary: Color(0xFF006A60),
    onPrimary: Colors.white,
    error: Color(0xFFBA1A1A),
    onError: Colors.white,
  );
  final theme = ThemeData(useMaterial3: true, colorScheme: scheme);

  Future<void> pumpLauncher(
    WidgetTester tester, {
    required void Function(bool) onResult,
    String cancelLabel = '取消',
    bool destructive = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: '删除备份',
                  content: '确定删除该备份？',
                  cancelLabel: cancelLabel,
                  confirmLabel: '删除',
                  destructive: destructive,
                );
                onResult(ok);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('确认返回 true，取消返回 false', (tester) async {
    bool? result;
    await pumpLauncher(tester, onResult: (v) => result = v);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('删除备份'), findsOneWidget);
    expect(find.text('确定删除该备份？'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    result = null;
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('支持自定义取消文案与危险确认样式', (tester) async {
    bool? result;
    await pumpLauncher(
      tester,
      onResult: (v) => result = v,
      cancelLabel: '保留',
      destructive: true,
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '保留'), findsOneWidget);

    final style = tester.widget<FilledButton>(find.byType(FilledButton)).style!;
    expect(style.backgroundColor?.resolve({}), scheme.error);
    expect(style.foregroundColor?.resolve({}), scheme.onError);

    await tester.tap(find.widgetWithText(TextButton, '保留'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
