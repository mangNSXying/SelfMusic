import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/screens/library_info/artist_detail_screen.dart';
import 'package:selfmusic/screens/library_info/meta_detail_screen.dart';
import 'package:selfmusic/screens/library_info/play_detail_screen.dart';
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
  await mgr.init();
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
      child: MaterialApp(home: Scaffold(body: child)),
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
    expect(find.byKey(const Key('play-detail-table')), findsNothing);
    expect(find.textContaining('共 250 首'), findsOneWidget);

    // 扁平开关：仅看有播放（song_0 没有播放记录）。
    expect(find.text('仅看有播放'), findsOneWidget);
    expect(find.text('250 首'), findsOneWidget);
    await tester.tap(find.text('仅看有播放'));
    await tester.pumpAndSettle();
    expect(find.text('249 首'), findsOneWidget);

    // 展开卡片看明细行。
    await tester.tap(find.text('歌曲 249'));
    await tester.pumpAndSettle();
    expect(find.text('播放时长'), findsOneWidget);
    expect(find.text('歌曲时长'), findsOneWidget);
    // 排序改为单一下拉菜单，展开卡片后只剩明细行这一处。
    expect(find.text('排序：次数 ↓'), findsOneWidget);
    expect(find.text('长期中位进度'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('播放数据·宽屏分页表格：只渲染当前页 25 行', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const PlayDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('play-detail-table')), findsOneWidget);
    expect(find.text('歌曲 249'), findsOneWidget);
    expect(find.textContaining('/ 250'), findsOneWidget);
    expect(find.text('长期中位进度'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    // 第 26 名不在当前页，未被构建。
    expect(find.text('歌曲 224'), findsNothing);

    // 表头可排序：点歌曲名 → 升序，第 1 页出现歌曲 0。
    await tester.tap(find.text('歌曲名'));
    await tester.pumpAndSettle();
    expect(find.text('歌曲 0'), findsOneWidget);

    // 表头可拖拽：列宽写入持久化设置。
    final handle = find.byKey(const ValueKey('table-resize-title'));
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(48, 0));
    await tester.pumpAndSettle();
    expect(mgr.settings.tableColumnWeights('library_play_detail'), isNotNull);
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
    expect(find.text('封面'), findsOneWidget);
  });

  testWidgets('元数据·窄屏：筛选与排序菜单', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const MetaDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.text('筛选：全部'), findsOneWidget);
    expect(find.text('排序：歌曲名 ↑'), findsOneWidget);

    await tester.tap(find.text('筛选：全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缺专辑'));
    await tester.pumpAndSettle();
    expect(find.text('筛选：缺专辑'), findsOneWidget);
    // 种子里 i%3==0 的 84 首没有专辑。
    expect(find.text('84 / 250 首'), findsOneWidget);

    await tester.tap(find.text('排序：歌曲名 ↑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缺失数'));
    await tester.pumpAndSettle();
    expect(find.text('排序：缺失数 ↓'), findsOneWidget);
  });

  testWidgets('元数据·宽屏分页表格：14 列与缺失值直显', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const MetaDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('meta-detail-table')), findsOneWidget);
    expect(find.text('缺失数'), findsOneWidget);
    expect(find.text('1–25 / 250'), findsOneWidget);

    final handle = find.byKey(const ValueKey('table-resize-title'));
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(mgr.settings.tableColumnWeights('library_meta_detail'), isNotNull);
  });

  testWidgets('歌手详情：状态与映射用条状展示', (tester) async {
    // 写隔离的 Future 要在真实异步环境里等，否则 widget test 会挂住。
    await tester.runAsync(() async {
      for (final (key, status) in [
        ('a1', 'resolved'),
        ('a2', 'ambiguous'),
        ('a3', 'pending'),
        ('a4', 'local'),
      ]) {
        await mgr.index.artistUpsert(
          artistKey: key,
          canonicalKey: key,
          displayName: key,
          status: status,
          errorCount: 0,
          nextAt: 0,
        );
      }
    });
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, const ArtistDetailScreen()));
    await tester.pumpAndSettle();

    expect(find.text('解析状态'), findsOneWidget);
    // 四个状态各 1 个，映射 0 / 250；四条状态条 + 一条映射条。
    expect(find.text('1 个 · 25%'), findsNWidgets(4));
    expect(find.text('0 / 250 首 · 0%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(5));
  });
}
