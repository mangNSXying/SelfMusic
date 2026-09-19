import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
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
  testWidgets('播放前用索引最新行纠正旧快照（歌名/歌手/专辑即时可见）',
      (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_reconcile_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      direct.index.upsertSongs([
        DirectSongRow(
          sourceKey: 'local:t',
          ref: '/music/a.mp3',
          title: 'a',
          format: 'mp3',
          size: 1024,
          mtime: 1,
        ),
      ]);
      direct.index.enrichSong('local:t', '/music/a.mp3',
          title: '补读歌名', artist: '补读歌手', album: '补读专辑');
    });

    final player = PlayerProvider()
      ..attachPersistence(index: direct.index, weight: direct.weight);

    // 调用方携带的是补读前的旧快照（歌单快照/断点恢复的典型形态）。
    final stale = Song.direct(
      id: 999,
      sourceKey: 'local:t',
      title: 'a',
      source: 'local',
      sourceRef: '/music/a.mp3',
      fileSize: 1024,
      format: 'mp3',
    );
    final live = player.resolveLiveSong(stale);
    expect(live.title, '补读歌名');
    expect(live.artist, '补读歌手');
    expect(live.albumName, '补读专辑');
    expect(live.id, isNot(stale.id)); // 确实换成了索引行

    // 索引中没有的源（服务端）原样返回，不影响代理播放。
    final server = Song(
      id: 7,
      sourceKey: 'server',
      title: '服务端歌',
      source: 'server',
      sourceRef: '7',
      fileSize: 0,
    );
    expect(identical(player.resolveLiveSong(server), server), isTrue);

    await tester.runAsync(() async {
      player.dispose();
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}
