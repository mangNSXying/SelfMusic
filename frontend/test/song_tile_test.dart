import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/widgets/selection_badge.dart';
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

void main() {

  testWidgets('播放中：封面保留，指示在标题后（改进.txt）', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_tileplay_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '测试歌',
      artist: '歌手',
      duration: 200,
      source: 'webdav',
      sourceRef: '/dav/play.mp3',
      fileSize: 1024,
    );

    Future<void> pumpTile(bool playing) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>(
                create: (_) => PlayerProvider()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SongTile(
                song: song,
                source: _FakeSource(),
                playing: playing,
                onPlay: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpTile(false);
    // 普通行：无播放指示，封面缩略图在位
    expect(find.byIcon(Icons.graphic_eq), findsNothing);
    expect(find.byType(CoverThumb), findsOneWidget);

    await pumpTile(true);
    // 播放行：封面仍在（指示不再替换封面）
    expect(find.byType(CoverThumb), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);

    // 指示排在标题之后：标题右边界 ≤ 指示左边界
    final titleRect = tester.getRect(find.textContaining('测试歌'));
    final eqRect = tester.getRect(find.byIcon(Icons.graphic_eq));
    expect(eqRect.left, greaterThanOrEqualTo(titleRect.right));
    // 指示用强调色（与标题同色）
    final cs = Theme.of(tester.element(find.byIcon(Icons.graphic_eq))).colorScheme;
    expect(tester.widget<Icon>(find.byIcon(Icons.graphic_eq)).color, cs.primary);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
  testWidgets('多选态：勾选框叠在封面左上角，点标记等同点行', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_tilesel_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '测试歌',
      artist: '歌手',
      albumName: '测试专辑',
      duration: 200,
      source: 'webdav',
      sourceRef: '/dav/sel.mp3',
      fileSize: 1024,
    );

    var taps = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongTile(
              song: song,
              source: _FakeSource(),
              onPlay: () {},
              selectionMode: true,
              selected: false,
              onSelect: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 勾选框不再顶替封面：两者同时在位
    expect(find.byType(CoverThumb), findsOneWidget);
    final badge = find.byType(SelectionBadge);
    expect(badge, findsOneWidget);
    // 标记叠在封面左上角（不居中、不在行外）
    final coverRect = tester.getRect(find.byType(CoverThumb));
    final badgeRect = tester.getRect(badge);
    expect(badgeRect.left, lessThan(coverRect.center.dx));
    expect(badgeRect.top, lessThan(coverRect.center.dy));
    expect(badgeRect.bottom, lessThanOrEqualTo(coverRect.bottom));
    expect(badgeRect.right, lessThanOrEqualTo(coverRect.right));
    expect(
        tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

    // 点标记 → 走 onSelect（与点整行一致）
    await tester.tap(badge);
    expect(taps, 1);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('紧凑形态（队列）：无封面、副标题仅歌手、无尾部菜单', (tester) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_tilecompact_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });

    final song = Song(
      id: 1,
      sourceKey: 'webdav:t',
      title: '测试歌',
      artist: '曲目歌手',
      albumName: '测试专辑',
      albumArtist: '专辑歌手',
      duration: 200,
      source: 'webdav',
      sourceRef: '/dav/c.mp3',
      fileSize: 1024,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongTile(
                song: song, source: _FakeSource(), onPlay: () {}, compact: true),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CoverThumb), findsNothing);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    // 副标题只剩歌手（无「歌手 · 专辑」）
    final sub = tester.widget<Text>(find.byType(Text).last);
    expect(sub.data, '曲目歌手');
    // 无尾部菜单与时长
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });

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
      duration: 200,
      source: 'webdav',
      sourceRef: '/dav/a.mp3',
      fileSize: 1024,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
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

    // 副标题：歌手 · 专辑 · 专辑歌手（与歌手不同时展示）；时长由秒换算为 mm:ss。
    expect(find.text('曲目歌手 · 测试专辑 · 专辑歌手：专辑歌手'), findsOneWidget);
    expect(find.text('03:20'), findsOneWidget);
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
    await settleWriter(tester);

    await openMenu();
    expect(find.text('取消喜欢'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);

    await tester.tap(find.text('取消喜欢'));
    await settleWriter(tester);

    await openMenu();
    expect(find.text('喜欢'), findsOneWidget);

    await tester.runAsync(() async {
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}
