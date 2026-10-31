import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/layout/screen_metrics.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/playlists_view.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/list_detail_split.dart';
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

/// 落库走后台写隔离（真实 isolate 往返）：交替 runAsync 与 pump 推进回调链。
Future<void> _settleWriter(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pumpAndSettle();
}

/// 造一个含两首歌的歌单（与 `playlists_view_test` 同一口径）。
Future<(Directory, int)> _seedPlaylist(DirectSourceManager direct) async {
  final dir = await Directory.systemTemp.createTemp('selfmusic_split_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  await direct.init();
  final plId = await direct.playlists.create('多选歌单');
  await direct.index.upsertSongs([
    DirectSongRow(
        sourceKey: 'local:test',
        ref: 'a',
        title: '夜曲',
        artist: '周杰伦',
        album: '十一月的萧邦',
        duration: 100,
        format: 'mp3',
        size: 1024,
        mtime: 1),
    DirectSongRow(
        sourceKey: 'local:test',
        ref: 'b',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 120,
        format: 'mp3',
        size: 1024,
        mtime: 2),
  ]);
  for (final entry in [(1, 'a', '夜曲'), (2, 'b', '晴天')]) {
    await direct.playlists.addSong(
      plId,
      Song.direct(
        id: entry.$1,
        sourceKey: 'local:test',
        title: entry.$3,
        artist: '周杰伦',
        source: 'local',
        sourceRef: entry.$2,
        fileSize: 1024,
        format: 'mp3',
      ),
    );
  }
  return (dir, plId);
}

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  group('判屏口径', () {
    test('大横屏 = 宽屏 + 内容区够两栏', () {
      const split = ScreenMetrics(
        windowSize: Size(1280, 800),
        contentWidth: 1020,
        child: SizedBox.shrink(),
      );
      expect(split.isWide, isTrue);
      expect(split.isLandscape, isTrue);
      expect(split.isLargeLandscape, isTrue);
      expect(split.supportsSplit, isTrue);
      // 1020 × 0.34 = 346.8，落在 [280, 360] 内。
      expect(split.listPaneWidth, closeTo(346.8, 0.1));

      // 1280 窗口扣掉侧栏 + 队列（1020 − 360 = 660）仍够两栏。
      const withQueue = ScreenMetrics(
        windowSize: Size(1280, 800),
        contentWidth: 660,
        child: SizedBox.shrink(),
      );
      expect(withQueue.supportsSplit, isTrue);

      // 手机横屏（800 − 侧栏 260 = 540）不够两栏：保持整页形态。
      const phone = ScreenMetrics(
        windowSize: Size(800, 360),
        contentWidth: 540,
        child: SizedBox.shrink(),
      );
      expect(phone.isWide, isTrue, reason: '横屏仍算宽屏（侧栏/队列常驻）');
      expect(phone.supportsSplit, isFalse);

      // 竖屏手机：既不是宽屏也不分栏。
      const portrait = ScreenMetrics(
        windowSize: Size(400, 800),
        contentWidth: 400,
        child: SizedBox.shrink(),
      );
      expect(portrait.isWide, isFalse);
      expect(portrait.supportsSplit, isFalse);
    });

    test('左栏宽度钳位', () {
      expect(splitListWidth(400), kSplitListMinWidth);
      expect(splitListWidth(2000), kSplitListMaxWidth);
      expect(splitListWidth(1000), closeTo(340, 0.01));
    });
  });

  group('ListDetailSplit', () {
    testWidgets('未启用时原样返回列表（多一层布局都没有）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ListDetailSplit(
            enabled: false,
            listWidth: 300,
            list: Text('列表'),
            detail: Text('详情'),
          ),
        ),
      ));
      expect(find.text('列表'), findsOneWidget);
      expect(find.text('详情'), findsNothing);
    });

    testWidgets('启用后左右两栏，左栏宽度精确', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            child: ListDetailSplit(
              enabled: true,
              listWidth: 320,
              list: Text('列表'),
              detail: Text('详情'),
            ),
          ),
        ),
      ));
      expect(find.text('列表'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
      final leftBox = tester.widget<SizedBox>(find
          .ancestor(
              of: find.text('列表'), matching: find.byType(SizedBox))
          .first);
      expect(leftBox.width, 320);
    });
  });

  group('DetailPane', () {
    Widget app(Widget? detail, Object? key) => MaterialApp(
          home: Scaffold(
            body: DetailPane(
              detail: detail,
              detailKey: key,
              emptyIcon: Icons.queue_music,
              emptyText: '从左侧选择歌单查看歌曲',
              duration: const Duration(milliseconds: 180),
            ),
          ),
        );

    testWidgets('空态 → 详情 → 换选中项：过渡结束后只留新内容', (tester) async {
      await tester.pumpWidget(app(null, null));
      expect(find.text('从左侧选择歌单查看歌曲'), findsOneWidget);

      await tester.pumpWidget(app(const Text('歌单 A'), 'a'));
      await tester.pumpAndSettle();
      expect(find.text('歌单 A'), findsOneWidget);
      expect(find.text('从左侧选择歌单查看歌曲'), findsNothing);

      await tester.pumpWidget(app(const Text('歌单 B'), 'b'));
      await tester.pumpAndSettle();
      expect(find.text('歌单 B'), findsOneWidget);
      expect(find.text('歌单 A'), findsNothing);
    });
  });

  group('歌单页分栏', () {
    Future<(Directory, DirectSourceManager, NavigationProvider)> pumpPlaylists(
        WidgetTester tester, {required double contentWidth}) async {
      late final Directory dir;
      late final DirectSourceManager direct;
      await tester.runAsync(() async {
        direct = DirectSourceManager();
        dir = (await _seedPlaylist(direct)).$1;
      });
      final provider = PlaylistsProvider(direct.playlists);
      // 判屏/分栏按当前分组判定，这里模拟停在歌单分组。
      final nav = NavigationProvider()..select(NavSection.playlists);
      final player = PlayerProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ScreenMetrics(
                windowSize: const Size(1280, 800),
                contentWidth: contentWidth,
                child: const PlaylistsView(),
              ),
            ),
          ),
        ),
      );
      await _settleWriter(tester);
      return (dir, direct, nav);
    }

    testWidgets('右栏空态 → 点歌单进右栏，左栏与搜索词都保留', (tester) async {
      final (dir, direct, nav) = await pumpPlaylists(tester, contentWidth: 1020);

      expect(find.text('从左侧选择歌单查看歌曲'), findsOneWidget);
      expect(find.text('多选歌单'), findsOneWidget);

      // 先搜索（左栏过滤词）：进入详情不应把它清掉。
      nav.setSearch('夜');
      await tester.pumpAndSettle();
      expect(nav.search, '夜');

      await tester.tap(find.text('多选歌单'));
      await tester.pumpAndSettle();
      expect(nav.browsingPlaylistId, isNotNull);
      expect(nav.search, '夜', reason: '分栏时搜索框就是左栏过滤器');
      // 右栏出现歌单详情（标题同名 + 歌曲），左栏行仍在。
      expect(find.text('多选歌单'), findsNWidgets(2));
      // 标题格式默认「歌手 - 歌名」，且搜索词仍在过滤（2 首里只命中 1 首）。
      expect(find.text('共 1 首歌曲'), findsOneWidget);
      expect(find.textContaining('夜曲'), findsOneWidget);

      await tester.runAsync(() async {
        direct.dispose();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
    });

    testWidgets('内容区不够两栏：保持单栏，进详情清空搜索（旧口径）', (tester) async {
      final (dir, direct, nav) = await pumpPlaylists(tester, contentWidth: 600);

      expect(find.text('从左侧选择歌单查看歌曲'), findsNothing);
      nav.setSearch('夜');
      await tester.pumpAndSettle();

      await tester.tap(find.text('多选歌单'));
      await tester.pumpAndSettle();
      expect(nav.browsingPlaylistId, isNotNull);
      expect(nav.search, '');

      await tester.runAsync(() async {
        direct.dispose();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
    });
  });
}
