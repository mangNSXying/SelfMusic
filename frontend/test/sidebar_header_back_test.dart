import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/sidebar.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';

void main() {
  testWidgets('点侧栏标题行回内容页：弹空内容栈并退出播放页', (tester) async {
    final nav = NavigationProvider()..select(NavSection.albums);
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
        child: const MaterialApp(home: Scaffold(body: Sidebar())),
      ),
    );
    await tester.pump();

    nav.openSettings(SettingsItem.system);
    nav.openPlayer();
    await tester.pump();
    expect(nav.settings, SettingsItem.system);
    expect(nav.playerView, isTrue);

    await tester.tap(find.text('SelfMusic'));
    await tester.pump();

    expect(nav.contentRoutes, isEmpty);
    expect(nav.settings, isNull);
    expect(nav.playerView, isFalse);
    expect(nav.section, NavSection.albums, reason: '标题行回内容页不换分组');
  });
}
