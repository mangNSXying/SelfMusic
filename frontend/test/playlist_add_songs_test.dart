import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
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

/// 落库走后台写隔离（真实 isolate 往返）：交替 runAsync 与 pump。
Future<void> settleWriter(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pumpAndSettle();
}

Song _song(int id, String ref, String title, String album) => Song.direct(
      id: id,
      sourceKey: 'local:test',
      title: title,
      artist: '周杰伦',
      albumName: album,
      source: 'local',
      sourceRef: ref,
      fileSize: 1024,
      format: 'mp3',
    );

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  testWidgets('歌单详情添加歌曲：悬浮入口、已在歌单禁用、搜索与批量追加', (tester) async {
    late Directory dir;
    late DirectSourceManager direct;
    late int plId;
    late LibraryProvider lib;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_pladd_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.index.upsertSongs([
        for (final (i, s) in [
          _song(1, 'a', '夜曲', '十一月的萧邦'),
          _song(2, 'b', '晴天', '叶惠美'),
          _song(3, 'c', '七里香', '七里香'),
        ].indexed)
          DirectSongRow(
            sourceKey: s.sourceKey,
            ref: s.sourceRef,
            title: s.title,
            artist: s.artist,
            album: s.albumName,
            duration: 100,
            format: 'mp3',
            size: 1024,
            mtime: i + 1,
          ),
      ]);
      plId = await direct.playlists.create('测试歌单');
      await direct.playlists.addSong(plId, _song(1, 'a', '夜曲', '十一月的萧邦'));
      lib = LibraryProvider()..attachDirectManager(direct);
      lib.songs = [
        _song(1, 'a', '夜曲', '十一月的萧邦'),
        _song(2, 'b', '晴天', '叶惠美'),
        _song(3, 'c', '七里香', '七里香'),
      ];
    });

    final provider = PlaylistsProvider(direct.playlists)..refresh();
    final nav = NavigationProvider();
    final player = PlayerProvider();
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ],
        child: MaterialApp(
          home: Scaffold(body: PlaylistDetailView(playlistId: plId)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('添加歌曲'), findsOneWidget);
    await tester.tap(find.byTooltip('添加歌曲'));
    await tester.pumpAndSettle();

    expect(find.text('添加歌曲到「测试歌单」'), findsOneWidget);
    final sheet = find.byType(DraggableScrollableSheet);
    Finder sheetText(String s) =>
        find.descendant(of: sheet, matching: find.text(s));
    expect(sheetText('已在歌单'), findsOneWidget);

    // 已在歌单的行禁用：点按不进入已选。
    final existingTitle = sheetText('周杰伦 - 夜曲');
    expect(existingTitle, findsOneWidget);
    final existingTile = tester.widget<ListTile>(find
        .ancestor(of: existingTitle, matching: find.byType(ListTile))
        .first);
    expect(existingTile.enabled, isFalse);
    await tester.tap(existingTitle);
    await tester.pump();
    expect(find.text('添加'), findsOneWidget);

    // 搜索只留「晴天」。
    final searchField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索曲库添加歌曲');
    await tester.enterText(searchField, '晴天');
    await tester.pump();
    expect(sheetText('周杰伦 - 晴天'), findsOneWidget);
    expect(sheetText('周杰伦 - 七里香'), findsNothing);
    await tester.enterText(searchField, '');
    await tester.pump();

    // 选两首 → 确认。
    await tester.tap(sheetText('周杰伦 - 晴天'));
    await tester.pump();
    await tester.tap(sheetText('周杰伦 - 七里香'));
    await tester.pump();
    expect(find.text('添加 2 首'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '添加 2 首'));
    await tester.pumpAndSettle();
    await settleWriter(tester);

    expect(provider.countOf(plId), 3);
    final rows = provider.itemsOf(plId);
    expect([for (final r in rows) r.title], ['夜曲', '晴天', '七里香']);
    await tester.pump();
    expect(find.text('共 3 首歌曲'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}
