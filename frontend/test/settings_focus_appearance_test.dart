import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/settings/settings_focus.dart';
import 'package:selfmusic/screens/settings/settings_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_focusui_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('定位请求滚动真实界面页并高亮目标', (tester) async {
    final settings = AppSettings(index);
    final direct = DirectSourceManager()..settings = settings;
    final nav = NavigationProvider()..openSettings(SettingsItem.appearance);
    final focus = SettingsFocusController();
    addTearDown(focus.dispose);

    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SettingsFocusScope(
        controller: focus,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<ThemeProvider>.value(
                value: ThemeProvider(autoLoad: false)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SettingsScreen(item: SettingsItem.appearance),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final target = find.widgetWithText(SwitchListTile, '长按组头');
    expect(target, findsOneWidget);
    final anchor =
        find.byKey(const ValueKey<String>('settings-anchor:appearance/长按组头'));
    expect(anchor, findsOneWidget);
    expect(
      SettingsFocusScope.maybeOf(tester.element(anchor)),
      same(focus),
      reason: '锚点应能读到定位控制器',
    );
    final before = tester.getTopLeft(target).dy;
    expect(before, greaterThan(600), reason: '目标初始在视口外');

    focus.request('appearance/长按组头');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(focus.highlight.value, 'appearance/长按组头');
    final after = tester.getTopLeft(target).dy;
    expect(after, lessThan(before));
    expect(after, lessThan(600), reason: '目标应滚入视口');
    focus.clear();
  });
}
