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
import 'package:selfmusic/widgets/content_shell.dart';
import 'package:selfmusic/widgets/count_header.dart';
import 'package:selfmusic/widgets/row_list.dart';
import 'package:selfmusic/widgets/selection_badge.dart';
import 'package:selfmusic/widgets/selection_bar.dart';
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

void _noop() {}

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

  testWidgets('方形卡片多选：勾选框叠封面左上角，隐藏角标菜单', (tester) async {
    const card = SizedBox(
      width: 120,
      child: SquareCard(
        title: '普通',
        onTap: _noop,
        cornerAction: Icon(Icons.settings),
      ),
    );

    // 普通态：角标菜单在位，无勾选框
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Column(children: [card]))));
    await tester.pump();
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byType(SelectionBadge), findsNothing);

    // 多选态：角标菜单隐藏（防误触），勾选框改叠在封面左上角
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 120,
                child: SquareCard(
                  title: '未选中',
                  onTap: _noop,
                  selectionMode: true,
                  cornerAction: Icon(Icons.settings),
                ),
              ),
              SizedBox(
                width: 120,
                child: SquareCard(
                  title: '选中',
                  onTap: _noop,
                  selectionMode: true,
                  selected: true,
                  cornerAction: Icon(Icons.settings),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.settings), findsNothing);
    expect(find.byType(SelectionBadge), findsNWidgets(2));

    final cover1 = tester.getRect(find.byType(AspectRatio).at(0));
    final badge1 = tester.getRect(find.byType(SelectionBadge).at(0));
    expect(badge1.left, lessThan(cover1.center.dx));
    expect(badge1.top, lessThan(cover1.center.dy));
    expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(0)).value, isFalse);
    expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value, isTrue);

    // 未选中态不描边（与既有卡片外观一致），选中态套 2px 主色环
    List<double> ringWidths() => tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.border is Border)
        .map((d) => (d.border! as Border).top.width)
        .toList();
    expect(ringWidths(), [0, 2]);
  });

  testWidgets('计数头与多选栏等高：进出多选模式内容区不跳动', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CountHeader(count: 12),
              SelectionBar(total: 12, selectedCount: 3),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final headerH = tester.getSize(find.byType(CountHeader)).height;
    final barH = tester.getSize(find.byType(SelectionBar)).height;
    expect(headerH, closeTo(kListHeaderHeight, 0.01));
    expect(barH, closeTo(headerH, 0.01));
  });

  testWidgets('UI1 内容页列表宽度上限：宽屏收窄到 80%（封顶 1500），窄屏退化为整宽',
      (tester) async {
    const probe = SizedBox(
          key: Key('probe'),
          width: double.infinity,
          height: 100,
        );
    Future<void> pump() => tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: ContentShell(child: probe),
            ),
          ),
        );

    // 宽屏 2000：80% = 1600 → 封顶 1500。
    tester.view.physicalSize = const Size(2000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pump();
    expect(tester.getSize(find.byKey(const Key('probe'))).width,
        closeTo(kContentMaxWidth, 0.5));

    // 中等屏 1200：80% = 960。
    tester.view.physicalSize = const Size(1200, 900);
    await pump();
    expect(tester.getSize(find.byKey(const Key('probe'))).width,
        closeTo(960, 0.5));

    // 窄屏 400：不足 500 下限，退化为整宽（不横向溢出）。
    tester.view.physicalSize = const Size(400, 800);
    await pump();
    expect(tester.getSize(find.byKey(const Key('probe'))).width,
        closeTo(400, 0.5));
  });
}
