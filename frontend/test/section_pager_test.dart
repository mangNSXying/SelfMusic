import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/content/section_pager.dart';
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
  testWidgets('分组 PageView：手指滑动切换分组，顶栏选择平滑切页', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    late final NavigationProvider nav;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_pager_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      // 跟手 PageView 仅在「滑动」档存在，本用例专测滑动档行为。
      direct.settings.playerTransition = PlayerTransition.slide;
    });
    final lib = LibraryProvider()..attachDirectManager(direct);
    nav = NavigationProvider();
    // 默认 songs（index 3）：断言歌曲空态可见。
    expect(nav.section, NavSection.songs);

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

    expect(find.text('暂无内容'), findsOneWidget);

    // 手指左滑 → 专辑页，导航同步。
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(nav.section, NavSection.albums);

    // 程序驱动（顶栏点击）：右滑两页回播放源，动画结束后同步。
    nav.select(NavSection.sources);
    await tester.pumpAndSettle();
    expect(nav.section, NavSection.sources);
    expect(find.textContaining('尚未添加播放源'), findsOneWidget);

    // 程序驱动到喜欢页。
    nav.select(NavSection.liked);
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无喜欢的歌曲'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('滑动后的吸附阶段点 tab：内容页必须跟随切换（不得停在旧页）',
      (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    late final NavigationProvider nav;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_pager_tap_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      direct.settings.playerTransition = PlayerTransition.slide;
    });
    addTearDown(() {
      direct.dispose();
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
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TopBar(onSidebarToggle: () {}),
                const Expanded(child: SectionPager()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(nav.section, NavSection.songs);

    // 手指左滑 → 专辑(4)。松手后 PageView 仍在吸附（isScrollingNotifier
    // 仍为 true），此时点 tab 不能被跳过，否则 section 已变、内容停在旧页。
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    expect(nav.section, NavSection.albums);

    await tester.tap(find.descendant(
        of: find.byType(TopBar), matching: find.text('播放源')));
    await tester.pumpAndSettle();

    expect(nav.section, NavSection.sources);
    expect(nav.pageOffset.value, 2.0, reason: '内容页应切到播放源');
    expect(find.textContaining('尚未添加播放源'), findsOneWidget);
  });
}
