import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/interaction_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('交互信号派生 isInteracting（滚动计数/过渡/浮层/队列）', () {
    final gate = InteractionGate();
    expect(gate.isInteracting, isFalse);

    gate.beginScroll();
    expect(gate.scrolling, isTrue);
    expect(gate.isInteracting, isTrue);
    // 嵌套滚动：两次 begin 需两次 end 才结束。
    gate.beginScroll();
    gate.endScroll();
    expect(gate.scrolling, isTrue);
    gate.endScroll();
    expect(gate.scrolling, isFalse);

    gate.setTransitioning(true);
    expect(gate.isInteracting, isTrue);
    gate.setTransitioning(false);
    gate.setPlayerSheetDragging(true);
    expect(gate.isInteracting, isTrue);
    gate.setPlayerSheetDragging(false);
    gate.setQueuePanelOpen(true);
    expect(gate.isInteracting, isTrue);
    gate.setQueuePanelOpen(false);
    expect(gate.isInteracting, isFalse);
  });

  test('空闲期通知立即投递', () {
    final gate = InteractionGate();
    var n = 0;
    gate.scheduleNotify(() => n++);
    expect(n, 1);
    expect(gate.hasPendingNotify, isFalse);
  });

  test('交互期聚合去重，结束后补投一次（最终一致）', () async {
    final gate = InteractionGate();
    var n = 0;
    gate.beginScroll();
    gate.scheduleNotify(() => n++);
    gate.scheduleNotify(() => n++); // 去重：只保留最后一次
    expect(n, 0);
    expect(gate.hasPendingNotify, isTrue);

    gate.endScroll(); // 交互结束 → 触发补投（微任务/postframe）
    expect(gate.hasPendingNotify, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(n, 1, reason: '交互结束应补投一次且仅一次');
  });

  test('endScroll 不越界（空栈 end 无副作用）', () {
    final gate = InteractionGate();
    gate.endScroll();
    expect(gate.scrolling, isFalse);
    expect(gate.isInteracting, isFalse);
  });

  test('flushPendingNow 显式补投待投通知', () async {
    final gate = InteractionGate();
    var n = 0;
    gate.beginScroll();
    gate.scheduleNotify(() => n++);
    expect(gate.hasPendingNotify, isTrue);
    gate.flushPendingNow();
    expect(gate.hasPendingNotify, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(n, 1);
  });
}
