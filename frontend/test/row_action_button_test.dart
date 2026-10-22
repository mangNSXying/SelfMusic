import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/theme/app_metrics.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/row_action_button.dart';

void main() {
  testWidgets('列表行右侧动作按钮使用紧凑尺寸', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build().themeData,
        home: Scaffold(
          body: Row(
            children: [
              RowActionIconButton(
                icon: Icons.copy_outlined,
                tooltip: '复制',
                onPressed: () {},
              ),
              RowActionTextButton(
                label: '设置',
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(IconButton)),
      const Size(kRowActionButtonSize, kRowActionButtonSize),
    );
    expect(
      tester.getSize(find.byIcon(Icons.copy_outlined)),
      const Size(kRowActionIconSize, kRowActionIconSize),
    );
    expect(
      tester.getSize(find.widgetWithText(TextButton, '设置')).height,
      kRowActionTextButtonHeight,
    );
  });
}
