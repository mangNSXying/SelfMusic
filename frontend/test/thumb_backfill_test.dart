import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';

/// 回填调度回归（ohos-thumb-taskpool US2 / T012）：`runThumbBackfill` 的有界
/// 并发、同目标去重、交互期让位与幂等续跑，全部用注入的确定性 [runThumbBackfill.sleep]
/// 驱动，不依赖真实时钟与真机。
void main() {
  test('同目标去重：重复封面路径只生成一次（保留首现顺序）', () async {
    final calls = <String>[];
    final made = await runThumbBackfill(
      covers: ['a', 'b', 'a', 'c', 'b'],
      generate: (c) async {
        calls.add(c);
        return true;
      },
      isInteracting: () => false,
      maxInflight: 4,
      sleep: (_) async {},
    );
    expect(calls, ['a', 'b', 'c']);
    expect(made, 3);
  });

  test('有界并发：单批内在飞数不超过 maxInflight', () async {
    var inflight = 0;
    var peak = 0;
    final made = await runThumbBackfill(
      covers: List<String>.generate(20, (i) => 'c$i'),
      generate: (c) async {
        inflight++;
        if (inflight > peak) peak = inflight;
        await Future<void>.delayed(Duration.zero);
        inflight--;
        return true;
      },
      isInteracting: () => false,
      maxInflight: 2,
      batchSize: 100,
      sleep: (_) async {},
    );
    expect(peak, lessThanOrEqualTo(2));
    expect(peak, greaterThan(0));
    expect(made, 20);
  });

  test('交互期让位：交互中不派发新批，交互结束后续跑并最终一致', () async {
    var interacting = true;
    final calls = <String>[];
    var slept = 0;
    final made = await runThumbBackfill(
      covers: ['a', 'b', 'c'],
      generate: (c) async {
        // 交互一旦结束就应放行；此处断言生成时已不在交互期。
        expect(interacting, isFalse);
        calls.add(c);
        return true;
      },
      isInteracting: () => interacting,
      maxInflight: 2,
      batchSize: 1,
      interactionWaitStep: const Duration(milliseconds: 1),
      sleep: (_) async {
        slept++;
        if (slept >= 2) interacting = false;
      },
    );
    expect(calls, ['a', 'b', 'c']);
    expect(made, 3);
    expect(slept, greaterThanOrEqualTo(2));
  });

  test('幂等续跑 + 失败不计入 made：单张失败不中断后续', () async {
    final made = await runThumbBackfill(
      covers: ['a', 'b', 'c', 'd'],
      generate: (c) async => c != 'b',
      isInteracting: () => false,
      maxInflight: 2,
      batchSize: 2,
      sleep: (_) async {},
    );
    expect(made, 3); // 仅 b 失败。

    // 重复调用结果一致（幂等）：同一批再次全成功 → made=4。
    final again = await runThumbBackfill(
      covers: ['a', 'b', 'c', 'd'],
      generate: (c) async => true,
      isInteracting: () => false,
      maxInflight: 2,
      batchSize: 2,
      sleep: (_) async {},
    );
    expect(again, 4);
  });

  test('空清单：直接返回 0，不调用 generate', () async {
    var called = false;
    final made = await runThumbBackfill(
      covers: const [],
      generate: (c) async {
        called = true;
        return true;
      },
      isInteracting: () => false,
      sleep: (_) async {},
    );
    expect(made, 0);
    expect(called, isFalse);
  });
}
