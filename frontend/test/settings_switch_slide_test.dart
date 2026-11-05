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
import 'package:selfmusic/screens/content/app_content.dart';
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
  testWidgets('滑动档：设置分区之间切换，旧分区留在退场层直到滑出', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_settings_slide_');
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

    nav.openSettings(SettingsItem.appearance);
    await tester.pumpAndSettle();
    expect(find.text('自定义配色与字体，实时生效并保存到本机'), findsOneWidget);

    // 界面 → 歌曲：旧分区必须留在退场层（历史 bug：旧层重挂载后读到新
    // 分区，页面在原地先变成新分区，再被新的同款分区滑入覆盖）。
    nav.openSettings(SettingsItem.songs);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('自定义配色与字体，实时生效并保存到本机'), findsOneWidget,
        reason: '退场层应仍是旧分区');
    expect(find.text('缓存与离线'), findsOneWidget, reason: '新分区在滑入');
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.text('自定义配色与字体，实时生效并保存到本机'), findsNothing);
    expect(find.text('缓存与离线'), findsOneWidget);
  });
}
