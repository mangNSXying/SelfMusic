import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/settings/settings_screen.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/server_settings.dart';
import 'package:selfmusic/shortcuts/shortcut_settings.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:sqlite3/open.dart';

/// 系统 / 存储分区：日志在系统，备份与迁移在存储。
ffi.DynamicLibrary _openOnLinux() {
  try {
    return ffi.DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return ffi.DynamicLibrary.open('libsqlite3.so.0');
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
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_backup_entry_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.index.open();
  });

  tearDown(() {
    direct.index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('系统页：快捷键 / 桌面和后台 / 诊断，日志时长可改', (tester) async {
    final settings = AppSettings(direct.index);
    direct.settings = settings;
    final nav = NavigationProvider()..openSettings(SettingsItem.system);

    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<ShortcutSettings>.value(
            value: ShortcutSettings(settings)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SettingsScreen(item: SettingsItem.system)),
      ),
    ));
    await tester.pump();

    expect(find.text('快捷键'), findsOneWidget);
    expect(find.text('窗口内'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('桌面和后台'), findsOneWidget);
    expect(find.text('通知栏控制'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('日志时长'), findsOneWidget);

    await tester.tap(find.text('日志时长'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('导出最近该时长内的日志'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(settings.logExportMinutes, 2);
  });

  testWidgets('存储页「备份与迁移」入口：弹窗列出本机备份与导入导出动作', (tester) async {
    final backupDir = Directory('${direct.index.dir}/backups')
      ..createSync(recursive: true);
    const backupName = 'selfmusic-settings-20261026000000.json';
    File('${backupDir.path}/$backupName')
        .writeAsStringSync('{"schema":1,"type":"settings"}');

    final settings = AppSettings(direct.index);
    direct.settings = settings;
    final nav = NavigationProvider()..openSettings(SettingsItem.storage);

    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
        ChangeNotifierProvider<ServerSettings>.value(value: ServerSettings()),
        Provider<ApiClient>.value(value: ApiClient()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SettingsScreen(item: SettingsItem.storage)),
      ),
    ));
    await tester.pump();

    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.text('收藏自动缓存'), findsOneWidget);
    expect(find.text('缓存容量'), findsOneWidget);
    expect(find.text('缓存位置'), findsOneWidget);
    expect(find.text('缓存目录'), findsOneWidget);
    expect(find.text('封面缓存'), findsOneWidget);
    expect(find.text('压缩画质'), findsOneWidget);
    expect(find.text('清理缩略图'), findsOneWidget);
    expect(find.text('备份与迁移'), findsOneWidget);

    await tester.tap(find.text('备份与迁移'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('导出设置'), findsOneWidget);
    expect(find.text('导入设置'), findsOneWidget);
    expect(find.text('导出歌单'), findsOneWidget);
    expect(find.text('导入歌单'), findsOneWidget);
    expect(find.text('本机备份'), findsOneWidget);
    expect(find.text(backupName), findsOneWidget);
  });
}
