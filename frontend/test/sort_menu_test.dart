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

/// 排序菜单：两行合一（字段名 + 行内升降箭头），点箭头选方向、点字段名翻方向
/// （改进.txt）。
void main() {
  Future<CollectionSort?> openMenu(WidgetTester tester,
      {required CollectionSort value, SortScope scope = SortScope.songs}) async {
    CollectionSort? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: value,
            scope: scope,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('歌曲页弹窗列出权重/播放时长/播放次数/时长，无曲数', (tester) async {
    await openMenu(tester, value: CollectionSort.defaultOrder);
    for (final label in ['默认排序', '字符', '权重', '播放时长', '播放次数', '时长']) {
      expect(find.text(label), findsOneWidget, reason: '缺字段 $label');
    }
    expect(find.text('曲数'), findsNothing);
  });

  testWidgets('集合页弹窗只有字符与曲数', (tester) async {
    await openMenu(tester,
        value: CollectionSort.defaultOrder, scope: SortScope.collections);
    expect(find.text('字符'), findsOneWidget);
    expect(find.text('曲数'), findsOneWidget);
    expect(find.text('权重'), findsNothing);
    expect(find.text('播放时长'), findsNothing);
  });

  testWidgets('点向下箭头 → 该字段降序', (tester) async {
    CollectionSort? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.defaultOrder,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    // 「播放时长」行的向下箭头：字符/权重/播放时长/播放次数/时长 → 第 3 个
    final down = find.byIcon(Icons.arrow_downward);
    expect(down, findsNWidgets(5));
    await tester.tap(down.at(2));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.playTimeDesc);
  });

  testWidgets('点向上箭头 → 该字段升序', (tester) async {
    CollectionSort? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.charDesc,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    // 「字符」行的向上箭头（默认排序无箭头）
    await tester.tap(find.byIcon(Icons.arrow_upward).first);
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.charAsc);
  });

  testWidgets('点字段名 → 该字段翻方向；非当前字段先落降序', (tester) async {
    CollectionSort? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.charAsc,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    // 当前字段「字符」→ 翻成降序
    await tester.tap(find.text('字符'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.charDesc);

    // 换一个字段「播放次数」→ 第一次点击落降序
    picked = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.charDesc,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放次数'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.playCountDesc);
  });

  testWidgets('点默认排序 → 回默认', (tester) async {
    CollectionSort? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.countAsc,
            scope: SortScope.collections,
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('默认排序'));
    await tester.pumpAndSettle();
    expect(picked, CollectionSort.defaultOrder);
  });

  testWidgets('当前字段+方向用强调色标出（其余淡化）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SortMenuButton(
            value: CollectionSort.playCountDesc,
            onChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    final scheme =
        Theme.of(tester.element(find.text('播放次数'))).colorScheme;

    final downs = find.byIcon(Icons.arrow_downward);
    expect(downs, findsNWidgets(5));
    Color colorAt(int i) => tester.widget<Icon>(downs.at(i)).color!;
    // 播放次数（第 4 个）向下 = 生效方向：强调背景 + onPrimaryContainer
    expect(_bgOf(tester, downs.at(3)), scheme.primaryContainer);
    expect(colorAt(3), scheme.onPrimaryContainer);
    // 播放次数向上（未生效）：透明背景 + 淡化
    expect(_bgOf(tester, find.byIcon(Icons.arrow_upward).at(3)),
        Colors.transparent);
    // 其它字段的向下箭头均为未生效态
    expect(_bgOf(tester, downs.at(0)), Colors.transparent);
    expect(_bgOf(tester, downs.at(4)), Colors.transparent);
  });
}
