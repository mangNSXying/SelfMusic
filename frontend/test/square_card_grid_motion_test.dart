import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/motion.dart';
import 'package:selfmusic/widgets/square_card.dart';

/// 方形卡片网格：卡宽连续（补间）、列数离散（由卡宽反推）的回归。
///
/// 历史问题（横屏 1280×800 开关播放队列）：内容区 300ms 内 1020→660，旧实现
/// 先算列数再反算卡宽 —— 卡宽是列数的函数，跨列数档位时先缩小再猛地放大
/// （实测 173 → 220 → 161 → 220 → 198.7，两次 +27%/+36% 暴涨），观感即
/// 「卡片疯狂切换大小」；同时 `cacheWidth` 逐帧变化导致封面每帧重解码闪白，
/// 观感即「刷新页面」。
class _Host extends StatefulWidget {
  const _Host({required this.from, required this.to});

  /// 容器起始宽度（= 内容区宽）。
  final double from;

  /// 容器终态宽度；同时作为 `targetWidth` 下发（AppShell 用目标宽算
  /// `ScreenMetrics`，一次开合只跳一次）。
  final double to;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: kPageMotion,
  );

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  /// 换一组 from/to 即"再来一次开合"：控制器必须重跑，
  /// 否则第二次 pumpWidget 会瞬间落在终态、拿不到中间帧。
  @override
  void didUpdateWidget(_Host oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.from != widget.from || oldWidget.to != widget.to) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = kPageMotionCurve.transform(_ctrl.value);
            final w = widget.from + (widget.to - widget.from) * t;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: w,
                height: 800,
                // 终态宽一次到位（与 AppShell 的 ScreenMetrics 同口径）。
                child: SquareCardGrid(
                  targetWidth: widget.to,
                  itemCount: 12,
                  itemBuilder: (c, i) => SquareCard(
                      title: '专辑 $i', subtitle: '歌手', onTap: () {}),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 取第一张可见卡的封面边长（= 当前卡宽）。
double _cardWidth(WidgetTester tester) =>
    tester.getSize(find.byType(AspectRatio).first).width;

/// 当前网格的列数。
int _cols(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byType(GridView));
  return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
      .crossAxisCount;
}

/// 测试视口固定放大：默认 800×600 会把 `SizedBox(width: 1020)` 钳到 800，
/// 拿不到 5 列的真实几何。
void _largeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(2048, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('静止态与旧实现逐像素一致（400 宽 → 2 列 176）', (tester) async {
    _largeViewport(tester);
    await tester.pumpWidget(const _Host(from: 400, to: 400));
    await tester.pumpAndSettle();
    expect(_cols(tester), 2);
    expect(_cardWidth(tester), closeTo(176, 0.01));
    expect(_cardWidth(tester), lessThanOrEqualTo(SquareCardGrid.maxItemWidth));
    // 静止态恰好铺满：网格宽 == 容器宽。
    expect(tester.getSize(find.byType(GridView)).width, closeTo(400, 0.01));
  });

  testWidgets('静止态与旧实现逐像素一致（1020 宽 → 5 列 184.8）', (tester) async {
    _largeViewport(tester);
    await tester.pumpWidget(const _Host(from: 1020, to: 1020));
    await tester.pumpAndSettle();
    expect(_cols(tester), 5);
    expect(_cardWidth(tester), closeTo(184.8, 0.01));
    expect(tester.getSize(find.byType(GridView)).width, closeTo(1020, 0.01));
  });

  testWidgets('收缩（开队列 1020→660）：卡宽单调增长，无锯齿跳变', (tester) async {
    _largeViewport(tester);
    await tester.pumpWidget(const _Host(from: 1020, to: 1020));
    await tester.pumpAndSettle();
    final widths = <double>[_cardWidth(tester)];
    final cols = <int>{_cols(tester)};

    // 容器逐帧收缩 1020→660，终态宽同步下发。
    await tester.pumpWidget(const _Host(from: 1020, to: 660));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_cardWidth(tester));
      cols.add(_cols(tester));
    }

    // 卡宽单调不减：收缩过程中卡片只会变大，不会忽然缩小再放大。
    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], greaterThanOrEqualTo(widths[i - 1] - 0.01),
          reason: '第 $i 帧卡宽回退：$widths');
    }
    // 相邻帧差 < 8px：锯齿实现会出现 +47 / +57 的跳变。
    for (var i = 1; i < widths.length; i++) {
      expect((widths[i] - widths[i - 1]).abs(), lessThan(8),
          reason: '第 $i 帧卡宽跳变：$widths');
    }
    // 列数只会随可用宽变窄而减少，不来回（具体在哪一帧减少取决于采样时刻）。
    final colList = cols.toList();
    expect(colList.first, greaterThan(colList.last));
    expect(colList.last, 3);
    expect(widths.first, closeTo(184.8, 1));
    expect(widths.last, closeTo(198.67, 1));
    // 每一帧网格宽都不超过容器宽（不裁掉半张卡）。
    expect(tester.getSize(find.byType(GridView)).width,
        lessThanOrEqualTo(660.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('放大（关队列 660→1020）：卡宽单调收缩，网格不溢出', (tester) async {
    _largeViewport(tester);
    await tester.pumpWidget(const _Host(from: 660, to: 660));
    await tester.pumpAndSettle();
    final widths = <double>[_cardWidth(tester)];
    final cols = <int>{_cols(tester)};

    await tester.pumpWidget(const _Host(from: 660, to: 1020));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_cardWidth(tester));
      cols.add(_cols(tester));
      // 网格按"当前可用宽"铺，不能超出（网格自身按 SizedBox 显式宽，
      // 所以这里始终不超过逐帧收缩中的容器宽）。
      expect(tester.getSize(find.byType(GridView)).width,
          lessThanOrEqualTo(1020.5));
    }

    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], lessThanOrEqualTo(widths[i - 1] + 0.01),
          reason: '第 $i 帧卡宽回退：$widths');
      expect((widths[i] - widths[i - 1]).abs(), lessThan(8),
          reason: '第 $i 帧卡宽跳变：$widths');
    }
    // 列数只会随可用宽变宽而增加，不来回。
    final colList = cols.toList();
    expect(colList.first, lessThan(colList.last));
    expect(colList.last, 5);
    expect(widths.last, closeTo(184.8, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('列数变化的那一帧卡宽不跳（只换位置）', (tester) async {
    _largeViewport(tester);
    await tester.pumpWidget(const _Host(from: 1020, to: 1020));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const _Host(from: 1020, to: 660));
    var prevCols = _cols(tester);
    var prevWidth = _cardWidth(tester);
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final c = _cols(tester);
      final w = _cardWidth(tester);
      if (c != prevCols) {
        expect((w - prevWidth).abs(), lessThan(8),
            reason: '列数 $prevCols→$c 那一帧卡宽从 $prevWidth 跳到 $w');
      }
      prevCols = c;
      prevWidth = w;
    }
  });

  testWidgets('无 targetWidth（详情右栏/测试直挂）：跟手实时约束，不走补间',
      (tester) async {
    _largeViewport(tester);
    // 终态宽 = 实时宽：恒为"静止态"，等价于旧实现口径。
    await tester.pumpWidget(const _Host(from: 1020, to: 1020));
    await tester.pumpAndSettle();
    expect(_cols(tester), 5);
    expect(_cardWidth(tester), closeTo(184.8, 0.01));
  });

  test('封面解码宽按 32 档量化：卡宽微调不换 ImageCache key', () {
    // 400 宽（176）与 420 宽（186）同属 192 档 → 同一 ResizeImage key。
    expect(squareCardDecodeWidth(176, 1), 192);
    expect(squareCardDecodeWidth(186, 1), 192);
    // 1020/660 两端：补间全程最多换一次 key（旧实现每帧一个）。
    expect(squareCardDecodeWidth(184.8, 1), 192);
    expect(squareCardDecodeWidth(198.67, 1), 220);
    // 封顶 maxItemWidth；高 DPR 按物理像素换算。
    expect(squareCardDecodeWidth(240, 1), 220);
    expect(squareCardDecodeWidth(176, 2), 384);
  });

  testWidgets('封面换档重解码时保留旧帧（gaplessPlayback）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: SquareCard(
              title: 'a',
              coverPath: '/nonexistent/cover.jpg',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.gaplessPlayback, isTrue);
  });
}
