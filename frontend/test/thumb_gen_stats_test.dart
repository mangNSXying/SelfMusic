import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/frame_baseline.dart';
import 'package:selfmusic/utils/thumb_gen_stats.dart';

/// `ThumbGenStats` 回归（ohos-thumb-taskpool US3 / T016）：聚合口径、可关闭
/// 开关、在飞峰值与场景关联 JSON 导出。
void main() {
  setUp(() {
    ThumbGenStats.reset();
    ThumbGenStats.enabled = true;
    ThumbGenStats.scenario = 'thumb-gen';
  });

  tearDown(() {
    ThumbGenStats.enabled = true;
  });

  test('聚合：成功/失败/超时计数与耗时 min-max-avg、原生样本', () {
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(
        ok: true,
        cost: const Duration(milliseconds: 10),
        nativeCostMs: 8);
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(ok: false, cost: const Duration(milliseconds: 30));
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(
        ok: false,
        cost: const Duration(milliseconds: 5000),
        timeout: true);

    final s = ThumbGenStats.snapshot();
    expect(s.attempted, 3);
    expect(s.ok, 1);
    expect(s.failed, 1);
    expect(s.timeout, 1);
    expect(s.minCostMs, 10);
    expect(s.maxCostMs, 5000);
    expect(s.avgCostMs, closeTo((10 + 30 + 5000) / 3, 0.001));
    expect(s.samples, 3);
    expect(s.nativeSamples, 1);
    expect(s.avgNativeCostMs, 8);
    expect(s.inflightPeak, 1);
  });

  test('在飞峰值：并发 markStart 记录峰值并在 end 回收', () {
    ThumbGenStats.markStart();
    ThumbGenStats.markStart();
    ThumbGenStats.markStart();
    expect(ThumbGenStats.inflight, 3);
    expect(ThumbGenStats.inflightPeak, 3);

    ThumbGenStats.markEnd(ok: true, cost: Duration.zero);
    expect(ThumbGenStats.inflight, 2);
    expect(ThumbGenStats.inflightPeak, 3);
  });

  test('批次计数：startBatch 累加', () {
    ThumbGenStats.startBatch();
    ThumbGenStats.startBatch();
    expect(ThumbGenStats.snapshot().batches, 2);
  });

  test('开关关闭：所有记录短路（零开销）', () {
    ThumbGenStats.enabled = false;
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(ok: true, cost: const Duration(milliseconds: 5));
    ThumbGenStats.startBatch();

    final s = ThumbGenStats.snapshot();
    expect(s.attempted, 0);
    expect(ThumbGenStats.inflight, 0);
    expect(s.batches, 0);
    expect(ThumbGenStats.inflightPeak, 0);
  });

  test('markAborted：仅回收在飞计数，不改变成败统计', () {
    ThumbGenStats.markStart();
    ThumbGenStats.markAborted();
    expect(ThumbGenStats.inflight, 0);
    expect(ThumbGenStats.snapshot().attempted, 0);
  });

  test('JSON 导出：含聚合字段与 scenario', () {
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(ok: true, cost: const Duration(milliseconds: 12));

    final decoded =
        jsonDecode(ThumbGenStats.exportJson()) as Map<String, dynamic>;
    expect(decoded['scenario'], 'thumb-gen');
    expect(decoded['attempted'], 1);
    expect(decoded['ok'], 1);
    expect(decoded['failed'], 0);
    expect(decoded['maxCostMs'], 12);
    expect(decoded['inflightPeak'], 1);
  });

  test('场景关联导出：ThumbGenStats 与 FrameBaseline 同 scenario 合并', () {
    ThumbGenStats.markStart();
    ThumbGenStats.markEnd(ok: true, cost: const Duration(milliseconds: 9));

    const frame = FrameBaseline(
      scenario: 'thumb-gen',
      missedFrames: 1,
      totalFrames: 200,
      maxFrameTime: Duration(milliseconds: 20),
    );
    final out = ThumbGenStats.exportScenario(frame: frame);
    expect(out['scenario'], 'thumb-gen');
    expect((out['thumbGen'] as Map)['attempted'], 1);
    expect((out['frame'] as Map)['scenario'], 'thumb-gen');
    expect((out['frame'] as Map)['missedFrames'], 1);
  });
}
