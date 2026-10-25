import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/sidebar.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';

/// 侧边栏设置分区顺序（改进.txt：把「歌曲」移到「播放」前）。
void main() {
  test('SettingsItem 顺序：歌曲在播放前', () {
    final labels = SettingsItem.values.map((e) => e.label).toList();
    expect(labels.indexOf('歌曲'), lessThan(labels.indexOf('播放')));
    expect(labels, ['常规', '备份', '歌曲', '播放', '界面', '通知', '服务端']);
  });

  testWidgets('侧边栏按该顺序渲染分区', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>(
              create: (_) => NavigationProvider()),
          ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(autoLoad: false)),
        ],
        child: const MaterialApp(home: Scaffold(body: Sidebar())),
      ),
    );
    await tester.pump();

    final ys = <String, double>{};
    for (final item in SettingsItem.values) {
      final f = find.text(item.label);
      expect(f, findsOneWidget, reason: '缺少分区 ${item.label}');
      ys[item.label] = tester.getTopLeft(f).dy;
    }
    // 自上而下顺序与枚举一致
    final order = SettingsItem.values.map((e) => ys[e.label]!).toList();
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThan(order[i - 1]),
          reason:
              '${SettingsItem.values[i].label} 应排在 ${SettingsItem.values[i - 1].label} 之后');
    }
  });
}
