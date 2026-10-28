import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/settings_screen.dart';
import 'package:selfmusic/services/server_settings.dart';
import 'package:selfmusic/shortcuts/shortcut_settings.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:sqlite3/open.dart';

/// 常规分区：备份页并入后只保留一个「备份与迁移」入口，点击弹窗列出本机备份。
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

  testWidgets('常规页「备份与迁移」入口：弹窗列出本机备份与导入导出动作', (tester) async {
    final backupDir = Directory('${direct.index.dir}/backups')
      ..createSync(recursive: true);
    const backupName = 'selfmusic-settings-20261026000000.json';
    File('${backupDir.path}/$backupName')
        .writeAsStringSync('{"schema":1,"type":"settings"}');

    final settings = AppSettings(direct.index);
    direct.settings = settings;
    final nav = NavigationProvider()..openSettings(SettingsItem.general);

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
        ChangeNotifierProvider<ServerSettings>.value(value: ServerSettings()),
        ChangeNotifierProvider<ShortcutSettings>.value(
            value: ShortcutSettings(settings)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SettingsScreen()),
      ),
    ));
    await tester.pump();

    expect(find.text('视图行为'), findsOneWidget);
    expect(find.text('长按展开/折叠'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
    expect(find.text('日志时长'), findsOneWidget);

    await tester.tap(find.text('日志时长'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('导出最近 1 分钟的日志'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.logExportMinutes, 1);

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
