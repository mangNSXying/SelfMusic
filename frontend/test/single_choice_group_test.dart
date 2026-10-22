import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/single_choice_group.dart';

void main() {
  testWidgets('窄屏下多选一选项自动换行，不横向滚动', (tester) async {
    var value = 'webdav';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build().themeData,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: StatefulBuilder(
                builder: (context, setState) => SingleChoiceGroup<String>(
                  options: const [
                    SingleChoiceOption(
                      value: 'webdav',
                      label: 'WebDAV',
                      icon: Icons.cloud_outlined,
                    ),
                    SingleChoiceOption(
                      value: 'local',
                      label: '本地文件夹',
                      icon: Icons.folder_outlined,
                    ),
                    SingleChoiceOption(
                      value: 'sftp',
                      label: 'SFTP',
                      icon: Icons.storage_outlined,
                    ),
                    SingleChoiceOption(
                      value: 'smb',
                      label: 'SMB',
                      icon: Icons.dns_outlined,
                    ),
                  ],
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byType(Wrap), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('SMB')).dy,
      greaterThan(tester.getTopLeft(find.text('WebDAV')).dy),
    );

    final wrapRect = tester.getRect(find.byType(Wrap));
    for (final key in ['webdav', 'local', 'sftp', 'smb']) {
      final optionRect = tester.getRect(find.byKey(ValueKey(key)));
      expect(optionRect.left, greaterThanOrEqualTo(wrapRect.left));
      expect(optionRect.right, lessThanOrEqualTo(wrapRect.right));
    }

    await tester.tap(find.text('本地文件夹'));
    await tester.pump();
    expect(value, 'local');
  });
}
