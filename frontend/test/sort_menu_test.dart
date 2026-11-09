import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/collection_sort.dart';
import 'package:selfmusic/widgets/sort_menu_button.dart';

/// 取某个箭头所在圆形容器的背景色（判断是否处于强调态）。
Color? _bgOf(WidgetTester tester, Finder arrow) {
  final box = tester.widget<Container>(
    find.ancestor(of: arrow, matching: find.byType(Container)).first,
  );
  return (box.decoration! as BoxDecoration).color;
}

/// 排序菜单：每行「字段名 + 单方向按钮」，点字段名/按钮都按
/// 升序 → 降序 → 默认 循环（与表头列头同口径）。
void main() {
  Future<void> openMenu(WidgetTester tester,
      {required CollectionSort value,
      SortScope scope = SortScope.songs,
      required ValueChanged<CollectionSort> onChanged}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: value,
            scope: scope,
            onChanged: onChanged,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
  }

  testWidgets('弹层贴着按钮右边缘（两种字段范围都不再偏左）', (tester) async {
    for (final scope in SortScope.values) {
      await openMenu(tester,
          value: CollectionSort.defaultOrder, scope: scope, onChanged: (_) {});
      final button = tester.getRect(find.byType(IconButton));
      final item =
          tester.getRect(find.byType(PopupMenuItem<CollectionSort>).first);
      // 按钮贴着窗口右边：菜单右边缘只让出 showMenu 的 8px 屏幕边距。
      expect(item.right, closeTo(button.right - 8, 1.0),
          reason: '$scope 菜单右边缘应与按钮右边缘对齐（不再内缩一截）');
      await tester.tapAt(const Offset(2, 400));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('歌曲页弹窗列出字符/歌手/专辑/权重/播放时长/播放次数/时长，无曲数', (tester) async {
    await openMenu(tester, value: CollectionSort.defaultOrder, onChanged: (_) {});
    for (final label in ['默认排序', '字符', '歌手', '专辑', '权重', '播放时长', '播放次数', '时长']) {
      expect(find.text(label), findsOneWidget, reason: '缺字段 $label');
    }
    expect(find.text('曲数'), findsNothing);
  });

  testWidgets('集合页弹窗只有字符与曲数', (tester) async {
    await openMenu(tester,
        value: CollectionSort.defaultOrder,
        scope: SortScope.collections,
        onChanged: (_) {});
    expect(find.text('字符'), findsOneWidget);
    expect(find.text('曲数'), findsOneWidget);
    expect(find.text('权重'), findsNothing);
    expect(find.text('播放时长'), findsNothing);
  });

  testWidgets('默认状态点方向按钮 → 该字段升序', (tester) async {
    CollectionSort? picked;
    await openMenu(tester,
        value: CollectionSort.defaultOrder, onChanged: (v) => picked = v);
    // 默认排序行无按钮；其余 7 行各一个升序箭头。
    final up = find.byIcon(Icons.arrow_upward);
    expect(up, findsNWidgets(7));
    // 「播放时长」是第 5 个字段（下标 4）。
    await tester.tap(up.at(4));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.playTimeAsc);
  });

  testWidgets('当前升序 → 再点变降序', (tester) async {
    CollectionSort? picked;
    await openMenu(tester,
        value: CollectionSort.charAsc, onChanged: (v) => picked = v);
    expect(find.byTooltip('切换为降序'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward).first);
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.charDesc);
  });

  testWidgets('当前降序 → 再点回默认排序', (tester) async {
    CollectionSort? picked;
    await openMenu(tester,
        value: CollectionSort.charDesc, onChanged: (v) => picked = v);
    expect(find.byTooltip('恢复默认排序'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.defaultOrder);
  });

  testWidgets('点字段名与方向按钮同一循环；换字段从升序开始', (tester) async {
    CollectionSort? picked;
    await openMenu(tester,
        value: CollectionSort.charAsc, onChanged: (v) => picked = v);
    await tester.tap(find.text('字符'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.charDesc);

    // 换一个字段「播放次数」→ 第一次点击落升序。
    picked = null;
    await openMenu(tester,
        value: CollectionSort.charDesc, onChanged: (v) => picked = v);
    await tester.tap(find.text('播放次数'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.playCountAsc);
  });

  testWidgets('点默认排序 → 回默认', (tester) async {
    CollectionSort? picked;
    await openMenu(tester,
        value: CollectionSort.countAsc,
        scope: SortScope.collections,
        onChanged: (v) => picked = v);
    await tester.tap(find.text('默认排序'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.defaultOrder);
  });

  testWidgets('当前字段+方向用强调色标出（每行只有一个方向按钮）', (tester) async {
    await openMenu(tester, value: CollectionSort.playCountDesc, onChanged: (_) {});
    final scheme =
        Theme.of(tester.element(find.text('播放次数'))).colorScheme;

    // 只有生效的「播放次数」显示降序箭头，其余字段都是升序箭头。
    final down = find.byIcon(Icons.arrow_downward);
    expect(down, findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNWidgets(6));
    expect(_bgOf(tester, down), scheme.primaryContainer);
    expect(tester.widget<Icon>(down).color, scheme.onPrimaryContainer);

    // 未生效字段（字符）的箭头为透明背景 + 淡化。
    final up = find.byIcon(Icons.arrow_upward).first;
    expect(_bgOf(tester, up), Colors.transparent);
  });
}
