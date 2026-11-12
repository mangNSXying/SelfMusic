import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/wheel_picker_dialog.dart';

void main() {
  testWidgets('数字滚轮：↑↓ 选择，Enter 确认', (tester) async {
    int? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                picked = await showNumberWheelDialog(
                  context: context,
                  title: '测试滚轮',
                  value: 5,
                  values: wheelRange(1, 9, 1),
                  labelOf: (v) => '$v 秒',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('测试滚轮'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked, 6);
  });

  testWidgets('多列滚轮：←→ 切换列，未选中有效值时禁用确定', (tester) async {
    int? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                picked = await showWheelPickerDialog<int>(
                  context: context,
                  title: '测试时长',
                  columns: [
                    WheelColumn(labels: [for (var h = 0; h <= 2; h++) '$h 小时']),
                    WheelColumn(labels: [for (var m = 0; m <= 5; m++) '$m 分']),
                  ],
                  initialIndices: [0, 0],
                  resultOf: (idx) => idx[0] * 60 + idx[1],
                  valid: (v) => v > 0,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 1);
  });
}
