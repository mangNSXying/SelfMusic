import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/library_info/library_info_overview.dart';
import 'package:selfmusic/services/artist_resolver.dart';
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

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_info_overview_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final mgr = DirectSourceManager();
  await mgr.init();
  addTearDown(mgr.dispose);
  return mgr;
}

/// 30 首：3 种格式、部分无专辑、部分有播放时长。
Future<DirectSourceManager> _seed() async {
  final mgr = await _openDirect();
  final rows = <DirectSongRow>[
    for (var i = 0; i < 30; i++)
      DirectSongRow(
        sourceKey: 'local:test',
        ref: 'song_$i',
        title: '歌曲 $i',
        artist: '歌手 ${i % 3}',
        album: i % 3 == 0 ? null : '专辑',
        duration: 120,
        format: i < 15 ? 'mp3' : (i < 25 ? 'flac' : 'm4a'),
        size: 1024,
        mtime: i,
      ),
  ];
  await mgr.index.upsertSongs(rows);
  for (var i = 1; i < 30; i++) {
    await mgr.index.upsertPlayMeta('local:test', 'song_$i', playSec: i * 20);
  }
  return mgr;
}

Widget _wrap(DirectSourceManager mgr, ArtistResolver resolver) => MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: mgr),
        ChangeNotifierProvider<ArtistResolver>.value(value: resolver),
        ChangeNotifierProvider<NavigationProvider>(
          create: (_) => NavigationProvider(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: LibraryInfoScreen()),
      ),
    );

void main() {
  testWidgets('总览：宽屏两列、窄屏单列，五张卡齐全且无溢出', (tester) async {
    late final DirectSourceManager mgr;
    await tester.runAsync(() async {
      mgr = await _seed();
    });
    final resolver = ArtistResolver(mgr.index);
    addTearDown(resolver.dispose);

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, resolver));
    await tester.pumpAndSettle();

    // 宽屏：元数据 / 歌手两张卡在同一行。
    expect(
      tester.getTopLeft(find.text('歌手身份')).dy,
      tester.getTopLeft(find.text('元数据覆盖')).dy,
      reason: '宽屏应为两列卡片',
    );

    for (final title in ['曲库概览', '元数据覆盖', '歌手身份', '格式分布', '播放数据']) {
      await tester.scrollUntilVisible(
        find.text(title),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('查看明细'), findsNWidgets(4));
    // 格式 / 播放卡与元数据卡一样走条状展示（右侧带数量）。
    expect(find.text('15 首 · 50%'), findsOneWidget);
    expect(find.text('24 首 · 80%'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 窄屏：单列排布，滚到底部同样完整。
    await tester.pumpWidget(const SizedBox());
    tester.view.physicalSize = const Size(400, 900);
    await tester.pumpWidget(_wrap(mgr, resolver));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('歌手身份')).dy,
      greaterThan(tester.getTopLeft(find.text('元数据覆盖')).dy),
      reason: '窄屏应为单列卡片',
    );
    for (final title in ['曲库概览', '元数据覆盖', '歌手身份', '格式分布', '播放数据']) {
      await tester.scrollUntilVisible(
        find.text(title),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览：空库提示去扫描', (tester) async {
    late final DirectSourceManager mgr;
    await tester.runAsync(() async {
      mgr = await _openDirect();
    });
    final resolver = ArtistResolver(mgr.index);
    addTearDown(resolver.dispose);

    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(mgr, resolver));
    await tester.pumpAndSettle();

    expect(find.text('暂无歌曲，先去播放源页扫描'), findsOneWidget);
  });
}
