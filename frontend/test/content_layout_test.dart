import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/app_shell.dart';
import 'package:selfmusic/layout/top_bar.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/widgets/square_card.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_layout_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

void main() {
  testWidgets('UI4 回归：内容区列表不再叠加系统安全区（顶栏已消费状态栏）',
      (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    // 模拟状态栏 100 / 手势条 40；ListView 自动内边距的根因就是它。
    tester.view.padding = const FakeViewPadding(top: 100, bottom: 40);
    addTearDown(tester.view.reset);

    final probe = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>(
                create: (_) => NavigationProvider()),
            ChangeNotifierProvider<PlayerProvider>(
                create: (_) => PlayerProvider()),
          ],
          child: AppShell(
            content: ListView(
              children: [SizedBox(key: probe, height: 20)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final topBarBottom = tester.getBottomLeft(find.byType(TopBar)).dy;
    final probeTop = tester.getTopLeft(find.byKey(probe)).dy;
    // 修复前会被自动垫高 100（状态栏高度）；修复后紧贴顶栏。
    expect(probeTop, closeTo(topBarBottom, 1.0));

    direct.dispose();
  });

  testWidgets('方形卡片回归：封面恒为正方形，且列宽不超过 220', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SquareCardGrid(
            itemCount: 4,
            itemBuilder: (c, i) =>
                SquareCard(title: '专辑 $i', subtitle: '歌手', onTap: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    final cover = tester.getSize(find.byType(AspectRatio).first);
    expect(cover.width, closeTo(cover.height, 0.01));
    // 400 宽 - 两侧 16 - 列间距 16 = 176（两列）
    expect(cover.width, closeTo(176, 0.5));
    expect(cover.width, lessThanOrEqualTo(SquareCardGrid.maxItemWidth));

    // 无封面（占位图标）时，占位底色也要撑满正方形，不能是矮长条。
    final placeholder = tester.getSize(find.byIcon(Icons.album).first);
    expect(placeholder.width, closeTo(cover.width, 0.5));
    expect(placeholder.height, closeTo(cover.height, 0.5));
  });
}
