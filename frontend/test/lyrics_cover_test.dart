import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/player/player_cover.dart';
import 'package:selfmusic/screens/player/player_now_playing.dart';
import 'package:sqlite3/open.dart';

/// 竖屏歌词页专辑封面：默认显示，关闭设置后回到「标题 + 歌词」原布局。

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
  String get key => 'webdav:lyrics';
  @override
  String get name => 'lyrics';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:lyrics',
      title: '歌词页测试曲目',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_lyrics_cover_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

Future<PlayerProvider> _playerWithCurrent() async {
  final p = PlayerProvider();
  p.loadOverride = (s, src) async {};
  await p.playQueue([_song()], source: _FakeSource());
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('默认显示封面，关闭设置后隐藏', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: const Scaffold(body: LyricsPage()),
        ),
      ),
    );
    await tester.pump();

    expect(direct.settings.lyricsShowCover, isTrue, reason: '默认开');
    expect(find.byType(CoverArt), findsOneWidget);
    // 封面略小于可用宽度，给标题与歌词区留出空间。
    final coverSize = tester.getSize(find.byType(CoverArt)).width;
    expect(coverSize, greaterThan(0));
    expect(coverSize, lessThan(200));

    direct.settings.lyricsShowCover = false;
    direct.refresh();
    await tester.pump();

    expect(find.byType(CoverArt), findsNothing);
  });
}
