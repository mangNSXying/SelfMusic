import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/local_file_direct_source.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/sources_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/single_choice_group.dart';
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
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
  });

  testWidgets('窄屏添加播放源：类型选项换行、本地文件夹默认显示目录栏', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_src_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        direct.dispose();
        dir.deleteSync(recursive: true);
      });
    });

    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: ChangeNotifierProvider<NavigationProvider>(
          create: (_) => NavigationProvider(),
          child: MaterialApp(
            theme: AppTheme.build().themeData,
            home: const Scaffold(body: SourcesScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加播放源'));
    await tester.pumpAndSettle();

    expect(find.text('添加播放源'), findsOneWidget);
    expect(find.byType(SingleChoiceGroup<SourceKind>), findsOneWidget);
    expect(find.byType(SegmentedButton<SourceKind>), findsNothing);
    // 默认选中第一个类型「本地」。
    expect(find.text('本地文件夹'), findsOneWidget);
    expect(find.text('测试连接'), findsNothing);

    // 切到 WebDAV 后出现「测试连接」按钮。
    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();
    expect(find.text('测试连接'), findsOneWidget);

    final horizontalScrolls = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(horizontalScrolls, isEmpty);

    expect(
      tester.getTopLeft(find.text('本地')).dy,
      moreOrLessEquals(tester.getTopLeft(find.text('SMB')).dy, epsilon: 0.5),
    );
    expect(
      tester.getTopLeft(find.text('WebDAV')).dy,
      greaterThan(tester.getTopLeft(find.text('SMB')).dy),
    );
    expect(
      tester.getTopLeft(find.text('SFTP')).dy,
      greaterThan(tester.getTopLeft(find.text('WebDAV')).dy),
    );
    final groupRect =
        tester.getRect(find.byType(SingleChoiceGroup<SourceKind>));
    for (final label in ['本地', 'SMB', 'WebDAV', 'SFTP']) {
      expect(
        tester.getRect(find.text(label)).right,
        lessThanOrEqualTo(groupRect.right),
      );
    }

    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('选择文件夹'), findsOneWidget);
    expect(find.textContaining('无法选择文件夹'), findsNothing);
  });

  testWidgets('编辑本地文件源：已选文件列表限高滚动', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_src_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      await direct.addLocalFiles(
        name: '本地文件源',
        files: [
          for (var i = 0; i < 30; i++)
            LocalFileEntry(
              ref: 'track_${i.toString().padLeft(2, '0')}.mp3',
              uri: 'file:///music/track_$i.mp3',
              name: 'track_${i.toString().padLeft(2, '0')}.mp3',
              size: 1024 * 1024,
              mtime: 0,
            ),
        ],
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        direct.dispose();
        dir.deleteSync(recursive: true);
      });
    });

    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: ChangeNotifierProvider<NavigationProvider>(
          create: (_) => NavigationProvider(),
          child: MaterialApp(
            theme: AppTheme.build().themeData,
            home: const Scaffold(body: SourcesScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('源设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑播放源'), findsOneWidget);
    expect(find.text('已选择 30 个音频文件'), findsOneWidget);
    final fileList = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(ListView),
    );
    expect(fileList, findsOneWidget);
    expect(tester.getSize(fileList).height, lessThanOrEqualTo(240));
  });

  testWidgets('播放源列表跟随顶栏搜索按源名称过滤', (tester) async {
    late final Directory root;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('selfmusic_src_search_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      direct = DirectSourceManager();
      await direct.init();
      final a = Directory('${root.path}/a')..createSync();
      final b = Directory('${root.path}/b')..createSync();
      await direct.addLocal(name: '客厅音乐', path: a.path);
      await direct.addLocal(name: '书房音乐', path: b.path);
    });
    final nav = NavigationProvider();
    addTearDown(() {
      nav.dispose();
      direct.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: ChangeNotifierProvider<NavigationProvider>.value(
          value: nav,
          child: MaterialApp(
            theme: AppTheme.build().themeData,
            home: const Scaffold(body: SourcesScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('客厅音乐'), findsOneWidget);
    expect(find.text('书房音乐'), findsOneWidget);

    nav.setSearch('客厅');
    await tester.pumpAndSettle();
    expect(find.text('客厅音乐'), findsOneWidget);
    expect(find.text('书房音乐'), findsNothing);
    expect(find.text('共 1 个播放源'), findsOneWidget);

    nav.setSearch('不存在的源');
    await tester.pumpAndSettle();
    expect(find.text('无匹配播放源'), findsOneWidget);

    nav.clearSearch();
    await tester.pumpAndSettle();
    expect(find.text('客厅音乐'), findsOneWidget);
    expect(find.text('书房音乐'), findsOneWidget);
    expect(find.text('共 2 个播放源'), findsOneWidget);
  });
}
