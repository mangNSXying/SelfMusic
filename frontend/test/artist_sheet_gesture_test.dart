import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/services/artist_resolver.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/song_list.dart';
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

/// 关库并删临时目录（Windows 上写隔离退出后句柄释放有延迟，带退避重试）。
Future<void> _dispose(DirectSourceManager direct, Directory dir) async {
  direct.index.close();
  direct.dispose();
  for (var i = 0; i < 20; i++) {
    try {
      if (!dir.existsSync()) return;
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
    }
  }
}

/// 造一个「组合 + 12 位成员 + 24 首歌」的曲库，打开歌手页并点开人员弹层。
///
/// 返回弹层标题的 Finder（用于探位置/拖动），以及清理所需的句柄。
Future<(Directory, DirectSourceManager, Finder)> _pumpArtistSheet(
    WidgetTester tester) async {
  late final Directory dir;
  late final DirectSourceManager direct;

  await tester.runAsync(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_artist_sheet_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
    direct.settings.viewModeArtists = CollectionViewMode.list;
    // 无过渡形态：避免 SectionPager 的 AnimatedSwitcher 用 ColoredBox 包整页，
    // 在测试里触发 ListTile 的 ink 可见性断言（与本次回归无关）。
    direct.settings.playerTransition = PlayerTransition.none;

    // 组合名下 24 首歌 + 一位主角/十二位成员：列表与详情都足够长。
    final index = direct.index;
    await index.upsertSongs([
      for (var i = 0; i < 24; i++)
        DirectSongRow(
          sourceKey: 'local:test',
          ref: 'r$i',
          title: '歌曲 $i',
          artist: '测试组合',
          album: '专辑 ${i ~/ 8}',
          duration: 100,
          format: 'mp3',
          size: 1024,
          mtime: i + 1,
        ),
    ]);
    await index.reconcileArtists();
    final group = index.artistRowByCanonical('测试组合')!;
    await index.artistUpsert(
      artistKey: group.artistKey,
      canonicalKey: group.canonicalKey,
      mbid: 'g-test',
      displayName: '测试组合',
      status: 'resolved',
      errorCount: 0,
      nextAt: 0,
      type: 'group',
    );
    // 主角名带 ASCII 前缀，保证排在成员前、开屏即命中（默认按字符序）。
    await index.artistSetMembers(artistKey: group.artistKey, members: [
      for (var i = 0; i < 13; i++)
        {
          'mbid': 'p$i',
          'name': i == 0 ? 'A测试歌手' : '成员$i',
          'type': 'person',
          'relation': 'member of band',
        },
    ]);
    await index.flushWrites();
  });

  final lib = LibraryProvider()..attachDirectManager(direct);
  lib.artists = direct.index.identityArtistGroups();
  expect(lib.artists.map((a) => a.name), contains('A测试歌手'),
      reason: '造数：人员身份应继承组合的歌曲并出现在歌手列表');
  final resolver = ArtistResolver(direct.index);
  final nav = NavigationProvider()..select(NavSection.artists);

  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  // 模拟状态栏 60：弹层上拉到全高后必须停在它下面。
  tester.view.padding = const FakeViewPadding(top: 60);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
        ChangeNotifierProvider<ArtistResolver>.value(value: resolver),
      ],
      child: const MaterialApp(home: Scaffold(body: SectionPager())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(find.text('A测试歌手'), findsOneWidget);
  await tester.tap(find.text('A测试歌手'));
  await tester.pumpAndSettle();

  final sheetTitle = find.descendant(
    of: find.byType(DraggableScrollableSheet),
    matching: find.text('A测试歌手'),
  );
  expect(sheetTitle, findsOneWidget);
  return (dir, direct, sheetTitle);
}

/// 歌手弹层两个回归（真机反馈）：
/// 1. 弹层上拉到全高时会盖住手机顶部状态栏；
/// 2. 点「详情」展开后窗口无法拖拽/滑动。
///
/// 根因：`showModalBottomSheet` 默认 `useSafeArea=false` 且移除顶部 padding，
/// `DraggableScrollableSheet` 可一路顶到状态栏；且此前只有歌曲列表挂了 sheet 的
/// scrollCtrl——「详情」区在固定 Column 里，展开后把列表挤到 0 高度，整页没有
/// 任何 Scrollable 再能拖动弹层。
void main() {
  testWidgets('歌手弹层：上拉到全高时让开顶部状态栏（回归）', (tester) async {
    final (dir, direct, sheetTitle) = await _pumpArtistSheet(tester);

    // 上拉近全高：标题必须仍位于状态栏（60）下方。
    await tester.drag(find.byType(SongTile).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(sheetTitle).dy, greaterThanOrEqualTo(60.0),
        reason: '弹层上拉到全高时不能盖住状态栏');

    await tester.runAsync(() => _dispose(direct, dir));
  });

  testWidgets('歌手弹层：展开「详情」后仍可拖拽、滑动（回归）', (tester) async {
    final (dir, direct, sheetTitle) = await _pumpArtistSheet(tester);

    // 展开「详情」：内容变长但不挤压列表，仍是同一个可滚动/可拖拽区。
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '详情展开不能把固定头部挤出弹层（旧布局 RenderFlex overflow / 列表被挤没）');

    // 从头部（标题）向下拖：弹层应能被拖小；旧布局头部不在 Scrollable 里，纹丝不动。
    final before = tester.getTopLeft(sheetTitle).dy;
    await tester.drag(sheetTitle, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sheetTitle).dy, greaterThan(before + 100),
        reason: '详情展开后窗口仍要能从头部/任意位置拖拽');

    await tester.runAsync(() => _dispose(direct, dir));
  });
}
