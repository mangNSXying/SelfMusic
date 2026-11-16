import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/draggable_sheet.dart';

/// 关闭通道回归：路由版统一拖拽窗口（专辑/歌手歌曲弹层）只能 pop 一次。
///
/// 拖拽条滑到 `minChildSize` 时框架会自动 pop；标题栏下甩、关闭按钮或残留的
/// 手势收尾若再 pop 一次，就会把底层页面（首页）一并弹掉，只剩空 Navigator，
/// 表现为整屏变黑。
void main() {
  testWidgets('弹层滑到下限只关闭一次，底层页面保留', (tester) async {
    final (pops, sheetCtx) = await _pumpApp(tester);
    await _openSheet(tester);

    final handle = find.byKey(const ValueKey('app_sheet_handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pops.length, 1, reason: '下限关闭只允许 pop 一次');
    expect(find.text('HOME'), findsOneWidget, reason: '底层首页不能被弹掉');
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(sheetCtx.currentContext, isNull, reason: '弹层子树已卸载');
  });

  testWidgets('关闭动画期间再次请求关闭不会弹掉首页（黑屏回归）', (tester) async {
    final (pops, sheetCtx) = await _pumpApp(tester);
    await _openSheet(tester);

    // 滑到下限：此时弹层已进入退场动画（路由已 pop，子树仍在树上）。
    final handle = find.byKey(const ValueKey('app_sheet_handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 30 && pops.isEmpty; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(pops.length, 1, reason: '滑到下限应触发关闭');

    // 模拟同一段手势里第二路关闭（标题栏下甩收尾 / 关闭按钮 / 残留通知）：
    // 关闭必须幂等，不能再 pop 掉首页。
    final ctx = sheetCtx.currentContext;
    expect(ctx, isNotNull, reason: '退场动画期间弹层子树仍在');
    AppSheetScope.closeOf(ctx!);
    AppSheetScope.closeOf(ctx);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pops.length, 1, reason: '重复关闭请求不能产生第二次 pop');
    expect(find.text('HOME'), findsOneWidget, reason: '底层首页不能被弹掉');
  });

  testWidgets('从列表下拉到下限关闭也只 pop 一次', (tester) async {
    final (pops, _) = await _pumpApp(tester);
    await _openSheet(tester);

    // 列表在顶部时继续下拉由 DraggableScrollableSheet 改窗口高度，到下限收起。
    final gesture = await tester.startGesture(tester.getCenter(find.text('行 1')));
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pops.length, 1, reason: '列表下拉到下限只允许 pop 一次');
    expect(find.text('HOME'), findsOneWidget, reason: '底层首页不能被弹掉');
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });

  testWidgets('未到下限时标题栏松手关闭也只 pop 一次', (tester) async {
    final (pops, _) = await _pumpApp(tester);
    await _openSheet(tester);

    await tester.fling(
        find.byKey(const ValueKey('app_sheet_handle')), const Offset(0, 80),
        1500);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pops.length, 1);
    expect(find.text('HOME'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('app_sheet_handle')), findsOneWidget);
}

/// 简化版主页 + 统一拖拽窗口：首页文案 HOME 用于断言底层路由仍在。
Future<(_PopLog, GlobalKey)> _pumpApp(WidgetTester tester) async {
  final pops = _PopLog();
  final sheetCtx = GlobalKey(debugLabel: 'sheetContent');
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [pops],
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('HOME'),
              ElevatedButton(
                onPressed: () => showAppDraggableSheet<void>(
                  context,
                  builder: (c, scrollCtrl) => Builder(
                    key: sheetCtx,
                    // 这里的 context 位于 AppSheetScope 之下：heightOf 才能算上
                    // 拖拽把手的占位（否则标题栏固定高会少 12px 而溢出）。
                    builder: (sheetContext) => CustomScrollView(
                      controller: scrollCtrl,
                      slivers: [
                        AppSheetHeader(
                          height: AppSheetTitleBar.heightOf(sheetContext),
                          child: AppSheetTitleBar(
                            title: '测试弹层',
                            count: 3,
                            scrollCtrl: scrollCtrl,
                          ),
                        ),
                        SliverList.list(children: [
                          for (var i = 0; i < 20; i++)
                            SizedBox(height: 48, child: Text('行 $i')),
                        ]),
                      ],
                    ),
                  ),
                ),
                child: const Text('OPEN'),
              ),
            ],
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (pops, sheetCtx);
}

class _PopLog extends NavigatorObserver {
  final List<Route<dynamic>> _popped = [];

  int get length => _popped.length;

  bool get isEmpty => _popped.isEmpty;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popped.add(route);
    super.didPop(route, previousRoute);
  }
}
