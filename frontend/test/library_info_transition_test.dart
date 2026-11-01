import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/layout/screen_metrics.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/services/artist_resolver.dart';
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
  testWidgets('歌曲信息进出应用页面切换动画（滑动档）', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_info_motion_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      direct.settings.playerTransition = PlayerTransition.slide;
    });
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final lib = LibraryProvider()..attachDirectManager(direct);
    final nav = NavigationProvider();
    final resolver = ArtistResolver(direct.index);
    addTearDown(resolver.dispose);

    const size = Size(1280, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<LibraryProvider>.value(value: lib),
          ChangeNotifierProvider<PlaylistsProvider>.value(
              value: PlaylistsProvider(direct.playlists)),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
          ChangeNotifierProvider<ArtistResolver>.value(value: resolver),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(autoLoad: false)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ScreenMetrics(
              windowSize: size,
              contentWidth: size.width - 260,
              child: const AppContent(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    nav.select(NavSection.songs);
    await tester.pumpAndSettle();
    nav.openLibraryInfo(LibraryInfoPage.overview);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final during = tester.getTopLeft(find.text('暂无歌曲，先去播放源页扫描')).dx;
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.text('暂无歌曲，先去播放源页扫描')).dx;
    expect(during, greaterThan(settled), reason: '歌曲信息进入应跟随「滑动」档从右侧滑入');

    nav.backToPrevious(keepSearch: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('暂无歌曲，先去播放源页扫描'), findsOneWidget);
    final leaving = tester.getTopLeft(find.text('暂无歌曲，先去播放源页扫描')).dx;
    expect(leaving, greaterThan(settled), reason: '歌曲信息退出应跟随「滑动」档向右滑出');
    await tester.pumpAndSettle();
    expect(find.text('暂无歌曲，先去播放源页扫描'), findsNothing);

    // 关于软件同样是 L2 工具页：进入/退出都走内容栈，页面内容可见。
    nav.openAbout();
    await tester.pumpAndSettle();
    expect(find.text('SelfMusic'), findsOneWidget);
    expect(find.text('收集日志'), findsOneWidget);
    nav.backToPrevious(keepSearch: true);
    await tester.pumpAndSettle();
    expect(find.text('SelfMusic'), findsNothing);
  });
}
