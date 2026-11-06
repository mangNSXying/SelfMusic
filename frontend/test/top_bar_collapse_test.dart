import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/app_shell.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
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

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_topbar_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

const _listKey = ValueKey<String>('content-list');

Widget _app(DirectSourceManager direct) => MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<NavigationProvider>(
              create: (_) => NavigationProvider()),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
          // 宽屏会挂侧栏，侧栏要读主题（不落盘，避免碰安全存储插件）。
          ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(autoLoad: false)),
        ],
        child: AppShell(
          content: ListView.builder(
            key: _listKey,
            itemCount: 100,
            itemExtent: 60,
            itemBuilder: (c, i) => Text('行$i'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('窄屏：向下浏览收起顶栏（搜索+Tab），向上浏览展开', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(direct));
    await tester.pump();

    final bar = find.byType(TopBar);
    final expanded = tester.getSize(bar).height;
    expect(expanded, greaterThan(100), reason: '展开态含搜索行 + 分组 Tab');

    // 手指上推 = 看后面的内容 → 整段收起（只剩状态栏占位，本测试无 padding）。
    await tester.drag(find.byKey(_listKey), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getSize(bar).height, closeTo(0, 0.01));

    // 停手保持收起。
    expect(tester.getSize(bar).height, closeTo(0, 0.01));

    // 手指下拉 = 往回看 → 展开。
    await tester.drag(find.byKey(_listKey), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getSize(bar).height, closeTo(expanded, 1));

    await tester.runAsync(() async => direct.dispose());
  });

  testWidgets('宽屏：滚动不收起顶栏', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(direct));
    await tester.pumpAndSettle();

    final bar = find.byType(TopBar);
    final expanded = tester.getSize(bar).height;

    await tester.drag(find.byKey(_listKey), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getSize(bar).height, closeTo(expanded, 0.01));

    await tester.runAsync(() async => direct.dispose());
  });
}
