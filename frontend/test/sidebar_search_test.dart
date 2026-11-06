import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/sidebar.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/settings/settings_focus.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';

void main() {
  testWidgets('侧栏搜索设置：命中、跳分区、清空恢复', (tester) async {
    final nav = NavigationProvider();
    final focus = SettingsFocusController();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(autoLoad: false)),
        ],
        child: SettingsFocusScope(
          controller: focus,
          child: const MaterialApp(home: Scaffold(body: Sidebar())),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('界面'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '自签名');
    await tester.pump();

    expect(find.text('信任自签名'), findsOneWidget);
    expect(find.text('界面'), findsNothing);

    await tester.tap(find.text('信任自签名'));
    await tester.pump();

    expect(nav.settings, SettingsItem.network);
    expect(focus.pending.value, 'network/信任自签名');
    expect(find.text('信任自签名'), findsNothing);
    expect(find.text('界面'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();
    expect(find.text('没有匹配设置'), findsOneWidget);
    focus.clear();
  });
}
