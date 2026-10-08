import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/chunked_scheduler.dart';

void main() {
  test('runChunked 覆盖全部下标且按 chunkSize 分片让出', () async {
    final seen = <int>[];
    var yields = 0;
    Future<void> tick() async {
      yields++;
    }

    await runChunked(
      length: 10,
      chunkSize: 4,
      process: seen.add,
      yieldTo: tick,
    );

    expect(seen, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    // 10 项 / 每片 4：3 片 → 片间让出 2 次（末片后不再让出）。
    expect(yields, 2);
  });

  test('length<=0 或空任务不抛出、不让出', () async {
    var yields = 0;
    await runChunked(
      length: 0,
      process: (_) => fail('不应处理任何下标'),
      yieldTo: () async => yields++,
    );
    expect(yields, 0);
  });

  test('分片间异常向上传播（可中断）', () async {
    final seen = <int>[];
    await expectLater(
      runChunked(
        length: 8,
        chunkSize: 2,
        process: (i) {
          if (i == 3) throw StateError('stop');
          seen.add(i);
        },
        yieldTo: () async {},
      ),
      throwsStateError,
    );
    expect(seen, [0, 1, 2]);
  });

  test('ChunkToken 取消后停止后续处理（已处理部分不回滚）', () async {
    final token = ChunkToken();
    final seen = <int>[];
    await runChunkedCancellable(
      token: token,
      length: 8,
      chunkSize: 1,
      process: (i) {
        seen.add(i);
        if (i == 2) token.cancel();
      },
      yieldTo: () async {},
    );
    expect(seen, [0, 1, 2]);
  });
}
