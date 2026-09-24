import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/playlists_view.dart';
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
      direct.playlists.create('已有歌单');
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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

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
      direct.playlists.create('现有歌单');
      direct.playlists.create('另一个歌单');
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
    expect(find.text('全选'), findsOneWidget);
    // 批量操作已收进右侧三点菜单。
    expect(find.byTooltip('更多操作'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除选中'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    // 点击另一项累计选中 → 全部选中后按钮变为「取消全选」
    await tester.tap(find.text('另一个歌单'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 2'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    // 取消全选清空勾选
    await tester.tap(find.text('取消全选'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);

    // 全选勾满
    await tester.tap(find.text('全选'));
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
      plId = direct.playlists.create('大歌单');
      for (var i = 0; i < 500; i++) {
        direct.playlists.addSong(
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

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}