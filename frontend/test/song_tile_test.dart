import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/widgets/song_tile.dart';
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
  String get name => 't';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50}) async => const [];
  @override
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50}) async => const [];
  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async => const [];
  @override
  String? streamUrl(int songId) => null;
  @override
  Map<String, String>? streamHeaders() => null;
}

void main() {
  testWidgets('三点菜单内切换喜欢态；副标题展示专辑歌手', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_tilefav_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '测试歌',
      artist: '曲目歌手',
      albumArtist: '专辑歌手',
      albumName: '测试专辑',
      source: 'webdav',
      sourceRef: '/dav/a.mp3',
      fileSize: 1024,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongTile(
              song: song,
              source: _FakeSource(),
              onPlay: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 副标题：歌手 · 专辑 · 专辑歌手（与歌手不同时展示）。
    expect(find.text('曲目歌手 · 测试专辑 · 专辑歌手：专辑歌手'), findsOneWidget);
    // 列表行不再直接放置喜欢按钮。
    expect(find.byIcon(Icons.favorite_border), findsNothing);

    Future<void> openMenu() async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    await openMenu();
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);

    await tester.tap(find.text('喜欢'));
    await tester.pumpAndSettle();

    await openMenu();
    expect(find.text('取消喜欢'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);

    await tester.tap(find.text('取消喜欢'));
    await tester.pumpAndSettle();

    await openMenu();
    expect(find.text('喜欢'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}
