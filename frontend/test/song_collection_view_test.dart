import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/utils/song_groups.dart';
import 'package:selfmusic/widgets/song_collection_view.dart';
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

Song _song(int id, String ref, {String? title, String? album}) => Song.direct(
      id: id,
      sourceKey: 'local:test',
      title: title ?? '歌$id',
      albumName: album,
      source: 'local',
      sourceRef: ref,
      fileSize: 1,
    );

void main() {
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    dir = await Directory.systemTemp.createTemp('selfmusic_collection_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
  });

  tearDown(() async {
    direct.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> pumpView(
    WidgetTester tester, {
    required List<Song> songs,
    required SongGroupMode mode,
    required bool searching,
    required ValueChanged<SongGroupMode> onMode,
    String collectionKey = 'test',
    FolderNavigation navigation = FolderNavigation.flat,
    List<String>? folderPaths,
    Set<String> extraFolders = const {},
    String dir = '',
    ValueChanged<String>? onDir,
    void Function(List<Song>)? onPlayGroup,
    void Function(List<Song>, int)? onPlay,
    String? folderLabel,
  }) async {
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
              searching: searching,
              collectionKey: collectionKey,
              groupMode: mode,
              onGroupModeChanged: onMode,
              sort: direct.settings.sortSongs,
              onSortChanged: (_) {},
              folderNavigation: navigation,
              folderPaths: folderPaths,
              extraFolders: extraFolders,
              dir: dir,
              onDirChanged: onDir,
              onPlay: onPlay ?? (_, __) {},
              onPlayGroup: onPlayGroup ?? (_) {},
              folderLabel: folderLabel,
              selectionActions: (_, __) => const [],
              emptyText: '空',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('文件夹平铺分组：组头、折叠与持久化', (tester) async {
    final songs = [
      _song(1, '文件夹A/one.mp3', title: '晴天'),
      _song(2, '文件夹B/two.mp3', title: '夜曲'),
      _song(3, '文件夹A/three.mp3', title: '稻香'),
    ];
    var mode = SongGroupMode.folder;
    await pumpView(
      tester,
      songs: songs,
      mode: mode,
      searching: false,
      onMode: (v) => mode = v,
    );

    expect(find.text('文件夹A'), findsOneWidget);
    expect(find.text('文件夹B'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('夜曲'), findsOneWidget);

    // 点组头折叠：组内歌曲隐藏，折叠组名持久化。
    await tester.tap(find.text('文件夹A'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('晴天'), findsNothing);
    expect(find.text('稻香'), findsNothing);
    expect(find.text('夜曲'), findsOneWidget);
    expect(direct.settings.groupCollapsed('test'), contains('文件夹A'));

    // 默认 A（设置关闭）：长按组头进入多选并选中整组；折叠组内的歌照样
    // 计入选择，选择本身不改变折叠状态。
    await tester.longPress(find.text('文件夹B'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);
    expect(find.text('夜曲'), findsOneWidget);
    expect(find.byTooltip('播放该分组'), findsNothing);

    // 多选态点击已折叠组头：递归选中组内全部歌曲（晴天 + 稻香）。
    await tester.tap(find.text('文件夹A'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 3'), findsOneWidget);
    expect(find.text('已选 2 / 2 首'), findsOneWidget);
    expect(find.text('晴天'), findsNothing); // 折叠只管展示

    // 再点一次取消整组。
    await tester.tap(find.text('文件夹A'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);

    // A 模式的长按已让位给多选，全部展开/折叠是计数栏工具条图标。
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byTooltip('多选'), findsOneWidget);
    await tester.tap(find.byTooltip('全部折叠'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('夜曲'), findsNothing);
    expect(direct.settings.groupCollapsed('test'),
        containsAll({'文件夹A', '文件夹B'}));

    // 分类菜单只剩分类方式，展开/折叠/多选已移出。
    await tester.tap(find.byTooltip('分类方式：文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('全部折叠'), findsNothing);
    expect(find.text('全部展开'), findsNothing);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('全部展开'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('夜曲'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(direct.settings.groupCollapsed('test'), isEmpty);
  });

  testWidgets('B 模式：长按组头折叠全部，多选从工具条进入', (tester) async {
    direct.settings.longPressCollapseGroups = true;
    final songs = [
      _song(1, '文件夹A/one.mp3', title: '晴天'),
      _song(2, '文件夹B/two.mp3', title: '夜曲'),
      _song(3, '文件夹A/three.mp3', title: '稻香'),
    ];
    await pumpView(
      tester,
      songs: songs,
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
    );

    // 长按组头 = 全部折叠，不进入多选。
    await tester.longPress(find.text('文件夹B'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsNothing);
    expect(find.text('夜曲'), findsNothing);
    expect(find.text('晴天'), findsNothing);
    expect(direct.settings.groupCollapsed('test'),
        containsAll({'文件夹A', '文件夹B'}));

    // 工具条多选图标进入：初始 0，选中整组不受折叠影响。
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 0'), findsOneWidget);

    await tester.tap(find.text('文件夹A'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);
    expect(find.text('已选 2 / 2 首'), findsOneWidget);

    // 多选态右侧箭头仍只负责展开/折叠，不改变选择。
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, '文件夹A'),
      matching: find.byTooltip('展开分组'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('稻香'), findsOneWidget);
    expect(find.text('已选 2'), findsOneWidget);
  });

  testWidgets('逐级文件夹：空文件夹显示、进入目录、文件夹递归播放', (tester) async {
    final songs = [
      _song(1, 'root.mp3', title: '根目录歌'),
      _song(2, 'FolderA/one.mp3', title: 'A一'),
      _song(3, 'FolderA/deep/two.mp3', title: 'A二'),
      _song(4, 'FolderB/three.mp3', title: 'B三'),
    ];
    final paths = [
      'root.mp3',
      'FolderA/one.mp3',
      'FolderA/deep/two.mp3',
      'FolderB/three.mp3'
    ];
    List<Song>? played;
    var currentDir = '';
    late StateSetter setOuter;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(builder: (c, setState) {
              setOuter = setState;
              return SongCollectionView(
                songs: songs,
                searching: false,
                collectionKey: 'source:test',
                groupMode: SongGroupMode.folder,
                onGroupModeChanged: (_) {},
                sort: direct.settings.sortSongs,
                onSortChanged: (_) {},
                folderNavigation: FolderNavigation.recursive,
                folderPaths: paths,
                extraFolders: const {'FolderC', 'FolderA/空子目录'},
                dir: currentDir,
                onDirChanged: (d) => setOuter(() => currentDir = d),
                onPlay: (_, __) {},
                onPlayGroup: (l) => played = l,
                selectionActions: (_, __) => const [],
                emptyText: '空',
              );
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 源根：三个文件夹（含新建的空文件夹）+ 根目录歌曲。
    expect(find.text('FolderA'), findsOneWidget);
    expect(find.text('FolderB'), findsOneWidget);
    expect(find.text('FolderC'), findsOneWidget);
    expect(find.text('0 首'), findsOneWidget); // 空文件夹
    expect(find.text('根目录歌'), findsOneWidget);
    expect(find.text('A一'), findsNothing);

    // 文件夹递归播放：A 下两首（含 deep）。
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byIcon(Icons.play_arrow),
    ));
    await tester.pump(const Duration(milliseconds: 20));
    expect(played?.map((s) => s.title), ['A一', 'A二']);

    // 进入 A：显示本层歌曲 + 深子目录，根目录歌曲消失。
    await tester.tap(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(currentDir, 'FolderA');
    expect(find.text('A一'), findsOneWidget);
    expect(find.text('deep'), findsOneWidget);
    expect(find.text('空子目录'), findsOneWidget);
    expect(find.text('根目录歌'), findsNothing);

    // 进入 deep：只剩深层歌曲。
    await tester.tap(find.text('deep'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(currentDir, 'FolderA/deep');
    expect(find.text('A二'), findsOneWidget);

    setOuter(() => currentDir = '');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('根目录歌'), findsOneWidget);

    // 进入新建的空文件夹：面包屑由页面负责，组件内显示空态。
    await tester.tap(find.text('FolderC'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(currentDir, 'FolderC');
    expect(find.text('空'), findsOneWidget);
  });

  testWidgets('逐级文件夹多选：递归选中子树、跨目录保留、三态勾选', (tester) async {
    final songs = [
      _song(1, 'root.mp3', title: '根目录歌'),
      _song(2, 'FolderA/one.mp3', title: 'A一'),
      _song(3, 'FolderA/deep/two.mp3', title: 'A二'),
      _song(4, 'FolderB/three.mp3', title: 'B三'),
    ];
    final paths = [
      'root.mp3',
      'FolderA/one.mp3',
      'FolderA/deep/two.mp3',
      'FolderB/three.mp3',
    ];
    var currentDir = '';
    List<Song>? actionSelected;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(builder: (c, setState) {
              setOuter = setState;
              return SongCollectionView(
                songs: songs,
                searching: false,
                collectionKey: 'source:test',
                groupMode: SongGroupMode.folder,
                onGroupModeChanged: (_) {},
                sort: direct.settings.sortSongs,
                onSortChanged: (_) {},
                folderNavigation: FolderNavigation.recursive,
                folderPaths: paths,
                extraFolders: const {'FolderC'},
                dir: currentDir,
                onDirChanged: (d) => setOuter(() => currentDir = d),
                onPlay: (_, __) {},
                onPlayGroup: (_) {},
                selectionActions: (selected, clear) {
                  actionSelected = selected;
                  return const [];
                },
                emptyText: '空',
              );
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 长按文件夹行 = 进入多选并递归选中整个子树（含 deep 层）。
    await tester.longPress(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);
    expect(find.text('已选 2 / 2 首'), findsOneWidget);
    expect(currentDir, ''); // 长按选择不进入文件夹
    // 批量操作拿到的是全集合里的递归选中结果，而不是本层展示列表。
    expect(actionSelected?.map((s) => s.title), ['A一', 'A二']);

    // 全选只作用于当前展示层（根目录歌曲），不把其余文件夹也算进去。
    await tester.tap(find.byTooltip('全选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 3'), findsOneWidget);
    expect(find.byTooltip('全不选'), findsOneWidget);

    // 全不选清空整个选择集（含其他目录里已选的歌），仍停留在多选态。
    await tester.tap(find.byTooltip('全不选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 0'), findsOneWidget);

    // 多选态点击整行 = 切选择，右侧箭头才进入目录。
    await tester.tap(find.text('FolderB'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);
    expect(currentDir, '');
    expect(actionSelected?.map((s) => s.title), ['B三']);
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byTooltip('进入文件夹'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(currentDir, 'FolderA');
    expect(find.text('已选 1'), findsOneWidget); // 跨目录保留选择

    // A一 未选，点选后返回根目录看 FolderA 半选。
    expect(find.text('A一'), findsOneWidget);
    await tester.tap(find.text('A一'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);

    setOuter(() => currentDir = '');
    await tester.pump(const Duration(milliseconds: 50));
    final partial = tester.widget<Checkbox>(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byType(Checkbox),
    ));
    expect(partial.tristate, isTrue);
    expect(partial.value, isNull);

    // 空文件夹不可选：没有勾选框，长按也不改变计数。
    expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'FolderC'),
          matching: find.byType(Checkbox),
        ),
        findsNothing);
    await tester.longPress(find.text('FolderC'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);

    // 点击半选文件夹 → 补齐整组；再点 → 取消整组。
    await tester.tap(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 3'), findsOneWidget);
    final full = tester.widget<Checkbox>(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byType(Checkbox),
    ));
    expect(full.tristate, isFalse);
    expect(full.value, isTrue);

    await tester.tap(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget); // 只剩 B三
  });

  testWidgets('搜索过滤不丢选择；全选只作用于命中项', (tester) async {
    final all = [
      _song(1, 'a.mp3', title: '晴天'),
      _song(2, 'b.mp3', title: '夜曲'),
    ];
    final filtered = [all[1]];
    var searching = false;
    var songs = all;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(builder: (c, setState) {
              setOuter = setState;
              return SongCollectionView(
                songs: songs,
                searching: searching,
                collectionKey: 'test',
                groupMode: SongGroupMode.none,
                onGroupModeChanged: (_) {},
                sort: direct.settings.sortSongs,
                onSortChanged: (_) {},
                onPlay: (_, __) {},
                onPlayGroup: (_) {},
                selectionActions: (_, __) => const [],
                emptyText: '空',
              );
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.text('晴天'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);

    setOuter(() {
      searching = true;
      songs = filtered;
    });
    await tester.pump(const Duration(milliseconds: 50));
    // 选中项被搜索过滤掉，但多选态与选择集保留（计数按当前范围显示 0）。
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.byTooltip('全选'), findsOneWidget);

    await tester.tap(find.byTooltip('全选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);

    setOuter(() {
      searching = false;
      songs = all;
    });
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);

    // 取消选择恢复计数栏。
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsNothing);
    expect(find.text('共 2 首歌曲'), findsOneWidget);
  });

  testWidgets('专辑分类：按专辑名分组，未知专辑兜底', (tester) async {
    final songs = [
      _song(1, 'a.mp3', title: '晴天', album: '叶惠美'),
      _song(2, 'b.mp3', title: '夜曲'),
      _song(3, 'c.mp3', title: '稻香', album: '魔杰座'),
    ];
    await pumpView(
      tester,
      songs: songs,
      mode: SongGroupMode.album,
      searching: false,
      onMode: (_) {},
    );
    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('魔杰座'), findsOneWidget);
    expect(find.text(kUnknownAlbumGroupName), findsOneWidget);
  });

  testWidgets('源页风格：文件夹（逐级）标签', (tester) async {
    await pumpView(
      tester,
      songs: [_song(1, 'a/x.mp3')],
      mode: SongGroupMode.none,
      searching: false,
      onMode: (_) {},
      folderLabel: '文件夹（逐级）',
    );
    await tester.tap(find.byIcon(Icons.category_outlined));
    await tester.pumpAndSettle();
    expect(find.text('无'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('文件夹（逐级）'), findsOneWidget);
  });

  testWidgets('源页树形展开：箭头展开/折叠与全部展开/折叠', (tester) async {
    final songs = [
      _song(1, 'FolderA/one.mp3', title: 'A一'),
      _song(2, 'FolderA/deep/two.mp3', title: 'A二'),
      _song(3, 'FolderB/three.mp3', title: 'B三'),
      _song(4, 'root.mp3', title: '根目录歌'),
    ];
    final paths = [
      'FolderA/one.mp3',
      'FolderA/deep/two.mp3',
      'FolderB/three.mp3',
      'root.mp3',
    ];
    await pumpView(
      tester,
      songs: songs,
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
      navigation: FolderNavigation.recursive,
      folderPaths: paths,
      extraFolders: const {'FolderC', 'FolderA/空子目录'},
    );

    // 默认全折叠：只有当前层文件夹与本层歌曲。
    expect(find.text('FolderA'), findsOneWidget);
    expect(find.text('FolderC'), findsOneWidget);
    expect(find.text('A一'), findsNothing);
    expect(find.text('A二'), findsNothing);
    expect(find.byTooltip('全部展开'), findsOneWidget);

    // 展开 FolderA：出现直属歌曲与子文件夹；空文件夹没有展开箭头。
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byTooltip('展开文件夹'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A一'), findsOneWidget);
    expect(find.text('deep'), findsOneWidget);
    expect(find.text('空子目录'), findsOneWidget);
    expect(find.text('A二'), findsNothing);
    expect(direct.settings.folderExpanded('test'), contains('FolderA'));
    expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'FolderC'),
          matching: find.byTooltip('展开文件夹'),
        ),
        findsNothing);

    // 折叠恢复。
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byTooltip('折叠文件夹'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A一'), findsNothing);
    expect(direct.settings.folderExpanded('test'), isNot(contains('FolderA')));

    // 工具条全部展开：深层歌曲可见；全部折叠恢复。
    await tester.tap(find.byTooltip('全部展开'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A二'), findsOneWidget);
    expect(find.text('B三'), findsOneWidget);
    await tester.tap(find.byTooltip('全部折叠'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A一'), findsNothing);
    expect(find.text('B三'), findsNothing);
    expect(find.text('根目录歌'), findsOneWidget);
  });

  testWidgets('源页 B 模式：长按文件夹行切换展开，不进入多选', (tester) async {
    direct.settings.longPressCollapseGroups = true;
    final songs = [
      _song(1, 'FolderA/one.mp3', title: 'A一'),
      _song(2, 'FolderA/deep/two.mp3', title: 'A二'),
      _song(3, 'root.mp3', title: '根目录歌'),
    ];
    final paths = [
      'FolderA/one.mp3',
      'FolderA/deep/two.mp3',
      'root.mp3',
    ];
    await pumpView(
      tester,
      songs: songs,
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
      navigation: FolderNavigation.recursive,
      folderPaths: paths,
    );

    expect(find.text('A一'), findsNothing);
    await tester.longPress(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A一'), findsOneWidget);
    expect(find.byTooltip('取消选择'), findsNothing);

    await tester.longPress(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A一'), findsNothing);

    // 工具条仍可进入多选。
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 0'), findsOneWidget);
  });

  testWidgets('源页树形多选：嵌套文件夹三态勾选按子树计数', (tester) async {
    final songs = [
      _song(1, 'FolderA/one.mp3', title: 'A一'),
      _song(2, 'FolderA/deep/two.mp3', title: 'A二'),
      _song(3, 'FolderB/three.mp3', title: 'B三'),
    ];
    final paths = [
      'FolderA/one.mp3',
      'FolderA/deep/two.mp3',
      'FolderB/three.mp3',
    ];
    await pumpView(
      tester,
      songs: songs,
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
      navigation: FolderNavigation.recursive,
      folderPaths: paths,
    );

    // 展开到 deep 层后进入多选。
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byTooltip('展开文件夹'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'deep'),
      matching: find.byTooltip('展开文件夹'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('A二'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);

    // 祖先 FolderA 半选（1/2），deep 全选（1/1）。
    final folderA = tester.widget<Checkbox>(find.descendant(
      of: find.widgetWithText(ListTile, 'FolderA'),
      matching: find.byType(Checkbox),
    ));
    expect(folderA.tristate, isTrue);
    expect(folderA.value, isNull);
    final deep = tester.widget<Checkbox>(find.descendant(
      of: find.widgetWithText(ListTile, 'deep'),
      matching: find.byType(Checkbox),
    ));
    expect(deep.value, isTrue);

    // 多选态点 FolderA 行补齐整组。
    await tester.tap(find.text('FolderA'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);
  });

  testWidgets('源页树形：窄屏深层缩进与行内三动作不溢出', (tester) async {
    tester.view.physicalSize = const ui.Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const refs = ['A/b/c/d/e.mp3', 'A/b/c/f.mp3'];
    await pumpView(
      tester,
      songs: [
        _song(1, refs[0], title: '尾巴'),
        _song(2, refs[1], title: '兄弟'),
      ],
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
      navigation: FolderNavigation.recursive,
      folderPaths: refs,
    );

    await tester.tap(find.byTooltip('全部展开'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('尾巴'), findsOneWidget);
    expect(find.text('兄弟'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具条图标：多选/展开/折叠与多选态全选/全不选（窄屏不溢出）',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpView(
      tester,
      songs: [
        _song(1, '文件夹A/one.mp3', title: '晴天'),
        _song(2, '文件夹B/two.mp3', title: '夜曲'),
      ],
      mode: SongGroupMode.folder,
      searching: false,
      onMode: (_) {},
    );

    expect(find.byTooltip('多选'), findsOneWidget);
    expect(find.byTooltip('全部展开'), findsOneWidget);
    expect(find.byTooltip('全部折叠'), findsOneWidget);
    // 全展开时「全部展开」禁用、「全部折叠」可用。
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.unfold_more))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.unfold_less))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);

    // 多选态：工具条换成全选/全不选图标。
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('全不选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
