import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/about_screen.dart';
import 'package:selfmusic/screens/settings/settings_screen.dart';
import 'package:selfmusic/screens/settings/settings_search_index.dart';
import 'package:selfmusic/services/update_service.dart';
import 'package:selfmusic/shortcuts/shortcut_settings.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/update_dialog.dart';
import 'package:sqlite3/open.dart';

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
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_update_');
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

  test('更新源默认 Gitea，切换后持久化', () {
    final settings = AppSettings(index);
    expect(settings.updateSource, UpdateSource.gitea);

    settings.updateSource = UpdateSource.github;
    expect(AppSettings(index).updateSource, UpdateSource.github,
        reason: '持久化往返');

    expect(UpdateSource.parse(null), UpdateSource.gitea);
    expect(UpdateSource.parse('bogus'), UpdateSource.gitea);
  });

  test('自动检查默认开启，关闭后持久化', () {
    final settings = AppSettings(index);
    expect(settings.updateAutoCheck, isTrue);
    settings.updateAutoCheck = false;
    expect(AppSettings(index).updateAutoCheck, isFalse);
  });

  test('延后时刻与忽略版本往返（含清空）', () {
    final settings = AppSettings(index);
    expect(settings.updateSnoozeUntil, isNull);
    expect(settings.updateSnoozeVersion, isEmpty);
    expect(settings.updateSkipVersion, isEmpty);

    final until = DateTime(2026, 11, 30, 8, 30);
    settings.updateSnoozeVersion = '1.0.5';
    settings.updateSnoozeUntil = until;
    settings.updateSkipVersion = '1.0.5';
    expect(AppSettings(index).updateSnoozeUntil, until);
    expect(AppSettings(index).updateSnoozeVersion, '1.0.5');
    expect(AppSettings(index).updateSkipVersion, '1.0.5');

    // 清空延后时刻时一并清掉延后版本号。
    settings.updateSnoozeUntil = null;
    settings.updateSkipVersion = '';
    expect(settings.updateSnoozeUntil, isNull);
    expect(settings.updateSnoozeVersion, isEmpty);
    expect(settings.updateSkipVersion, isEmpty);
  });

  test('用户设置项进 knownKeys，提醒状态不进', () {
    expect(AppSettings.knownKeys, contains(AppSettings.kUpdateSource));
    expect(AppSettings.knownKeys, contains(AppSettings.kUpdateAutoCheck));
    for (final local in [
      AppSettings.kUpdateSnoozeUntilMs,
      AppSettings.kUpdateSnoozeVersion,
      AppSettings.kUpdateSkipVersion,
    ]) {
      expect(AppSettings.knownKeys, isNot(contains(local)),
          reason: '本机提醒状态，不随设置导出/同步：$local');
    }
  });

  test('搜索索引含更新分组', () {
    final source =
        settingsSearchEntries.firstWhere((e) => e.label == '更新源');
    expect(source.section, SettingsItem.system);
    expect(source.group, '更新');
    expect(source.aliases, contains('gitea'));
    expect(source.id, '${SettingsItem.system.name}/更新源');

    final auto =
        settingsSearchEntries.firstWhere((e) => e.label == '自动检查');
    expect(auto.section, SettingsItem.system);
    expect(auto.group, '更新');

    expect(searchSettings('检查更新'), isNotEmpty);
    expect(searchSettings('更新源').first.label, '更新源');
  });

  testWidgets('关于软件页含「检查更新」行，标注当前更新源', (tester) async {
    final settings = AppSettings(index);
    final direct = DirectSourceManager()..settings = settings;
    addTearDown(direct.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: const MaterialApp(home: Scaffold(body: AboutScreen())),
      ),
    );
    await tester.pump();

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.textContaining('更新源：Gitea'), findsOneWidget);
    // 原有入口不受影响。
    expect(find.text('收集日志'), findsOneWidget);
    expect(find.text('反馈'), findsOneWidget);
  });

  testWidgets('窄屏下更新弹窗动作按钮折返而非每按钮一行', (tester) async {
    // 360dp 手机：弹窗宽 280，动作区约 232；Wrap 应折成两行而不是四行。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const release = ReleaseInfo(
      tag: '1.1.0',
      name: 'release_1.1.0',
      body: '修复若干问题。',
      pageUrl: 'https://example.com/release/1.1.0',
      assets: [],
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build().themeData,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showUpdateDialog(
                context,
                release: release,
                currentVersion: '1.0.0',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final rows = {
      for (final label in ['取消', '之后提醒', '不再提醒', '更新'])
        tester.getCenter(find.text(label)).dy,
    };
    expect(rows.length, lessThanOrEqualTo(2),
        reason: '应折返成两行，而不是每枚按钮各占一行');
    expect(tester.takeException(), isNull, reason: '不应出现溢出报错');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('极窄屏下更新弹窗动作按钮折返而非溢出', (tester) async {
    // 320dp：一行确实放不下，Wrap 应折成两行且无 RenderFlex 溢出。
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const release = ReleaseInfo(
      tag: '1.1.0',
      name: 'release_1.1.0',
      body: '修复若干问题。',
      pageUrl: 'https://example.com/release/1.1.0',
      assets: [],
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build().themeData,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showUpdateDialog(
                context,
                release: release,
                currentVersion: '1.0.0',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '不应出现溢出报错');
    for (final label in ['取消', '之后提醒', '不再提醒', '更新']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('系统页「更新」分组：更新源可切换、自动检查开关生效', (tester) async {
    final settings = AppSettings(index);
    final direct = DirectSourceManager()..settings = settings;
    addTearDown(direct.dispose);
    final nav = NavigationProvider()..openSettings(SettingsItem.system);

    tester.view.physicalSize = const Size(1200, 4000);
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
    await tester.pumpAndSettle();

    // 分组与两行都在。
    expect(find.text('更新'), findsOneWidget);
    expect(find.text('更新源'), findsOneWidget);
    expect(find.text('自动检查'), findsOneWidget);
    expect(find.text('开启软件时自动检查更新并弹窗提醒'), findsOneWidget);
    expect(find.text('Gitea'), findsOneWidget);

    // 更新源：弹窗选 GitHub 后持久化。
    await tester.tap(find.text('更新源'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(settings.updateSource, UpdateSource.github);
    expect(find.text('GitHub'), findsOneWidget, reason: '行内显示新值');

    // 自动检查：点整行关闭（页面还有其它开关，按行文案定位）。
    expect(settings.updateAutoCheck, isTrue);
    await tester.tap(find.text('自动检查'));
    await tester.pumpAndSettle();
    expect(settings.updateAutoCheck, isFalse);
  });
}
