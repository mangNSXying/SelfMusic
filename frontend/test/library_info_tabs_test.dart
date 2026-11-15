import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/library_info/library_info_content.dart';
import 'package:selfmusic/screens/library_info/library_info_tabs.dart';
import 'package:selfmusic/services/artist_resolver.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_info_tabs_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final mgr = DirectSourceManager();
  await mgr.init();
  addTearDown(mgr.dispose);
  return mgr;
}

void main() {
  testWidgets('歌曲信息页签：五个入口、选中态与回调', (tester) async {
    final selected = <LibraryInfoPage>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryInfoTabBar(
            current: LibraryInfoPage.overview,
            onSelect: selected.add,
          ),
        ),
      ),
    );

    for (final label in ['总览', '元数据', '歌手', '格式', '播放']) {
      expect(find.text(label), findsOneWidget);
    }

    final current = tester.widget<Text>(find.text('总览'));
    expect(current.style?.fontWeight, FontWeight.w600);
    final other = tester.widget<Text>(find.text('元数据'));
    expect(other.style?.fontWeight, FontWeight.normal);

    await tester.tap(find.byKey(const ValueKey('library-info-tab-meta')));
    expect(selected, [LibraryInfoPage.meta]);
  });

  testWidgets('歌曲信息页签：点击切换实际页面内容', (tester) async {
    late final DirectSourceManager mgr;
    await tester.runAsync(() async {
      mgr = await _openDirect();
    });
    final resolver = ArtistResolver(mgr.index);
    addTearDown(resolver.dispose);
    final nav = NavigationProvider();

    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: mgr),
          ChangeNotifierProvider<ArtistResolver>.value(value: resolver),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<NavigationProvider>(
              builder: (context, nav, _) => LibraryInfoContent(
                page: nav.libraryInfoPage ?? LibraryInfoPage.overview,
              ),
            ),
          ),
        ),
      ),
    );

    nav.openLibraryInfo(LibraryInfoPage.overview);
    await tester.pumpAndSettle();
    expect(find.text('暂无歌曲，先去播放源页扫描'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-info-tab-meta')));
    await tester.pumpAndSettle();
    expect(nav.libraryInfoPage, LibraryInfoPage.meta);
    expect(find.text('按歌曲名 / 歌手 / 专辑过滤'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-info-tab-artists')));
    await tester.pumpAndSettle();
    expect(nav.libraryInfoPage, LibraryInfoPage.artists);
    expect(find.text('暂无歌手数据'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-info-tab-overview')));
    await tester.pumpAndSettle();
    expect(nav.libraryInfoPage, LibraryInfoPage.overview);
    expect(find.text('暂无歌曲，先去播放源页扫描'), findsOneWidget);
  });
}
