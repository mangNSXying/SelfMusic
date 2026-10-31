import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/utils/collection_sort.dart';
import 'package:selfmusic/utils/song_groups.dart';
import 'package:selfmusic/widgets/draggable_sheet.dart';
import 'package:selfmusic/widgets/song_collection_view.dart';
import 'package:selfmusic/widgets/song_table.dart';
import 'package:selfmusic/widgets/song_table_sliver.dart';
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

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:t';
  @override
  String get name => 'NAS';
  @override
  SourceKind get kind => SourceKind.webdav;
}

Song _song({
  int id = 1,
  String title = '晴天',
  String? artist = '周杰伦',
  String? album = '叶惠美',
  String sourceRef = '/dav/a.flac',
}) =>
    Song(
      id: id,
      sourceKey: 'webdav:t',
      title: title,
      artist: artist,
      albumName: album,
      duration: 240,
      source: 'webdav',
      sourceRef: sourceRef,
      fileSize: 25 * 1024 * 1024,
      format: 'flac',
    );

void main() {
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    dir = await Directory.systemTemp.createTemp('selfmusic_table_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
  });

  tearDown(() async {
    direct.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> pumpCollection(
    WidgetTester tester, {
    required double width,
    required List<Song> songs,
    SongGroupMode mode = SongGroupMode.none,
    FolderNavigation navigation = FolderNavigation.flat,
    List<String>? folderPaths,
  }) async {
    tester.view.physicalSize = ui.Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongCollectionView(
              songs: songs,
              searching: false,
              collectionKey: 'table-test',
              groupMode: mode,
              onGroupModeChanged: (_) {},
              sort: direct.settings.sortSongs,
              onSortChanged: (_) {},
              folderNavigation: navigation,
              folderPaths: folderPaths,
              dir: '',
              onDirChanged: (_) {},
              onPlay: (_, __) {},
              onPlayGroup: (_) {},
              sourceOf: (_) => _FakeSource(),
              selectionActions: (_, __) => const [],
              emptyText: '空',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('宽列表：九列表头与行内单元格对齐', (tester) async {
    await pumpCollection(tester, width: 1200, songs: [_song()]);

    for (final label in [
      '标题',
      '歌手',
      '专辑',
      '播放源',
      '格式',
      '码率',
      '大小',
      '赞踩',
      '时长'
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('NAS'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('853 kbps'), findsOneWidget);
    expect(find.text('25.0 MB'), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
    // 表格行不再显示「歌手 · 专辑」副标题。
    expect(find.text('周杰伦 · 叶惠美'), findsNothing);

    // 文本列与表头左边界一致；数字列右边界一致。
    expect(tester.getTopLeft(find.text('周杰伦')).dx,
        closeTo(tester.getTopLeft(find.text('歌手')).dx, 0.5));
    expect(tester.getTopLeft(find.text('叶惠美')).dx,
        closeTo(tester.getTopLeft(find.text('专辑')).dx, 0.5));
    expect(tester.getTopRight(find.text('04:00')).dx,
        closeTo(tester.getTopRight(find.text('时长')).dx, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('阈值 800：九列全显且不溢出', (tester) async {
    await pumpCollection(tester, width: 800, songs: [_song()]);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('播放源'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄列表：不插入表头，保持副标题行', (tester) async {
    await pumpCollection(tester, width: 700, songs: [_song()]);
    expect(find.text('标题'), findsNothing);
    expect(find.text('播放源'), findsNothing);
    expect(find.text('853 kbps'), findsNothing);
    expect(find.text('周杰伦 · 叶惠美'), findsOneWidget);
  });

  testWidgets('多选态保留表头，菜单列占位不挤动列宽', (tester) async {
    await pumpCollection(tester, width: 1000, songs: [_song()]);
    final headerArtistX = tester.getTopLeft(find.text('歌手')).dx;
    final rowArtistX = tester.getTopLeft(find.text('周杰伦')).dx;

    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(tester.getTopLeft(find.text('歌手')).dx, headerArtistX);
    expect(tester.getTopLeft(find.text('周杰伦')).dx, rowArtistX);
    expect(tester.takeException(), isNull);
  });

  testWidgets('源页文件夹树：歌曲缩进不移动表格列', (tester) async {
    const refs = ['A/b/c/深处的歌.mp3'];
    await pumpCollection(
      tester,
      width: 1200,
      songs: [_song(title: '深处的歌', sourceRef: refs[0])],
      mode: SongGroupMode.folder,
      navigation: FolderNavigation.recursive,
      folderPaths: refs,
    );

    await tester.tap(find.byTooltip('全部展开'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('深处的歌'), findsOneWidget);

    // 标题格按层级缩进（仍可辨认层级），但歌手/专辑等列不随缩进右移。
    expect(tester.getTopLeft(find.text('深处的歌')).dx,
        greaterThan(tester.getTopLeft(find.text('标题')).dx));
    expect(tester.getTopLeft(find.text('周杰伦')).dx,
        closeTo(tester.getTopLeft(find.text('歌手')).dx, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver 表格：表头随滚动固定', (tester) async {
    final songs = [
      for (var i = 0; i < 20; i++)
        _song(id: i + 1, title: '歌$i', sourceRef: '/dav/$i.flac'),
    ];
    tester.view.physicalSize = const ui.Size(1200, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SongTableSliverList(
                  songs: songs,
                  table: SongTableLayout.fit(1200),
                  sourceOf: (_) => _FakeSource(),
                  onPlay: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('标题'), findsOneWidget);
    expect(find.text('歌0'), findsOneWidget);
    final before = tester.getTopLeft(find.text('标题')).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(find.text('标题'), findsOneWidget);
    expect(tester.getTopLeft(find.text('标题')).dy, closeTo(before, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver 表格：已有 pinned 页头时表头叠加在其下方', (tester) async {
    final songs = [
      for (var i = 0; i < 20; i++)
        _song(id: i + 1, title: '歌$i', sourceRef: '/dav/$i.flac'),
    ];
    tester.view.physicalSize = const ui.Size(1200, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                const AppSheetHeader(
                  height: 56,
                  child: SizedBox.expand(),
                ),
                SongTableSliverList(
                  songs: songs,
                  table: SongTableLayout.fit(1200),
                  sourceOf: (_) => _FakeSource(),
                  onPlay: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('标题'), findsOneWidget);
    // 页头钉在 0~56，表格表头容器在它下方（文本在表头内垂直居中）。
    final header = find.byType(SongTableHeader);
    expect(tester.getTopLeft(header).dy, closeTo(56, 0.5));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(56, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('表头点击排序：升 → 降 → 默认，底色与页面一致', (tester) async {
    tester.view.physicalSize = const ui.Size(1200, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var sort = CollectionSort.defaultOrder;
    final picked = <CollectionSort>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SongTableHeader(
              layout: SongTableLayout.fit(1200)!,
              sort: sort,
              onSort: (v) {
                picked.add(v);
                setState(() => sort = v);
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('歌手'), findsOneWidget);
    await tester.tap(find.text('歌手'));
    await tester.pump();
    expect(picked.last, CollectionSort.artistAsc);
    expect(find.text('歌手 ↑'), findsOneWidget);

    await tester.tap(find.text('歌手 ↑'));
    await tester.pump();
    expect(picked.last, CollectionSort.artistDesc);
    expect(find.text('歌手 ↓'), findsOneWidget);

    await tester.tap(find.text('歌手 ↓'));
    await tester.pump();
    expect(picked.last, CollectionSort.defaultOrder);
    expect(find.text('歌手'), findsOneWidget);

    // 表头不再额外压一条 surfaceContainerLow 色带，与页面/计数头同底色。
    final box = tester.widget<Container>(
      find.ancestor(of: find.text('标题'), matching: find.byType(Container)).first,
    );
    expect((box.decoration! as BoxDecoration).color,
        Theme.of(tester.element(find.text('标题'))).scaffoldBackgroundColor);
  });
}
