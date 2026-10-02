import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/providers/direct_task_queue.dart';

/// 直连补读的优先级队列。
///
/// 用户定的顺序：当前曲元数据/封面 → 下一首音频（预载）→ 下一首元数据/封面 →
/// 全库后台补读。原来这些是各跑各的（播放器并发补当前曲、main 并发预载下一首、
/// manager 自己循环全库），弱网下三条链路互相抢连接，谁先补完全看运气。

/// 记录执行顺序的任务登记器。
class _Log {
  final List<String> order = [];
  int concurrent = 0;
  int maxConcurrent = 0;

  Future<void> run(String name) async {
    order.add(name);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    await Future<void>.delayed(Duration.zero);
    concurrent--;
  }
}

void main() {
  test('按优先级执行：当前曲 → 下一首音频 → 下一首元数据 → 全库', () async {
    final q = DirectTaskQueue();
    final log = _Log();

    // 故意倒着提交：全库先到（它是批量任务，一次排一百个），当前曲最后到。
    for (var i = 0; i < 3; i++) {
      q.submit(DirectTaskPriority.background,
          key: 'bg$i', body: () => log.run('bg$i'));
    }
    q.submit(DirectTaskPriority.nextMeta, key: 'nextM', body: () => log.run('nextM'));
    q.submit(DirectTaskPriority.nextAudio, key: 'nextA', body: () => log.run('nextA'));
    q.submit(DirectTaskPriority.currentMeta, key: 'cur', body: () => log.run('cur'));

    await q.idle();
    expect(log.order, ['cur', 'nextA', 'nextM', 'bg0', 'bg1', 'bg2']);
  });

  test('串行：任何时刻只有一个任务在跑', () async {
    final q = DirectTaskQueue();
    final log = _Log();
    for (var i = 0; i < 5; i++) {
      q.submit(DirectTaskPriority.background, key: 'k$i', body: () => log.run('k$i'));
    }
    await q.idle();
    expect(log.maxConcurrent, 1, reason: '并发跑就是同时开 N 条连接抢同一条链路');
  });

  test('中途插队：切歌后当前曲任务插到排队的全库任务前面', () async {
    final q = DirectTaskQueue();
    final log = _Log();
    q.submit(DirectTaskPriority.background, key: 'bg0', body: () => log.run('bg0'));
    // bg0 已经在跑，切歌插进来一个最高优先级任务。
    await Future<void>.delayed(Duration.zero);
    q.submit(DirectTaskPriority.background, key: 'bg1', body: () => log.run('bg1'));
    q.submit(DirectTaskPriority.currentMeta, key: 'cur', body: () => log.run('cur'));

    await q.idle();
    expect(log.order, ['bg0', 'cur', 'bg1']);
  });

  test('换歌作废：过期且未开始的下一首任务被丢掉', () async {
    final q = DirectTaskQueue();
    final log = _Log();
    q.submit(DirectTaskPriority.nextAudio, key: 'nextA', body: () => log.run('nextA'));
    q.submit(DirectTaskPriority.nextMeta, key: 'nextM', body: () => log.run('nextM'));
    expect(q.debugPendingKeys, ['nextAudio/nextA', 'nextMeta/nextM']);

    q.dropPending((p, _) =>
        p == DirectTaskPriority.nextAudio || p == DirectTaskPriority.nextMeta);
    expect(q.debugPendingKeys, isEmpty);
    await q.idle();
    expect(log.order, isEmpty, reason: '预载到不再会播的那首，纯浪费带宽');

    // 全库任务不受换歌影响。
    q.submit(DirectTaskPriority.background, key: 'bg', body: () => log.run('bg'));
    await q.idle();
    expect(log.order, ['bg']);
  });

  test('同 key 幂等：重复提交只跑一次', () async {
    final q = DirectTaskQueue();
    var n = 0;
    for (var i = 0; i < 5; i++) {
      q.submit(DirectTaskPriority.background, key: 'same', body: () async => n++);
    }
    expect(q.pendingCount, 1, reason: '同一个 key 不该排多份');
    await q.idle();
    expect(n, 1);
  });

  test('单任务失败不拖垮队列', () async {
    final q = DirectTaskQueue();
    final log = _Log();
    q.submit(DirectTaskPriority.currentMeta,
        key: 'boom', body: () async => throw StateError('源不可达'));
    q.submit(DirectTaskPriority.nextMeta, key: 'nextM', body: () => log.run('nextM'));

    await q.idle();
    expect(log.order, ['nextM']);
  });

  test('idle：排空后才完成，已空时立即完成', () async {
    final q = DirectTaskQueue();
    final immediate = Completer<void>();
    unawaited(q.idle().then((_) => immediate.complete()));
    await Future<void>.delayed(Duration.zero);
    expect(immediate.isCompleted, isTrue, reason: '没有任何任务时不该吊住调用方');

    final started = Completer<void>();
    q.submit(DirectTaskPriority.background, key: 'slow', body: () async {
      started.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await started.future;
    expect(q.isRunning, isTrue);

    final drained = Completer<void>();
    unawaited(q.idle().then((_) => drained.complete()));
    await Future<void>.delayed(Duration.zero);
    expect(drained.isCompleted, isFalse, reason: '还有任务在跑就不能算 idle');
    await drained.future;
    expect(drained.isCompleted, isTrue);
  });
}
