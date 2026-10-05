import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
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
  testWidgets('滑动档：首帧空闲后开启邻页预构建；跨多页跳页不穿中间页',
      (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    late final NavigationProvider nav;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_pager_jump_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      direct.settings.playerTransition = PlayerTransition.slide;
    });
    addTearDown(() {
      // Windows 下写连接可能仍占用库文件，删不掉就留给系统临时目录。
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final lib = LibraryProvider()..attachDirectManager(direct);
    nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<LibraryProvider>.value(value: lib),
          ChangeNotifierProvider<PlaylistsProvider>.value(
              value: PlaylistsProvider(direct.playlists)),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(home: Scaffold(body: SectionPager())),
      ),
    );
    await tester.pumpAndSettle();

    // 首帧空闲后的邻页预构建（懒列表：只建可能显示的行）。
    expect(
        tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling,
        isTrue);

    // 歌曲(3) → 喜欢(1)：跨两页。记录实时页码，断言从未经过中间页(2)。
    final seen = <double>[];
    void record() => seen.add(nav.pageOffset.value);
    nav.pageOffset.addListener(record);
    addTearDown(() => nav.pageOffset.removeListener(record));

    nav.select(NavSection.liked);
    await tester.pump(); // 消费帧后 jump + 入场动画启动
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(nav.section, NavSection.liked);
    expect(find.textContaining('暂无喜欢的歌曲'), findsOneWidget);
    expect(
      seen.every((v) => (v - 3).abs() < 0.05 || (v - 1).abs() < 0.05),
      isTrue,
      reason: '跨页过程中出现了中间页页码：$seen',
    );
  });
}
