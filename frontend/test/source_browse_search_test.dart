import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/source_browse_view.dart';
import 'package:selfmusic/theme/app_theme.dart';
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

/// 源内浏览挂载后会自动扫描；测试用空目录会把手工灌入的索引行标 missing，
/// 故这里让扫描直接失败（页面会 toast 并结束），只验证搜索词接线。
class _NoScanDirectSourceManager extends DirectSourceManager {
  @override
  Future<ScanSummary> scanSource(String key) async =>
      throw StateError('测试跳过扫描');
}

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
  });

  testWidgets('源内搜索复用顶栏搜索词，不再自带输入框', (tester) async {
    late final Directory root;
    late final DirectSourceManager direct;
    late final String sourceKey;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('selfmusic_src_browse_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      direct = _NoScanDirectSourceManager();
      await direct.init();
      final musicDir = Directory('${root.path}/music')..createSync();
      await direct.addLocal(name: '测试源', path: musicDir.path);
      sourceKey = direct.sources.single.key;
      await direct.index.upsertSongs([
        DirectSongRow(
          sourceKey: sourceKey,
          ref: 'a',
          title: '夜曲',
          artist: '周杰伦',
          album: '十一月的萧邦',
          duration: 100,
          format: 'mp3',
          size: 1024,
          mtime: 1,
        ),
        DirectSongRow(
          sourceKey: sourceKey,
          ref: 'b',
          title: '晴天',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 120,
          format: 'mp3',
          size: 1024,
          mtime: 2,
        ),
      ]);
    });
    final nav = NavigationProvider();
    final lib = LibraryProvider()..attachDirectManager(direct);
    addTearDown(() {
      nav.dispose();
      lib.dispose();
      direct.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<LibraryProvider>.value(value: lib),
          ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider()),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: MaterialApp(
          theme: AppTheme.build().themeData,
          home: Scaffold(body: SourceBrowseView(sourceKey: sourceKey)),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    // 源内不再有独立搜索框。
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('夜曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsOneWidget);

    // 顶栏搜索词直接过滤当前源；搜索态强制平铺并显示命中数。
    nav.setSearch('夜曲');
    await tester.pumpAndSettle();
    expect(find.textContaining('夜曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsNothing);
    expect(find.text('搜索到 1 首'), findsOneWidget);

    nav.clearSearch();
    await tester.pumpAndSettle();
    expect(find.textContaining('夜曲'), findsOneWidget);
    expect(find.textContaining('晴天'), findsOneWidget);
  });
}
