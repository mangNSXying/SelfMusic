import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/app_toast.dart';

/// AppToast 自动消失回归。
///
/// 泄漏点：计时回调原以 `entry.mounted` 为摘除前提，而 `mounted` 取决于该
/// OverlayEntry 是否已被构建（`_OverlayEntryWidgetState` 挂载）。若弹入后到计时
/// 到期之间**没有产出帧**（启动期同步/后台重入/重负载无帧区间），条目尚未构建 →
/// mounted=false → 跳过 remove → 条目永久滞留 `_entries`，下一帧才渲染出来且
/// 再无计时器回收，表现为 toast 不消失。修复后无条件摘除。
void main() {
  Widget host() => MaterialApp(
        navigatorKey: appNavigatorKey,
        home: const Scaffold(body: Text('host')),
      );

  testWidgets('普通流程：计时到期后 toast 自动消失', (tester) async {
    await tester.pumpWidget(host());
    AppToast.show('同步完成', isError: false);
    await tester.pump();
    expect(find.text('同步完成'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.text('同步完成'), findsNothing);
  });

  testWidgets('弹入后无帧产出：计时到期摘除，不在后续帧里复活', (tester) async {
    await tester.pumpWidget(host());
    // 关键：show 后**不 pump**（模拟启动同步/后台等无帧区间），
    // 直接推进时间让计时到期——条目此时尚未构建（mounted=false）。
    AppToast.show('同步完成', isError: false);
    await tester.pump(const Duration(milliseconds: 3000));
    // 之后有帧了：修复前条目滞留并在此渲染且永不过期；修复后从未出现。
    await tester.pump();
    expect(find.text('同步完成'), findsNothing);
  });

  testWidgets('被不透明全屏路由盖住：到期摘除、路由弹出后不复活', (tester) async {
    await tester.pumpWidget(host());
    AppToast.show('同步完成', isError: false);
    await tester.pump();
    expect(find.text('同步完成'), findsOneWidget);

    // toast 呈现期间推入全屏播放页（不透明路由）盖住。
    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('player'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(find.text('同步完成'), findsOneWidget);

    // 计时到期：修复后 entry 已摘除。
    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.text('同步完成'), findsNothing);

    // 弹出播放页：toast 不应复活。
    appNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('player'), findsNothing);
    expect(find.text('同步完成'), findsNothing);
  });

  testWidgets('未到期的旧 toast 被新 toast 顶掉，且新 toast 正常过期', (tester) async {
    await tester.pumpWidget(host());
    AppToast.show('同步完成', isError: false);
    await tester.pump();
    expect(find.text('同步完成'), findsOneWidget);

    AppToast.show('新消息', isError: false);
    await tester.pump();
    expect(find.text('同步完成'), findsNothing);
    expect(find.text('新消息'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.text('新消息'), findsNothing);
  });
}