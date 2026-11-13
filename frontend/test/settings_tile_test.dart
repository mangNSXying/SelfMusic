import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/settings_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Column(children: [child])),
    ));
  }

  testWidgets('设置行：左名称上、解释下，右为当前值', (tester) async {
    await pump(
      tester,
      SettingsTile(
        title: '歌词行数',
        description: '按歌词区高度放大字号',
        trailing: const SettingsValueText('10 行'),
        onTap: () {},
      ),
    );

    expect(find.text('歌词行数'), findsOneWidget);
    expect(find.text('按歌词区高度放大字号'), findsOneWidget);
    expect(find.text('10 行'), findsOneWidget);

    final titleX = tester.getTopLeft(find.text('歌词行数')).dx;
    final descX = tester.getTopLeft(find.text('按歌词区高度放大字号')).dx;
    final valueX = tester.getTopLeft(find.text('10 行')).dx;
    expect(descX, titleX, reason: '解释与名称左对齐');
    expect(
      tester.getTopLeft(find.text('按歌词区高度放大字号')).dy,
      greaterThan(tester.getTopLeft(find.text('歌词行数')).dy),
      reason: '解释在名称下方',
    );
    expect(valueX, greaterThan(titleX), reason: '当前值在右侧');
  });

  testWidgets('开关行：点击整行与开关都能切换', (tester) async {
    var value = false;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => SettingsTile.toggle(
          title: '加权随机',
          description: '按权重抽歌',
          value: value,
          onChanged: (v) => setState(() => value = v),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(value, isTrue);

    await tester.tap(find.text('加权随机'));
    await tester.pump();
    expect(value, isFalse);
  });

  testWidgets('禁用行：不可点击且当前值变灰', (tester) async {
    var tapped = false;
    await pump(
      tester,
      SettingsTile(
        title: '次数冷却',
        description: '刚播过的歌先跳过',
        trailing: const SettingsValueText('正常', enabled: false),
        enabled: false,
        onTap: () => tapped = true,
      ),
    );

    await tester.tap(find.text('次数冷却'));
    await tester.pump();
    expect(tapped, isFalse);
  });

  testWidgets('右侧值与开关轨道右缘对齐', (tester) async {
    await pump(
      tester,
      Column(
        children: [
          SettingsTile.toggle(
            title: '带开关',
            value: false,
            onChanged: (_) {},
          ),
          SettingsTile.value(title: '取值行', value: '10 行'),
        ],
      ),
    );

    final switchRight = tester.getRect(find.byType(Switch)).right;
    final valueRight = tester.getRect(find.text('10 行')).right;
    // 开关控件左右各留 4px，轨道右缘为控件右缘 - 4。
    expect(valueRight, switchRight - 4);
  });

  testWidgets('行内不再绘制右箭头图标', (tester) async {
    await pump(
      tester,
      SettingsTile(
        title: '标题格式',
        trailing: const SettingsValueText('歌手 - 歌名'),
        onTap: () {},
      ),
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('动作行：主色文字 + 小箭头，点击可执行', (tester) async {
    var tapped = false;
    await pump(
      tester,
      SettingsTile.action(
        title: '重试解析',
        label: '开始',
        onTap: () => tapped = true,
      ),
    );

    expect(find.text('开始'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('重试解析'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('动作行禁用：不显示箭头高亮且不可点击', (tester) async {
    var tapped = false;
    await pump(
      tester,
      SettingsTile.action(
        title: '设备管理',
        label: '查看',
        onTap: () => tapped = true,
        enabled: false,
      ),
    );

    final context = tester.element(find.text('查看'));
    final text = tester.widget<Text>(find.text('查看'));
    expect(text.style?.color, isNot(Theme.of(context).colorScheme.primary));
    await tester.tap(find.text('设备管理'));
    await tester.pump();
    expect(tapped, isFalse);
  });
}
