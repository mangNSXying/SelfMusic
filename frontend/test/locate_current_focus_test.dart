import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/utils/song_groups.dart';
import 'package:selfmusic/widgets/row_list.dart';
import 'package:selfmusic/widgets/song_collection_view.dart';
import 'package:selfmusic/widgets/song_list_locator.dart';
import 'package:sqlite3/open.dart';

/// 「定位当前曲」的进入即追焦回归（统一调度见 `CurrentSongFocusController`）：
/// - 挂载即定位（含首帧后补跳）；
/// - 当前曲在折叠组里时自动展开再定位（此前只有手动按钮会展开）；
/// - 当前曲身份按 sourceKey+sourceRef 判定（库内 id 不一致也能定位）；
/// - 重复曲按调用方给出的「正在播的那一份」行号定位。

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

void main() {
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    dir = await Directory.systemTemp.createTemp('selfmusic_locate_focus_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
  });

  tearDown(() async {
    direct.dispose();
    // Windows 上写隔离句柄释放稍晚（仓库已知环境问题），清理失败不算用例失败。
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
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
    String collectionKey = 'locate:focus',
    bool focusCurrent = true,
    int? currentIndexHint,
    ValueListenable<int>? focusTick,
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
              collectionKey: collectionKey,
              groupMode: mode,
              onGroupModeChanged: (_) {},
              sort: direct.settings.sortSongs,
              onSortChanged: (_) {},
              onPlay: (_, __) {},
              onPlayGroup: (_) {},
              selectionActions: (_, __) => const [],
              emptyText: '空',
              focusCurrent: focusCurrent,
              focusTick: focusTick,
              currentIndexHint: currentIndexHint,
            ),
          ),
        ),
      ),
    );
    // 自动追焦走 post-frame 调度：多泵两帧（含展开折叠组后的重试）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  ScrollPosition listPosition(WidgetTester tester) {
    final scrollable = find.descendant(
        of: find.byType(SongCollectionView), matching: find.byType(Scrollable));
    return tester.state<ScrollableState>(scrollable).position;
  }

  testWidgets('自动追焦：挂载即定位到当前播放行', (tester) async {
    final songs = [for (var i = 1; i <= 60; i++) _song(i, 's$i.mp3')];
    await pumpCollection(tester, songs: songs, playing: 50);

    expect(listPosition(tester).pixels,
        closeTo(50 * kRowExtent - SongListLocator.margin, 0.5));
    expect(find.text('歌51'), findsOneWidget);
  });

  testWidgets('自动追焦：当前曲在折叠组内时自动展开并定位', (tester) async {
    final songs = [
      _song(1, '文件夹A/one.mp3', title: '晴天'),
      _song(2, '文件夹A/two.mp3', title: '夜曲'),
      _song(3, '文件夹B/three.mp3', title: '稻香'),
    ];
    // 先折叠当前曲所在的组（模拟用户此前手动折叠过）。
    direct.settings.setGroupCollapsed('locate:fold', {'文件夹A'});

    await pumpCollection(
      tester,
      songs: songs,
      playing: 1,
      mode: SongGroupMode.folder,
      collectionKey: 'locate:fold',
    );

    expect(find.text('夜曲'), findsOneWidget, reason: '自动展开后应能看到当前曲');
    // 三首歌 + 一个组头不足一屏：定位语义只要求目标可见，偏移钳在 0。
    expect(listPosition(tester).pixels, 0);
  });

  testWidgets('自动追焦：库内 id 不一致（快照 vs 实时行）仍能定位', (tester) async {
    // 列表为实时行（id=51），播放队列里的同一首 id=0（断点恢复/歌单快照）。
    final songs = [for (var i = 1; i <= 60; i++) _song(i, 's$i.mp3')];
    final queue = [for (var i = 1; i <= 60; i++) _song(0, 's$i.mp3')];
    await pumpCollection(tester, songs: songs, playing: 50, queue: queue);

    expect(listPosition(tester).pixels,
        closeTo(50 * kRowExtent - SongListLocator.margin, 0.5));
  });

  testWidgets('自动追焦：重复曲定位到正在播的那一份（currentIndexHint）', (tester) async {
    // 第 61 行是第 1 行的复本；正在播的是复本而不是第一份。
    final songs = [
      for (var i = 1; i <= 60; i++) _song(i, 's$i.mp3'),
      _song(1, 's1.mp3'),
    ];
    await pumpCollection(tester,
        songs: songs, playing: 60, currentIndexHint: 60);

    final pos = listPosition(tester);
    // 末行定位会被 maxScrollExtent 钳位；只验证「没有回到第一份（行 0）」。
    final want = (60 * kRowExtent - SongListLocator.margin)
        .clamp(0.0, pos.maxScrollExtent);
    expect(pos.pixels, closeTo(want, 0.5));
    expect(pos.pixels, greaterThan(1000), reason: '重复曲不应定位到第一份');
  });

  testWidgets('focusTick 重进：重新定位到新的当前曲', (tester) async {
    final songs = [for (var i = 1; i <= 60; i++) _song(i, 's$i.mp3')];
    final player = await newPlayer(tester, songs, 5);
    final tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
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
              collectionKey: 'locate:tick',
              groupMode: SongGroupMode.none,
              onGroupModeChanged: (_) {},
              sort: direct.settings.sortSongs,
              onSortChanged: (_) {},
              onPlay: (_, __) {},
              onPlayGroup: (_) {},
              selectionActions: (_, __) => const [],
              emptyText: '空',
              focusCurrent: true,
              focusTick: tick,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(listPosition(tester).pixels, closeTo(5 * kRowExtent - 96, 0.5));

    await tester.runAsync(() => player.playAt(49));
    tick.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(listPosition(tester).pixels,
        closeTo(49 * kRowExtent - SongListLocator.margin, 0.5));
  });
}
