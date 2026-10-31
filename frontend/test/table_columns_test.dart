import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/table_columns.dart';

const _columns = [
  TableColumnSpec(id: 'a', label: 'A', defaultWeight: 100, minWeight: 50),
  TableColumnSpec(id: 'b', label: 'B', defaultWeight: 100, minWeight: 50),
  TableColumnSpec(id: 'c', label: 'C', defaultWeight: 100, minWeight: 50),
];

void main() {
  test('默认权重 / 持久化清洗：列数不符或非法值回退默认', () {
    expect(defaultTableWeights(_columns), [100, 100, 100]);
    expect(sanitizeTableWeights(_columns, null), [100, 100, 100]);
    expect(sanitizeTableWeights(_columns, const [1, 2]), [100, 100, 100]);
    expect(sanitizeTableWeights(_columns, const [10, 200, double.nan]),
        [100, 100, 100]);
    // 低于下限的钳到下限。
    expect(sanitizeTableWeights(_columns, const [10, 200, 100]),
        [50, 200, 100]);
  });

  test('拖拽分隔线：像素位移按内容宽换算权重，相邻两列一增一减', () {
    const weights = [100.0, 100.0, 100.0];
    final next = resizeTableWeights(
      columns: _columns,
      weights: weights,
      dividerIndex: 0,
      deltaPixels: 30,
      contentWidth: 300,
    );
    expect(next, [130, 70, 100]);
    // 原列表不变
    expect(weights, [100, 100, 100]);
  });

  test('拖拽到下限：不可再缩时本次不动', () {
    final next = resizeTableWeights(
      columns: _columns,
      weights: const [100, 50, 150],
      dividerIndex: 0,
      deltaPixels: 100,
      contentWidth: 300,
    );
    expect(next, const [100, 50, 150]);
  });

  test('flex 权重放大 10 倍取整，最小 1', () {
    expect(tableColumnFlex(123), 1230);
    expect(tableColumnFlex(1.24), 12);
    expect(tableColumnFlex(0.01), 1);
  });
}
