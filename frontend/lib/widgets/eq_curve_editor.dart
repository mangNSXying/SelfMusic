import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/equalizer/equalizer_types.dart';

/// 均衡器频响曲线编辑器：对数频率轴 + 10 个固定频段节点，上下拖动调增益。
///
/// 节点横坐标固定为标准中心频率，避免任意曲线在 Android 原生 EQ 上无法精确
/// 还原；曲线本身按节点平滑插值，只作为直观的手柄。
class EqCurveEditor extends StatefulWidget {
  const EqCurveEditor({
    super.key,
    required this.gains,
    required this.onChanged,
    this.onCommit,
    this.height = 200,
  });

  final List<double> gains;
  final void Function(int index, double db) onChanged;
  final VoidCallback? onCommit;
  final double height;

  @override
  State<EqCurveEditor> createState() => _EqCurveEditorState();
}

class _EqCurveEditorState extends State<EqCurveEditor> {
  int? _selected;

  void _update(Size size, Offset local) {
    final plot = EqCurveGeometry.plotRect(size);
    final dx = local.dx.clamp(plot.left, plot.right).toDouble();
    final dy = local.dy.clamp(plot.top, plot.bottom).toDouble();
    final index = EqCurveGeometry.nearestBandIndex(dx, size);
    final db = EqCurveGeometry.gainForY(dy, size);
    if (index == null) return;
    setState(() => _selected = index);
    widget.onChanged(index, db);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _update(size, d.localPosition),
            onPanStart: (d) => _update(size, d.localPosition),
            onPanUpdate: (d) => _update(size, d.localPosition),
            onPanEnd: (_) => widget.onCommit?.call(),
            onTapUp: (_) => widget.onCommit?.call(),
            child: CustomPaint(
              size: size,
              painter: _EqCurvePainter(
                gains: widget.gains,
                selected: _selected,
                accent: cs.primary,
                grid: cs.outlineVariant,
                text: cs.onSurfaceVariant,
                background: cs.surfaceContainerHighest.withValues(alpha: 0.28),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 曲线几何（独立出来便于单测与手势/绘制共用同一套坐标）。
class EqCurveGeometry {
  static const double leftPad = 34;
  static const double rightPad = 12;
  static const double topPad = 12;
  static const double bottomPad = 26;
  static const double minFrequency = 20;
  static const double maxFrequency = 20000;

  static Rect plotRect(Size size) => Rect.fromLTRB(
        leftPad,
        topPad,
        math.max(leftPad + 1, size.width - rightPad),
        math.max(topPad + 1, size.height - bottomPad),
      );

  static double xForFrequency(double freq, Size size) {
    final plot = plotRect(size);
    final t = (math.log(freq.clamp(minFrequency, maxFrequency)) -
            math.log(minFrequency)) /
        (math.log(maxFrequency) - math.log(minFrequency));
    return plot.left + t * plot.width;
  }

  static double gainForY(double y, Size size) {
    final plot = plotRect(size);
    final t = ((y - plot.top) / plot.height).clamp(0.0, 1.0);
    return (kEqMaxDb - t * (kEqMaxDb - kEqMinDb)).toDouble();
  }

  static double yForGain(double db, Size size) {
    final plot = plotRect(size);
    final t = ((kEqMaxDb - db) / (kEqMaxDb - kEqMinDb)).clamp(0.0, 1.0);
    return plot.top + t * plot.height;
  }

  static int? nearestBandIndex(double dx, Size size) {
    if (size.width <= leftPad + rightPad) return null;
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < kEqFrequencies.length; i++) {
      final x = xForFrequency(kEqFrequencies[i], size);
      final d = (x - dx).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  static Offset pointFor(int index, double gain, Size size) => Offset(
        xForFrequency(kEqFrequencies[index], size),
        yForGain(gain, size),
      );
}

class _EqCurvePainter extends CustomPainter {
  _EqCurvePainter({
    required this.gains,
    required this.selected,
    required this.accent,
    required this.grid,
    required this.text,
    required this.background,
  });

  final List<double> gains;
  final int? selected;
  final Color accent;
  final Color grid;
  final Color text;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = EqCurveGeometry.plotRect(size);
    final bgPaint = Paint()..color = background;
    final rrect = RRect.fromRectAndRadius(plot, const Radius.circular(12));
    canvas.drawRRect(rrect, bgPaint);

    _drawGrid(canvas, size, plot);
    _drawCurve(canvas, size, plot);
    _drawLabels(canvas, size, plot);
  }

  void _drawGrid(Canvas canvas, Size size, Rect plot) {
    final paint = Paint()
      ..color = grid.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (final db in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      final y = EqCurveGeometry.yForGain(db, size);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          db == 0 ? (paint..strokeWidth = 1.4) : paint);
      paint.strokeWidth = 1;
    }
    for (var i = 0; i < kEqFrequencies.length; i++) {
      final x = EqCurveGeometry.xForFrequency(kEqFrequencies[i], size);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), paint);
    }
  }

  void _drawCurve(Canvas canvas, Size size, Rect plot) {
    final points = <Offset>[
      for (var i = 0; i < kEqFrequencies.length; i++)
        EqCurveGeometry.pointFor(
          i,
          i < gains.length ? gains[i] : 0,
          size,
        ),
    ];
    if (points.isEmpty) return;

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final midX = (prev.dx + curr.dx) / 2;
      line.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
    }

    final fill = Path.from(line)
      ..lineTo(points.last.dx, plot.bottom)
      ..lineTo(points.first.dx, plot.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.28),
            accent.withValues(alpha: 0.02),
          ],
        ).createShader(plot),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );

    for (var i = 0; i < points.length; i++) {
      final isSelected = selected == i;
      canvas.drawCircle(
        points[i],
        isSelected ? 6 : 4.2,
        Paint()..color = accent,
      );
      canvas.drawCircle(
        points[i],
        isSelected ? 3 : 2,
        Paint()..color = Colors.white,
      );
    }
  }

  void _drawLabels(Canvas canvas, Size size, Rect plot) {
    for (final entry in const [(-12.0, '-12'), (0.0, '0'), (12.0, '+12')]) {
      final y = EqCurveGeometry.yForGain(entry.$1, size);
      _text(
        canvas,
        entry.$2,
        Offset(plot.left - 6, y),
        alignRight: true,
        anchorMiddle: true,
      );
    }
    for (final i in const [0, 2, 5, 7, 9]) {
      final x = EqCurveGeometry.xForFrequency(kEqFrequencies[i], size);
      _text(
        canvas,
        kEqFrequencyLabels[i],
        Offset(x, plot.bottom + 7),
        anchorMiddle: true,
      );
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset offset, {
    bool alignRight = false,
    bool anchorMiddle = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: 10, color: text),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = offset.dx;
    if (alignRight) dx -= painter.width;
    if (anchorMiddle) dx -= painter.width / 2;
    var dy = offset.dy;
    if (anchorMiddle) dy -= painter.height / 2;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) =>
      !listEquals(gains, oldDelegate.gains) ||
      selected != oldDelegate.selected ||
      accent != oldDelegate.accent ||
      grid != oldDelegate.grid ||
      text != oldDelegate.text ||
      background != oldDelegate.background;
}
