import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/header_action_button.dart';

void main() {
  testWidgets('内容页头部主/次动作按钮使用同一紧凑高度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build().themeData,
        home: Scaffold(
          body: Row(
            children: [
              HeaderActionButton(
                primary: true,
                icon: const Icon(Icons.play_arrow),
                label: '播放',
                onPressed: () {},
              ),
              const SizedBox(width: 8),
              HeaderActionButton(
                primary: false,
                icon: const Icon(Icons.replay),
                label: '播放',
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final primary = tester.getSize(find.widgetWithText(FilledButton, '播放'));
    final secondary = tester.getSize(find.widgetWithText(OutlinedButton, '播放'));

    expect(primary, secondary);
  });
}
