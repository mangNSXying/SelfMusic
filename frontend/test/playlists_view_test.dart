import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/playlists_view.dart';
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


/// 落库走后台写隔离（真实 isolate 往返）：`pump` 不推进真实消息，
/// 需交替 runAsync（真实事件循环）与 pump（推进回调链）。
Future<void> settleWriter(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pumpAndSettle();
}

/// 造一个含两首歌（夜曲/晴天）的歌单并返回临时目录与歌单 id。
///
/// 关键前提：两首歌都灌进本地索引，使歌单详情的 `songByRef` 能解析出实时行
/// （`id` 为真实 rowid）；而歌单条目行是快照（`id` 恒 0）——两套 `songKey`
/// 不同源，正是「已选」计数恒 0 / 搜索后全选变整单的根因前提。
Future<(Directory, int)> _seedIndexedPlaylist(
    DirectSourceManager direct, String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
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
  await direct.playlists.addSong(plId, Song.direct(
    id: 1,
    sourceKey: 'local:test',
    title: '夜曲',
    artist: '周杰伦',
    source: 'local',
    sourceRef: 'a',
    fileSize: 1024,
    format: 'mp3',
  ));
  await direct.playlists.addSong(plId, Song.direct(
    id: 2,
    sourceKey: 'local:test',
    title: '晴天',
    artist: '周杰伦',
    source: 'local',
    sourceRef: 'b',
    fileSize: 1024,
    format: 'mp3',
  ));
  return (dir, plId);
}

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  testWidgets('新建歌单后立即显示（无需重启）', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plw_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.playlists.create('已有歌单');
    });

    final provider = PlaylistsProvider(direct.playlists);
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaylistsView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已有歌单'), findsOneWidget);
    expect(find.text('新建歌单'), findsNothing);

    // 右下角「+」新建
    await tester.tap(find.byTooltip('新建歌单'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), '新建歌单');
    await tester.tap(find.text('创建'));
    await settleWriter(tester);

    // 无需重启，新歌单立即可见
    expect(find.text('新建歌单'), findsOneWidget);
    expect(provider.playlists.length, 2);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('长按歌单进入多选，可全选 / 取消选择', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plw_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.playlists.create('现有歌单');
      await direct.playlists.create('另一个歌单');
    });

    final provider = PlaylistsProvider(direct.playlists);
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaylistsView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 长按进入选择模式并选中当前项
    await tester.longPress(find.text('现有歌单'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('已选 1'), findsOneWidget);
    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('全不选'), findsOneWidget);
    // 批量操作已收进右侧三点菜单。
    expect(find.byTooltip('更多操作'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除选中'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    // 点击另一项累计选中 → 全部选中后「全选」禁用、「全不选」可用。
    await tester.tap(find.text('另一个歌单'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.select_all))
            .onPressed,
        isNull);

    // 全不选清空勾选
    await tester.tap(find.byTooltip('全不选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.byTooltip('全选'), findsOneWidget);

    // 全选勾满
    await tester.tap(find.byTooltip('全选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);

    // 取消选择退出多选
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('右键歌单行：在指针处弹出重命名/删除菜单；多选态不响应', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plrc_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.playlists.create('右键歌单');
    });

    final provider = PlaylistsProvider(direct.playlists);
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaylistsView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final row = tester.getCenter(find.text('右键歌单'));
    await tester.tapAt(row,
        buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    // 空白处点击关闭菜单。
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsNothing);

    // 多选态：右键不弹菜单（与隐藏三点按钮一致）。
    await tester.longPress(find.text('右键歌单'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tapAt(row,
        buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('右键歌单卡片：在指针处弹出同款菜单（SquareCard 通道）',
      (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plrcard_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.playlists.create('卡片歌单');
      direct.settings.viewModePlaylists = CollectionViewMode.card;
    });

    final provider = PlaylistsProvider(direct.playlists);
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaylistsView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tapAt(tester.getCenter(find.text('卡片歌单')),
        buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('歌单详情固定行高：深位置定位/跳转不整表构建（回归 itemExtent）',
      (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    late final int plId;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_pld_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      plId = await direct.playlists.create('大歌单');
      for (var i = 0; i < 500; i++) {
        await direct.playlists.addSong(
          plId,
          Song(
            id: i,
            sourceKey: 'local:test',
            title: '歌曲 $i',
            artist: '歌手',
            source: 'local',
            sourceRef: 'r_$i',
            fileSize: 0,
          ),
        );
      }
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('歌曲 0'), findsOneWidget);
    final lv = tester.widget<ListView>(find.byType(ListView));
    // 无 itemExtent 时 Sliver 为定位深处需从第 0 行逐行排到目标行
    // （实测深位置首帧构建 712 行 vs 有 itemExtent 16 行），必卡。
    expect(lv.itemExtent, 73);
    expect(lv.controller, isNotNull);

    // 深位置跳转仍只构建可见行。
    lv.controller!.jumpTo(400 * 73.0);
    await tester.pump();
    expect(find.textContaining('歌曲 400'), findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(40));

    // 收尾让出：warmMetaOf 分期（每 300 首一批）批间 yieldToEventLoop 会排一个
    // 零延时 Timer；本用例只用了无参 pump()（不推进假时钟），帧后回调排下的
    // 这个 Timer 会悬到测试结束，触发「A Timer is still pending」不变量。
    // 补一拍 elapse 让它跑完（不涉及任何断言语义）。
    await tester.pump(Duration.zero);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('歌单详情行并回 SongTile：内置菜单 + 上移/下移/移除', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    late final int plId;
    await tester.runAsync(() async {
      direct = DirectSourceManager();
      final seeded = await _seedIndexedPlaylist(direct, 'selfmusic_plrow_');
      dir = seeded.$1;
      plId = seeded.$2;
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>(
              create: (_) => NavigationProvider()),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();

    // 行本体是共用的 SongTile（不再自绘 ListTile）
    expect(find.byType(SongTile), findsNWidgets(2));
    // 行内已有封面 + 播放指示位
    expect(find.byType(CoverThumb), findsNWidgets(2));

    // 首行三点菜单：内置项（喜欢/不喜欢/加入歌单）+ 顺序项（上移/下移/移除）
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.text('不喜欢'), findsOneWidget);
    expect(find.text('加入歌单'), findsOneWidget);
    expect(find.text('上移'), findsOneWidget);
    expect(find.text('下移'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
    // 首行不可上移、可以下移
    bool enabled(String label) => tester
        .widget<PopupMenuItem<String>>(find.ancestor(
            of: find.text(label), matching: find.byType(PopupMenuItem<String>)))
        .enabled;
    expect(enabled('上移'), isFalse);
    expect(enabled('下移'), isTrue);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('歌单详情搜索：按歌单内歌曲过滤（与歌曲页同源匹配）', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    late final int plId;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plsearch_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      plId = await direct.playlists.create('搜索歌单');
      await direct.playlists.addSong(plId, Song(
        id: 0,
        sourceKey: 'local:test',
        title: '夜曲',
        artist: '周杰伦',
        source: 'local',
        sourceRef: 'a',
        fileSize: 0,
      ));
      await direct.playlists.addSong(plId, Song(
        id: 1,
        sourceKey: 'local:test',
        title: '晴天',
        artist: '周杰伦',
        source: 'local',
        sourceRef: 'b',
        fileSize: 0,
      ));
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('夜曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsOneWidget);

    // 搜索命中的歌曲保留，其余过滤；计数头显示命中数。
    nav.setSearch('夜曲');
    await tester.pump();
    expect(find.textContaining('夜曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsNothing);
    expect(find.text('共 1 首歌曲'), findsOneWidget);

    nav.setSearch('');
    await tester.pump();
    expect(find.textContaining('晴天'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('歌单详情播放入口：播放 + 并列「从头播放」文字按钮（空三点菜单移除）', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    late final int plId;
    await tester.runAsync(() async {
      direct = DirectSourceManager();
      final seeded = await _seedIndexedPlaylist(direct, 'selfmusic_plplay_');
      dir = seeded.$1;
      plId = seeded.$2;
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>(
              create: (_) => NavigationProvider()),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('播放'), findsOneWidget);
    expect(find.text('播放全部'), findsNothing);
    expect(find.text('从头播放'), findsOneWidget);
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.byTooltip('从头播放'), findsNothing);
    expect(find.byTooltip('更多播放方式'), findsNothing);

    // 窄屏：两枚按钮仍带文字，标题让位但不溢出。
    tester.view.physicalSize = const ui.Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('从头播放'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('歌单详情多选：已选计数随勾选增长，搜索后全选只选命中项（回归 id 分叉）', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    late final int plId;
    await tester.runAsync(() async {
      direct = DirectSourceManager();
      final seeded = await _seedIndexedPlaylist(direct, 'selfmusic_plsel_');
      dir = seeded.$1;
      plId = seeded.$2;
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('共 2 首歌曲'), findsOneWidget);

    // 长按进入多选：已选计数应从 0 增到 1。
    await tester.longPress(find.textContaining('晴天'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);
    expect(find.text('已选 0'), findsNothing);
    expect(find.byTooltip('全选'), findsOneWidget);

    // 搜索范围内尚无选中 → 全选图标可用（选中的是被过滤掉的晴天）。
    nav.setSearch('夜曲');
    await tester.pump();
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.byTooltip('全选'), findsOneWidget);

    // 全选只作用于搜索命中项：计数 = 命中数 1（不是整单 2）。
    await tester.tap(find.byTooltip('全选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);
    expect(find.byTooltip('全不选'), findsOneWidget);

    // 清搜索后选择集仍是两首（晴天 + 夜曲）；多选期间计数栏不显示。
    nav.setSearch('');
    await tester.pump();
    expect(find.text('已选 2'), findsOneWidget);
    expect(find.text('共 2 首歌曲'), findsNothing);

    // 退出多选恢复计数栏。
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsNothing);
    expect(find.text('共 2 首歌曲'), findsOneWidget);

    // 批量「从歌单移除」按同一套键生效：选夜曲 → 移除 → 剩 1 首。
    await tester.longPress(find.textContaining('夜曲'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('播放选中'), findsOneWidget);
    expect(find.text('加入歌单'), findsOneWidget);
    expect(find.text('从歌单移除'), findsOneWidget);
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.text('不喜欢'), findsOneWidget);
    expect(find.text('缓存'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    bool enabled(String label) => tester
        .widget<PopupMenuItem<int>>(find.ancestor(
            of: find.text(label), matching: find.byType(PopupMenuItem<int>)))
        .enabled;
    expect(enabled('缓存'), isFalse);
    expect(enabled('删除'), isFalse);
    await tester.tap(find.text('从歌单移除'));
    await tester.pumpAndSettle();
    expect(find.text('确定从歌单中移除选中的 1 首歌曲？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await settleWriter(tester);

    expect(find.text('已选 1'), findsNothing);
    expect(find.text('共 1 首歌曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsOneWidget);
    expect(find.textContaining('夜曲'), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}
