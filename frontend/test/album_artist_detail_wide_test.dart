import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/library_screen.dart';
import 'package:selfmusic/services/artist_resolver.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/detail_stack.dart';
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

/// 直连播放源占位：点歌时 `PlayerProvider` 按 sourceKey 解析到它，
/// 实际装载走 `loadOverride`（不触真实音频）。
class _FakeSource extends MusicSource {
  @override
  String get key => 'local:test';
  @override
  String get name => 'test';
  @override
  SourceKind get kind => SourceKind.local;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('file:///dev/null');
}

/// 只验证「先退出详情、再发起重拉」的交互，不触真实 MusicBrainz。
class _FakeResolver extends ArtistResolver {
  _FakeResolver(super._index);

  int forceRetryCalls = 0;

  @override
  Future<void> forceRetryOne({String? artistKey, String? canonicalKey}) async {
    forceRetryCalls++;
  }
}

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

class _Harness {
  _Harness({
    required this.dir,
    required this.direct,
    required this.lib,
    required this.nav,
    required this.player,
    required this.resolver,
  });

  final Directory dir;
  final DirectSourceManager direct;
  final LibraryProvider lib;
  final NavigationProvider nav;
  final PlayerProvider player;
  final _FakeResolver resolver;
}

/// 宽屏（1280×800）装配真实索引 + `AppContent`：歌手页当前分组。
///
/// 曲库：组合「测试组合」24 首歌（3 张专辑）+ 13 位成员（首位「A测试歌手」），
/// 与窄屏弹层回归 `artist_sheet_gesture_test` 同一口径，保证两形态内容可比。
Future<_Harness> _pumpWide(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  PlayerTransition transition = PlayerTransition.none,
}) async {
  late final Directory dir;
  late final DirectSourceManager direct;

  await tester.runAsync(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_detail_wide_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
    direct.settings.viewModeArtists = CollectionViewMode.list;
    direct.settings.playerTransition = transition;

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
  // 专辑页入口（卡片/列表）走 lib.albums/lib.songs；这里用内存快照即可，
  // 歌手页入口走索引身份映射，不需要这两份数据。
  lib.songs = [
    for (var i = 0; i < 24; i++)
      Song(
        id: i,
        sourceKey: 'local:test',
        title: '歌曲 $i',
        artist: '测试组合',
        albumName: '专辑 ${i ~/ 8}',
        source: 'local',
        sourceRef: 'r$i',
        fileSize: 1024,
      ),
  ];
  lib.albums = Album.fromSongs(lib.songs);
  final resolver = _FakeResolver(direct.index);
  final nav = NavigationProvider()..select(NavSection.artists);
  final player = PlayerProvider();
  player.attachSourceResolver((_) => _FakeSource());
  player.loadOverride = (s, src) async {};

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(player.dispose);

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
      child: const MaterialApp(
        home: Scaffold(body: AppContent()),
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
    player: player,
    resolver: resolver,
  );
}

void main() {
  group('宽屏详情页：歌手 → 专辑', () {
    testWidgets('打开歌手整页、嵌套专辑、逐级返回（底层列表保活）', (tester) async {
      final h = await _pumpWide(tester);
      addTearDown(() => _dispose(h.direct, h.dir));

      // 未打开：内容区只有分组列表，没有详情页外壳（懒构建的基线）。
      expect(find.byType(DetailStack), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsNothing);

      await tester.tap(find.text('A测试歌手'));
      await tester.pumpAndSettle();

      // 宽屏 = 内容区整页，不是弹层；页头为返回箭头（无把手/关闭）。
      expect(h.nav.details, hasLength(1));
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('共 24 首歌曲'), findsOneWidget);
      // 与弹层一致：专辑横条 + 详情块 + 右下重新解析都在。
      expect(find.text('专辑 (3)'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
      expect(find.text('重新解析'), findsOneWidget);

      // 点专辑横条 → 叠第二层（只含该歌手的 8 首）。
      await tester.tap(find.text('专辑 0'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(2));
      expect(h.nav.details.last, isA<AlbumDetailRoute>());
      expect(find.text('共 8 首歌曲'), findsOneWidget);
      // 被盖住的歌手页仍在树上（保活），但不在当前可见层。
      expect(find.text('A测试歌手'), findsNothing);
      expect(find.text('共 24 首歌曲', skipOffstage: false), findsOneWidget);

      // 返回：专辑页销毁，歌手页原样回来（不重建、不重新查询）。
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));
      expect(find.text('共 24 首歌曲'), findsOneWidget);
      expect(find.text('共 8 首歌曲'), findsNothing);
      expect(find.text('专辑 0'), findsOneWidget);

      // 再返回：详情栈清空，回到歌手列表。
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(h.nav.details, isEmpty);
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.text('A测试歌手'), findsOneWidget);
    });

    testWidgets('打开详情后滚动位置保持（底层分组页常驻）', (tester) async {
      final h = await _pumpWide(tester);
      addTearDown(() => _dispose(h.direct, h.dir));

      // 列表上滑一段，记下某行的屏幕位置。
      await tester.drag(find.text('A测试歌手'), const Offset(0, -160));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('成员3')).dy;

      await tester.tap(find.text('成员3'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      // 底层列表没有因详情进出而重建：滚动位置逐像素保持。
      expect(tester.getTopLeft(find.text('成员3')).dy, before);
    });

    testWidgets('整页里点歌不关详情：进播放页后返回仍在原页', (tester) async {
      final h = await _pumpWide(tester);
      addTearDown(() => _dispose(h.direct, h.dir));

      await tester.tap(find.text('A测试歌手'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));

      await tester.tap(find.byType(SongTile).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(h.nav.playerView, isTrue);
      // 页面没有被 pop（窄屏弹层才会先关窗）。
      expect(h.nav.details, hasLength(1));
      expect(find.byTooltip('返回'), findsOneWidget);
    });

    testWidgets('专辑列表入口：宽屏点专辑也走内容区整页', (tester) async {
      final h = await _pumpWide(tester);
      addTearDown(() => _dispose(h.direct, h.dir));

      h.nav.select(NavSection.albums);
      await tester.pumpAndSettle();
      expect(find.text('专辑 0'), findsWidgets);

      await tester.tap(find.text('专辑 0').first);
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));
      expect(h.nav.details.single, isA<AlbumDetailRoute>());
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.text('共 8 首歌曲'), findsOneWidget);
    });

    testWidgets('整页「重新解析」：确认后先退出详情、再发起重拉', (tester) async {
      final h = await _pumpWide(tester);
      addTearDown(() => _dispose(h.direct, h.dir));

      await tester.tap(find.text('A测试歌手'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));

      // 取消：留在原页，不重拉。
      await tester.tap(find.text('重新解析'));
      await tester.pumpAndSettle();
      expect(find.text('重新解析「A测试歌手」？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.nav.details, hasLength(1));
      expect(h.resolver.forceRetryCalls, 0);

      // 确认：先退详情（快照作废），再重拉；底层列表可直接看进度。
      await tester.tap(find.text('重新解析'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();
      expect(h.resolver.forceRetryCalls, 1);
      expect(h.nav.details, isEmpty);
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.text('A测试歌手'), findsOneWidget);
    });

    testWidgets('滑动过渡档：进出详情页无异常、动画结束后只留顶层', (tester) async {
      final h = await _pumpWide(tester, transition: PlayerTransition.slide);
      addTearDown(() => _dispose(h.direct, h.dir));

      await tester.tap(find.text('A测试歌手'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      // 动画中：页头随整页从右侧滑入，未就位。
      final flyingX = tester.getTopLeft(find.byTooltip('返回')).dx;
      expect(flyingX, greaterThan(100));
      await tester.pumpAndSettle();
      final settledX = tester.getTopLeft(find.byTooltip('返回')).dx;
      expect(settledX, lessThan(100));
      expect(flyingX, greaterThan(settledX));

      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      // 退场中：页面仍在树上并向右滑出。
      expect(tester.getTopLeft(find.byTooltip('返回')).dx, greaterThan(settledX));
      await tester.pumpAndSettle();
      expect(h.nav.details, isEmpty);
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.text('A测试歌手'), findsOneWidget);
    });
  });

  group('导航详情栈', () {
    Album album(int id) => Album(
          id: id,
          artist: '测试组合',
          album: '专辑 $id',
          groupKey: 'album\x00专辑 $id',
          trackCount: 1,
          totalDuration: 100,
        );
    const artist = Artist(name: 'A测试歌手', songCount: 24, albumCount: 3);

    test('进退/嵌套/最多两层/离开分组清空', () {
      final nav = NavigationProvider();
      final rev = nav.detailRevision;

      nav.enterArtist(artist, const []);
      expect(nav.details.single, isA<ArtistDetailRoute>());
      expect(nav.detailRevision, rev + 1);

      nav.enterAlbum(album(1), const []);
      expect(nav.details, hasLength(2));
      expect(nav.details.last, isA<AlbumDetailRoute>());

      // 最多两层：进第三层时丢掉最底层，保留最近的详情。
      nav.enterAlbum(album(2), const []);
      expect(nav.details, hasLength(2));
      expect((nav.details.last as AlbumDetailRoute).album.album, '专辑 2');

      expect(nav.backToPrevious(), isTrue);
      expect(nav.details, hasLength(1));
      expect(nav.details.single, isA<AlbumDetailRoute>());

      // 切分组 / 设置页 / 歌单 / 源内：详情栈一律清空。
      nav.select(NavSection.songs);
      expect(nav.details, isEmpty);

      nav.enterArtist(artist, const []);
      nav.openSettings(SettingsItem.general);
      expect(nav.details, isEmpty);

      nav.enterAlbum(album(3), const []);
      nav.enterPlaylist(1);
      expect(nav.details, isEmpty);

      nav.enterArtist(artist, const []);
      nav.enterSource('s');
      expect(nav.details, isEmpty);
    });
  });
}
