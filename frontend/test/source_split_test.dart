import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/layout/screen_metrics.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/services/artist_resolver.dart';
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

/// 自动扫描计数 + 跳过真实 I/O（与 `source_browse_search_test` 同口径）。
class _CountingManager extends DirectSourceManager {
  int scanCalls = 0;

  @override
  Future<ScanSummary> scanSource(String key) async {
    scanCalls++;
    throw StateError('测试跳过扫描');
  }
}

class _FakeResolver extends ArtistResolver {
  _FakeResolver(super._index);
}

class _Harness {
  _Harness({
    required this.dir,
    required this.direct,
    required this.lib,
    required this.nav,
    required this.keyA,
    required this.keyB,
  });

  final Directory dir;
  final _CountingManager direct;
  final LibraryProvider lib;
  final NavigationProvider nav;
  final String keyA;
  final String keyB;
}

Future<void> _dispose(_Harness h) async {
  h.nav.dispose();
  h.lib.dispose();
  h.direct.index.close();
  h.direct.dispose();
  for (var i = 0; i < 20; i++) {
    try {
      if (!h.dir.existsSync()) return;
      h.dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
    }
  }
}

/// 装配真实索引 + `AppContent`：两个本地源，各有一首歌（甲源还有子目录）。
///
/// [contentWidth] 模拟内容区可用宽度（生产由 AppShell 下发）：1020 够两栏，
/// 600 退回整页形态。`viewModeSources=card` 同样退回整页形态。
Future<_Harness> _pump(
  WidgetTester tester, {
  double contentWidth = 1020,
  CollectionViewMode viewMode = CollectionViewMode.list,
}) async {
  late final Directory dir;
  late final _CountingManager direct;
  late final String keyA;
  late final String keyB;

  await tester.runAsync(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_source_split_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = _CountingManager();
    await direct.init();
    direct.settings.playerTransition = PlayerTransition.none;
    direct.settings.viewModeSources = viewMode;

    final aDir = Directory('${dir.path}/a')..createSync();
    final bDir = Directory('${dir.path}/b')..createSync();
    await direct.addLocal(name: '源甲', path: aDir.path);
    await direct.addLocal(name: '源乙', path: bDir.path);
    keyA = direct.sources.firstWhere((s) => s.name == '源甲').key;
    keyB = direct.sources.firstWhere((s) => s.name == '源乙').key;
    await direct.index.upsertSongs([
      DirectSongRow(
        sourceKey: keyA,
        ref: '甲曲.mp3',
        title: '甲曲',
        artist: '甲歌手',
        album: '甲专辑',
        duration: 100,
        format: 'mp3',
        size: 1024,
        mtime: 1,
      ),
      DirectSongRow(
        sourceKey: keyA,
        ref: '专辑/甲曲二.mp3',
        title: '甲曲二',
        artist: '甲歌手',
        album: '甲专辑',
        duration: 100,
        format: 'mp3',
        size: 1024,
        mtime: 2,
      ),
      DirectSongRow(
        sourceKey: keyB,
        ref: '乙曲.mp3',
        title: '乙曲',
        artist: '乙歌手',
        album: '乙专辑',
        duration: 120,
        format: 'mp3',
        size: 1024,
        mtime: 3,
      ),
    ]);
    await direct.index.flushWrites();
  });

  final lib = LibraryProvider()..attachDirectManager(direct);
  final nav = NavigationProvider()..select(NavSection.sources);
  final player = PlayerProvider();
  final resolver = _FakeResolver(direct.index);
  addTearDown(player.dispose);
  addTearDown(resolver.dispose);

  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<ArtistResolver>.value(value: resolver),
        ChangeNotifierProvider<PlaylistsProvider>.value(
            value: PlaylistsProvider(direct.playlists)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ScreenMetrics(
            windowSize: const Size(1280, 800),
            contentWidth: contentWidth,
            child: const AppContent(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  return _Harness(
    dir: dir,
    direct: direct,
    lib: lib,
    nav: nav,
    keyA: keyA,
    keyB: keyB,
  );
}

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
  });

  group('源内目录返回链', () {
    test('先退目录再退源，keepSearch 只清右栏', () {
      final nav = NavigationProvider()..select(NavSection.sources);

      nav.enterSource('local:test');
      nav.setSourceDir('a/b');
      expect(nav.sourceDir, 'a/b');

      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.sourceDir, 'a');
      expect(nav.browsingSourceKey, 'local:test');

      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.sourceDir, '');
      expect(nav.browsingSourceKey, 'local:test');

      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.browsingSourceKey, isNull);
    });

    test('搜索态下目录不可见：返回直接退出源内', () {
      final nav = NavigationProvider()..select(NavSection.sources);
      nav.enterSource('local:test');
      nav.setSourceDir('a');
      nav.setSearch('甲');
      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.browsingSourceKey, isNull);
    });
  });

  group('播放源分栏（大横屏 + 列表）', () {
    testWidgets('右栏空态 → 点源进右栏，左栏行高亮且不整页替换', (tester) async {
      final h = await _pump(tester);
      addTearDown(() => _dispose(h));

      expect(find.text('从左侧选择播放源浏览'), findsOneWidget);
      expect(find.text('共 2 个播放源'), findsOneWidget);
      expect(find.text('源甲'), findsOneWidget);
      final rowX = tester.getTopLeft(find.text('源甲')).dx;

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();

      expect(h.nav.browsingSourceKey, h.keyA);
      // 右栏头部（返回 / 标题 / 扫描）+ 歌曲；左栏行与计数头仍在原位。
      expect(find.byTooltip('返回播放源'), findsOneWidget);
      // 左栏行 + 右栏标题；表格行的「播放源」列还会重复源名。
      expect(find.text('源甲'), findsAtLeastNWidgets(2));
      expect(find.text('扫描'), findsOneWidget);
      expect(find.textContaining('甲曲'), findsWidgets);
      expect(find.text('共 2 个播放源'), findsOneWidget);
      expect(tester.getTopLeft(find.text('源甲').first).dx, rowX);

      // 左栏当前行有底色提示。
      final tile = tester.widget<ListTile>(find
          .ancestor(of: find.text('源甲').first, matching: find.byType(ListTile))
          .first);
      expect(tile.tileColor, isNotNull);

      await tester.tap(find.text('源乙').first);
      await tester.pumpAndSettle();
      expect(h.nav.browsingSourceKey, h.keyB);
      expect(find.text('源乙'), findsAtLeastNWidgets(2));
      expect(find.text('源甲'), findsOneWidget, reason: '右栏应已换成新源');
      expect(find.textContaining('甲曲'), findsNothing);
      expect(find.textContaining('乙曲'), findsOneWidget);

      await tester.tap(find.byTooltip('返回播放源'));
      await tester.pumpAndSettle();
      expect(h.nav.browsingSourceKey, isNull);
      expect(find.text('从左侧选择播放源浏览'), findsOneWidget);
    });

    testWidgets('搜索词跨开关右栏保留；左栏按源名、右栏按曲目同时过滤', (tester) async {
      final h = await _pump(tester);
      addTearDown(() => _dispose(h));

      h.nav.setSearch('源');
      await tester.pumpAndSettle();
      expect(find.text('共 2 个播放源'), findsOneWidget);

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();
      expect(h.nav.search, '源', reason: '分栏时搜索框就是左栏过滤器');
      expect(h.nav.browsingSourceKey, h.keyA);
      // 右栏按同一搜索词过滤源内曲目（甲曲不含「源」）。
      expect(find.text('该源内没有匹配的歌曲'), findsOneWidget);

      // 右栏返回只清右栏，搜索词与左栏行都保留。
      await tester.tap(find.byTooltip('返回播放源'));
      await tester.pumpAndSettle();
      expect(h.nav.browsingSourceKey, isNull);
      expect(h.nav.search, '源');
      expect(find.text('源甲'), findsOneWidget);
    });

    testWidgets('右栏在子目录时返回只退一层目录，到源根才清空右栏', (tester) async {
      final h = await _pump(tester);
      addTearDown(() => _dispose(h));

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();
      // 表格模式标题只显示歌名（歌手在独立列），默认的「歌手 - 歌名」不再拼接。
      expect(find.text('甲曲'), findsOneWidget, reason: '根目录直接显示本层歌曲');

      // 文件夹行也是 ListTile；表头「专辑」不是 ListTile，避免误点。
      await tester.tap(find.widgetWithText(ListTile, '专辑'));
      await tester.pumpAndSettle();
      expect(h.nav.sourceDir, '专辑');
      expect(find.byTooltip('返回上一级'), findsOneWidget);
      expect(find.textContaining('甲曲二'), findsOneWidget);
      expect(find.text('甲曲'), findsNothing);

      await tester.tap(find.byTooltip('返回上一级'));
      await tester.pumpAndSettle();
      expect(h.nav.sourceDir, '');
      expect(h.nav.browsingSourceKey, h.keyA);
      expect(find.byTooltip('返回播放源'), findsOneWidget);

      await tester.tap(find.byTooltip('返回播放源'));
      await tester.pumpAndSettle();
      expect(h.nav.browsingSourceKey, isNull);
      expect(find.text('从左侧选择播放源浏览'), findsOneWidget);
    });

    testWidgets('反复切源不重复触发自动扫描', (tester) async {
      final h = await _pump(tester);
      addTearDown(() => _dispose(h));

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();
      expect(h.direct.scanCalls, 1);

      await tester.tap(find.text('源乙').first);
      await tester.pumpAndSettle();
      expect(h.direct.scanCalls, 2);

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();
      expect(h.direct.scanCalls, 2, reason: '同一源 60s 内不重复自动扫描');
    });
  });

  group('非分栏形态（内容区不够 / 卡片模式）', () {
    testWidgets('内容区 600：整页替换，进源清空搜索', (tester) async {
      final h = await _pump(tester, contentWidth: 600);
      addTearDown(() => _dispose(h));

      expect(find.text('从左侧选择播放源浏览'), findsNothing);

      h.nav.setSearch('源');
      await tester.pumpAndSettle();
      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();

      expect(h.nav.browsingSourceKey, h.keyA);
      expect(h.nav.search, '', reason: '非分栏沿用进详情清空搜索的旧口径');
      // 整页换成源内浏览：源列表的计数头不再在树上。
      expect(find.text('共 2 个播放源'), findsNothing);
      expect(find.byTooltip('返回播放源'), findsOneWidget);
    });

    testWidgets('卡片模式：即使内容区够宽也不分栏', (tester) async {
      final h = await _pump(tester, viewMode: CollectionViewMode.card);
      addTearDown(() => _dispose(h));

      expect(find.text('从左侧选择播放源浏览'), findsNothing);

      await tester.tap(find.text('源甲').first);
      await tester.pumpAndSettle();
      expect(h.nav.browsingSourceKey, h.keyA);
      expect(find.text('共 2 个播放源'), findsNothing);
      expect(find.byTooltip('返回播放源'), findsOneWidget);
    });
  });
}
