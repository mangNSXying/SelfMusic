import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/weight_curve.dart';

void main() {
  group('WeightCurve 时长削弱（改进.txt 功能8）', () {
    WeightCurve build(List<Map<String, Object?>> segs, {bool enabled = true}) =>
        WeightCurve.fromSettings(enabled, segs);

    test('命中区间返回对应系数；作用域为 [min, max) 左闭右开', () {
      final c = build(const [
        {'min_sec': 240.0, 'max_sec': 600.0, 'factor': 0.8},
        {'min_sec': 600.0, 'max_sec': null, 'factor': 0.6},
      ]);
      expect(c.multiplierFor(120), 1.0); // 未命中
      expect(c.multiplierFor(240), 0.8); // 区间左闭
      expect(c.multiplierFor(599), 0.8);
      expect(c.multiplierFor(600), 0.6); // 移交下一段
      expect(c.multiplierFor(3600), 0.6); // 无上限段生效
    });

    test('未开启 / 时长未知（null/0）/ 空配置 → 1.0（不削弱）', () {
      expect(build(const [], enabled: true).multiplierFor(300), 1.0);
      expect(build(const [
        {'min_sec': 240.0, 'max_sec': null, 'factor': 0.5},
      ], enabled: false).multiplierFor(300), 1.0);
      expect(build(const [
        {'min_sec': 240.0, 'max_sec': null, 'factor': 0.5},
      ]).multiplierFor(null), 1.0);
      expect(build(const [
        {'min_sec': 240.0, 'max_sec': null, 'factor': 0.5},
      ]).multiplierFor(0), 1.0);
    });

    test('factor 越界被钳回 [0.5, 1.5]', () {
      final c = build(const [
        {'min_sec': 10.0, 'max_sec': 100.0, 'factor': 2.0},
        {'min_sec': 100.0, 'max_sec': null, 'factor': 0.2},
      ]);
      expect(c.multiplierFor(10), 1.5);
      expect(c.multiplierFor(100), 0.5);
    });

    test('乱序分段按起始时长升序；非法片段静默丢弃', () {
      final c = build(const [
        {'min_sec': 200.0, 'max_sec': null, 'factor': 0.9}, // 后置
        {'min_sec': 0.0, 'max_sec': null, 'factor': 0.7}, // min<=0 非法
        {'min_sec': 500.0, 'max_sec': 400.0, 'factor': 0.7}, // max<=min 非法
        {'min_sec': 100.0, 'max_sec': 200.0, 'factor': 0.0}, // factor<=0 非法
        {'min_sec': 100.0, 'max_sec': 200.0, 'factor': 0.8},
      ]);
      expect(c.multiplierFor(100), 0.8);
      expect(c.multiplierFor(250), 0.9);
    });
  });
}