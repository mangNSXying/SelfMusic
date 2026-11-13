import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/settings_layout.dart';
import 'package:selfmusic/widgets/settings_section_header.dart';
import 'package:selfmusic/widgets/settings_tile.dart';

void main() {
  testWidgets('设置页统一层级：页/组/子组/行/控件同一条 16 基线', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            children: [
              const SettingsSectionHeader('组标题'),
              const SettingsSubgroupHeader('子组标题'),
              SettingsTile.value(title: '设置行', value: '10 行'),
              const SettingsControlBlock(child: Text('控件')),
              const SettingsGroupNote('组说明'),
              const SettingsGroupDivider(),
            ],
          ),
        ),
      ),
    );

    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.padding, const EdgeInsets.only(top: 12, bottom: 16));

    final x = tester.getTopLeft(find.text('组标题')).dx;
    expect(x, 16);
    expect(tester.getTopLeft(find.text('子组标题')).dx, x);
    expect(tester.getTopLeft(find.text('设置行')).dx, x);
    expect(tester.getTopLeft(find.text('控件')).dx, x);
    expect(tester.getTopLeft(find.text('组说明')).dx, x);

    final groupY = tester.getTopLeft(find.text('组标题')).dy;
    expect(groupY, greaterThanOrEqualTo(20));
    expect(
      tester.getTopLeft(find.text('子组标题')).dy,
      greaterThan(tester.getTopLeft(find.text('组标题')).dy),
    );

    final divider = tester.widget<Divider>(find.byType(Divider));
    expect(divider.height, 24);
  });
}
