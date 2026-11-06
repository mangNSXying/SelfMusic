import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/library/entry_songs_view.dart';
import 'package:selfmusic/utils/song_groups.dart';
import 'package:selfmusic/widgets/locate_current_button.dart';
import 'package:selfmusic/widgets/row_list.dart';
import 'package:selfmusic/widgets/song_collection_view.dart';
import 'package:selfmusic/widgets/song_table.dart';
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

Song _song(int id, String ref, {String? title}) => Song.direct(
      id: id,
      sourceKey: 'local:test',
      title: title ?? '歌$id',
      source: 'local',
      sourceRef: ref,
      fileSize: 1,
    );

/// 计数栏「定位当前曲」：点击后滚到当前播放行（含折叠组展开 / 不在列表置灰）。
void main() {
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    dir = await Directory.systemTemp.createTemp('selfmusic_locate_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
  });

  tearDown(() async {
    direct.dispose();
    await dir.delete(recursive: true);
  });

  Future<PlayerProvider> newPlayer(
      WidgetTester tester, List<Song> queue, int playing) async {
    late final PlayerProvider player;
    await tester.runAsync(() async {
      player = PlayerProvider();
      player.loadOverride = (s, src) async {};
      await player.playQueue(queue, index: playing, source: _FakeSource());
    });
    addTearDown(player.dispose);
    return player;
  }

  Future<void> pumpCollection(
    WidgetTester tester, {
    required List<Song> songs,
    required int playing,
    List<Song>? queue,
    SongGroupMode mode = SongGroupMode.none,
  }) async {
    final player = await newPlayer(tester, queue ?? songs, playing);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongCollectionView(
              songs: songs,
              searching: false,
              collectionKey: 'locate',
              groupMode: mode,
              onGroupModeChanged: (_) {},
              sort: direct.settings.sortSongs,
              onSortChanged: (_) {},
              onPlay: (_, __) {},
              onPlayGroup: (_) {},
              selectionActions: (_, __) => const [],
              emptyText: '空',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('歌曲列表：点击定位滚到当前播放行', (tester) async {
    final songs = [for (var i = 1; i <= 60; i++) _song(i, 's$i.mp3')];
    await pumpCollection(tester, songs: songs, playing: 50);

    final scrollable = find.descendant(
        of: find.byType(SongCollectionView),
        matching: find.byType(Scrollable));
    final pos = tester.state<ScrollableState>(scrollable).position;
    expect(pos.pixels, 0);

    await tester.tap(find.byType(LocateCurrentButton));
    await tester.pump();

    expect(pos.pixels, closeTo(50 * kRowExtent - 96, 0.5));
    expect(find.text('歌51'), findsOneWidget);
  });

  testWidgets('歌曲列表：当前曲在折叠组内时先展开再定位', (tester) async {
    final songs = [
      _song(1, '文件夹A/one.mp3', title: '晴天'),
      _song(2, '文件夹A/two.mp3', title: '夜曲'),
      _song(3, '文件夹B/three.mp3', title: '稻香'),
    ];
    await pumpCollection(tester,
        songs: songs, playing: 1, mode: SongGroupMode.folder);

    await tester.tap(find.text('文件夹A'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('夜曲'), findsNothing);

    await tester.tap(find.byType(LocateCurrentButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('夜曲'), findsOneWidget);
  });

  testWidgets('歌曲列表：当前曲不在本列表时定位按钮置灰', (tester) async {
    final songs = [_song(1, 's1.mp3'), _song(2, 's2.mp3')];
    await pumpCollection(tester,
        songs: songs, playing: 0, queue: [_song(9, 'other.mp3')]);

    final button =
        tester.widget<LocateCurrentButton>(find.byType(LocateCurrentButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('专辑/歌手歌曲列表：点击定位滚到当前播放行', (tester) async {
    final songs = [for (var i = 1; i <= 40; i++) _song(i, 'a$i.mp3')];
    final player = await newPlayer(tester, songs, 30);
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<LibraryProvider>(
              create: (_) => LibraryProvider()),
          ChangeNotifierProvider<NavigationProvider>(
              create: (_) => NavigationProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EntrySongsView(
              songs: songs,
              scrollCtrl: ctrl,
              title: '测试专辑',
              showClose: false,
              fromSheet: false,
              contextKey: 'album:test',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(ctrl.offset, 0);

    await tester.tap(find.byType(LocateCurrentButton));
    await tester.pump();

    // 表格模式：列表前多一行 pinned 表头（32px），定位偏移随之抬高。
    expect(ctrl.offset,
        closeTo(30 * kRowExtent - 96 + kSongTableHeaderHeight, 0.5));
    expect(find.text('歌31'), findsOneWidget);
  });
}
