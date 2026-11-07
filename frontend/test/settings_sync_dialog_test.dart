import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/screens/settings/sync_section.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
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
  late Directory dir;
  late DirectSourceManager direct;
  late AppSettings settings;
  late SyncEngine sync;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_sync_dialog_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.index.open();
    settings = AppSettings(direct.index);
    direct.settings = settings;
    sync =
        SyncEngine(api: ApiClient(), index: direct.index, settings: settings);
  });

  tearDown(() {
    sync.stop();
    direct.index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('同步设置弹窗：总开关控制四个类目，关闭后回写副标题', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          Provider<SyncEngine>.value(value: sync),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncSection()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('同步设置'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);

    await tester.tap(find.text('同步设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSyncDialog), findsOneWidget);

    final master = find.widgetWithText(SwitchListTile, '同步设置');
    expect(tester.widget<SwitchListTile>(master).value, isFalse);
    await tester.tap(master);
    await tester.pump();
    expect(settings.syncSettingsEnabled, isTrue);

    final playback = find.widgetWithText(SwitchListTile, '播放偏好');
    expect(tester.widget<SwitchListTile>(playback).onChanged, isNotNull);
    await tester.tap(playback);
    await tester.pump();
    expect(settings.syncSettingsPlayback, isFalse);
    expect(settings.syncSettingsLibrary, isTrue);

    final iface = find.widgetWithText(SwitchListTile, '界面偏好');
    expect(tester.widget<SwitchListTile>(iface).value, isFalse);
    expect(tester.widget<SwitchListTile>(iface).onChanged, isNotNull);
    await tester.tap(iface);
    await tester.pump();
    expect(settings.syncSettingsInterface, isTrue);

    final theme = find.widgetWithText(SwitchListTile, '主题外观');
    expect(tester.widget<SwitchListTile>(theme).value, isFalse);
    expect(tester.widget<SwitchListTile>(theme).onChanged, isNotNull);
    await tester.tap(theme);
    await tester.pump();
    expect(settings.syncSettingsTheme, isTrue);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSyncDialog), findsNothing);
    expect(find.textContaining('媒体库规则'), findsOneWidget);
    expect(find.textContaining('界面偏好'), findsOneWidget);
    expect(find.textContaining('主题外观'), findsOneWidget);
    expect(find.textContaining('播放偏好'), findsNothing);
  });
}
