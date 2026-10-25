import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/widgets/root_focus_keeper.dart';

Widget _app({
  required FocusNode root,
  required Widget child,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    home: RootFocusKeeper(
      focusNode: root,
      child: Focus(
        focusNode: root,
        autofocus: true,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('搜索框失焦回落到祖先 Scope 时，根节点重新拿到焦点', (tester) async {
    final root = FocusNode(debugLabel: 'root');
    final field = FocusNode(debugLabel: 'search');
    addTearDown(root.dispose);
    addTearDown(field.dispose);
    await tester.pumpWidget(_app(
      root: root,
      child: Column(
        children: [
          TextField(
            focusNode: field,
            onTapOutside: (_) => field.unfocus(),
          ),
          const Expanded(child: Center(child: Text('outside'))),
        ],
      ),
    ));
    await tester.pump();
    expect(root.hasPrimaryFocus, isTrue);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field.hasPrimaryFocus, isTrue);

    await tester.tap(find.text('outside'));
    await tester.pump();
    await tester.pump();

    expect(root.hasPrimaryFocus, isTrue);
    expect(field.hasPrimaryFocus, isFalse);
  });

  testWidgets('输入框聚焦时根节点不抢焦点', (tester) async {
    final root = FocusNode(debugLabel: 'root');
    final field = FocusNode(debugLabel: 'search');
    addTearDown(root.dispose);
    addTearDown(field.dispose);
    await tester.pumpWidget(_app(
      root: root,
      child: TextField(focusNode: field),
    ));
    await tester.pump();

    field.requestFocus();
    await tester.pump();
    await tester.pump();

    expect(field.hasPrimaryFocus, isTrue);
    expect(root.hasPrimaryFocus, isFalse);
  });

  testWidgets('pushed 路由打开时不抢焦点，返回后根节点恢复', (tester) async {
    final root = FocusNode(debugLabel: 'root');
    final navKey = GlobalKey<NavigatorState>();
    addTearDown(root.dispose);
    await tester.pumpWidget(_app(
      root: root,
      navigatorKey: navKey,
      child: const Text('home'),
    ));
    await tester.pump();
    expect(root.hasPrimaryFocus, isTrue);

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('route')),
    ));
    await tester.pumpAndSettle();
    expect(root.hasPrimaryFocus, isFalse);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(root.hasPrimaryFocus, isTrue);
  });
}
