import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/frame_scheduler.dart';

void main() {
  testWidgets('scheduleAfterFrame：帧末执行且只执行一次', (tester) async {
    var calls = 0;
    scheduleAfterFrame(() => calls++);
    expect(calls, 0, reason: '注册时不得同步执行');
    await tester.pump();
    expect(calls, 1);
    await tester.pump();
    expect(calls, 1, reason: '一次性回调不得重复执行');
  });

  testWidgets('scheduleAfterFrame：多次调度按注册顺序在帧末执行', (tester) async {
    final order = <String>[];
    scheduleAfterFrame(() => order.add('a'));
    scheduleAfterFrame(() => order.add('b'));
    expect(order, isEmpty);
    await tester.pump();
    expect(order, ['a', 'b']);
  });
}
