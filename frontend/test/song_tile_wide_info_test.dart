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

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:t';
  @override
  String get name => 'NAS';
  @override
  SourceKind get kind => SourceKind.webdav;
}

/// 建真实 DirectSourceManager（SongTile build 需要 settings/weight）。
///
/// 注意：本文件**不清理临时目录**——Windows 下 deleteSync 偶发
/// PathAccessException(errno 32)（句柄延迟释放），留给系统临时目录
/// 清理机制即可；这是与 song_tile_test 的唯一差异，保证本机可跑绿。
Future<DirectSourceManager> openDirect(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

void main() {
  testWidgets('宽行（≥800px）：时长左侧显示「播放源 · 格式 · 码率 · 大小」', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await openDirect('selfmusic_widewide_');
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '宽屏歌',
      artist: '歌手',
      duration: 240, // 04:00
      source: 'webdav',
      sourceRef: '/dav/w.flac',
      fileSize: 25 * 1024 * 1024, // 25.0 MB
      format: 'flac',
    );

    tester.view.physicalSize = const Size(1200, 900);
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
            body: SongTile(song: song, source: _FakeSource(), onPlay: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    // 25 MiB / 240s = 853 kbps；播放源用友好名、格式大写、大小保留 1 位小数。
    final info = find.text('NAS · FLAC · 853 kbps · 25.0 MB');
    expect(info, findsOneWidget);
    final duration = find.text('04:00');
    expect(duration, findsOneWidget);
    // 信息位于时长左侧（与时长同在 trailing 行内）。
    expect(tester.getRect(info).right,
        lessThanOrEqualTo(tester.getRect(duration).left));

    // 阈值边界：恰好 800 仍显示。
    tester.view.physicalSize = const Size(800, 900);
    await tester.pump();
    expect(info, findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
    });
  });

  testWidgets('窄行（<800px）：不显示宽行信息，仅时长与菜单', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await openDirect('selfmusic_widenarrow_');
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '窄屏歌',
      artist: '歌手',
      duration: 240,
      source: 'webdav',
      sourceRef: '/dav/n.flac',
      fileSize: 25 * 1024 * 1024,
      format: 'flac',
    );

    tester.view.physicalSize = const Size(700, 900);
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
            body: SongTile(song: song, source: _FakeSource(), onPlay: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
    expect(find.textContaining('FLAC'), findsNothing);
    expect(find.textContaining('kbps'), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
    });
  });

  testWidgets('宽行缺时长：跳过码率，仅「播放源 · 格式 · 大小」', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await openDirect('selfmusic_widenodur_');
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '无时长歌',
      artist: '歌手',
      source: 'webdav',
      sourceRef: '/dav/x.mp3',
      fileSize: 512 * 1024, // 512 KB（不足 1 MB 降为 KB）
      format: 'mp3',
    );

    tester.view.physicalSize = const Size(1200, 900);
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
            body: SongTile(song: song, source: _FakeSource(), onPlay: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('NAS · MP3 · 512 KB'), findsOneWidget);
    expect(find.textContaining('kbps'), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
    });
  });
}
