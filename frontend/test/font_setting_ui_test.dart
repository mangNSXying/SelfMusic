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
import 'package:selfmusic/screens/settings_screen.dart';
import 'package:selfmusic/theme/app_theme.dart' show SettingsItem;
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
    dir = await Directory.systemTemp.createTemp('selfmusic_fontui_');
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

  Future<void> pumpAppearance(
    WidgetTester tester, {
    AppSettings? customSettings,
    ThemeProvider? theme,
  }) async {
    final settings = customSettings ?? AppSettings(index);
    final nav = NavigationProvider()..openSettings(SettingsItem.appearance);
    final direct = DirectSourceManager()..settings = settings;

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<ThemeProvider>.value(
            value: theme ?? ThemeProvider(autoLoad: false)),
      ],
      child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
    ));
    await tester.pump();
  }

  testWidgets('界面设置包含「文字」分区与字体导入入口', (tester) async {
    await pumpAppearance(tester);

    expect(find.text('文字'), findsOneWidget);
    expect(find.text('界面字体'), findsOneWidget);
    expect(find.text('系统默认'), findsOneWidget);
    expect(find.text('导入字体文件'), findsOneWidget);
    expect(find.text('更换字体'), findsNothing);
    expect(find.text('恢复系统字体'), findsNothing);
  });

  testWidgets('已导入字体时显示当前字体、更换与恢复入口', (tester) async {
    final settings = AppSettings(index)
      ..customFontFamily = 'SelfMusicCustomFont_test'
      ..customFontFile = 'font_test.otf'
      ..customFontLabel = '测试字体';

    await pumpAppearance(
      tester,
      customSettings: settings,
      theme: ThemeProvider(
        autoLoad: false,
        initialFontFamily: 'SelfMusicCustomFont_test',
      ),
    );

    expect(find.text('当前：测试字体'), findsOneWidget);
    expect(find.text('更换字体'), findsOneWidget);
    expect(find.text('恢复系统字体'), findsOneWidget);
    expect(find.textContaining('预览：'), findsOneWidget);
  });
}
