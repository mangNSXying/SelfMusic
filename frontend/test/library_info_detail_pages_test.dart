import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/screens/library_info_meta_detail.dart';
import 'package:selfmusic/screens/library_info_play_detail.dart';
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

/// 250 首 + 逐首 play_sec=i*10（song_0 未播放），消息面覆盖两种布局。
Future<DirectSourceManager> _seed() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_infodetail_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final mgr = DirectSourceManager();
  await mgr.index.open();
  final rows = <DirectSongRow>[
    for (var i = 0; i < 250; i++)
      DirectSongRow(
        sourceKey: 'local:test',
        ref: 'song_$i',
        title: '歌曲 $i',
        artist: '歌手 ${i % 5}',
        album: i % 3 == 0 ? null : '专辑',
        duration: 100,
        format: 'mp3',
        size: 1024,
        mtime: i,
      ),
  ];
  await mgr.index.upsertSongs(rows);
  for (var i = 1; i < 250; i++) {
    await mgr.index.upsertPlayMeta('local:test', 'song_$i', playSec: i * 10);
  }
  await mgr.index.recordProgress('local:test', 'song_249', 100);
  return mgr;
}

Widget _wrap(DirectSourceManager mgr, Widget child) =>
    ChangeNotifierProvider<DirectSourceManager>.value(
      value: mgr,
      child: MaterialApp(home: child),
    );

void main() {
  late DirectSourceManager mgr;

  setUp(() async {
    mgr = await _seed();
  });

  testWidgets('播放数据·窄屏卡片：可滚动卡片列表，不渲染分页表格', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const PlayDetailScreen()));
    await tester.pumpAndSettle();

    // 默认次数降序：song_249（24.9 次）在最前。
    expect(find.text('歌曲 249'), findsOneWidget);
    expect(find.text('24.9 次'), findsOneWidget);
    expect(find.byType(PaginatedDataTable), findsNothing);
    expect(find.textContaining('共 250 首'), findsOneWidget);

    // 展开卡片看明细行。
    await tester.tap(find.text('歌曲 249'));
    await tester.pumpAndSettle();
    expect(find.text('播放时长'), findsOneWidget);
    expect(find.text('歌曲时长'), findsOneWidget);
    // 排序按钮 + 展开卡片明细行。
    expect(find.text('中位进度'), findsNWidgets(2));
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('播放数据·宽屏分页表格：只渲染当前页 25 行', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const PlayDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(PaginatedDataTable), findsOneWidget);
    expect(find.text('歌曲 249'), findsOneWidget);
    expect(find.textContaining('of 250'), findsOneWidget);
    expect(find.text('中位进度'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    // 第 26 名不在当前页，未被构建。
    expect(find.text('歌曲 224'), findsNothing);
  });

  testWidgets('元数据·窄屏卡片：展开 12 维明细', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const MetaDetailScreen()));
    await tester.pumpAndSettle();

    // 默认歌曲名升序：song_0 在最前（种子数据多数字段留空 → 有缺失）。
    expect(find.text('歌曲 0'), findsOneWidget);
    expect(find.textContaining('缺 '), findsWidgets);

    await tester.tap(find.text('歌曲 0'));
    await tester.pumpAndSettle();
    expect(find.text('专辑歌手'), findsOneWidget);
    expect(find.text('专辑封面'), findsOneWidget);
  });

  testWidgets('元数据·宽屏分页表格：14 列与缺失值直显', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const MetaDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(PaginatedDataTable), findsOneWidget);
    expect(find.text('缺失数'), findsOneWidget);
    expect(find.textContaining('of 250'), findsOneWidget);
  });
}
