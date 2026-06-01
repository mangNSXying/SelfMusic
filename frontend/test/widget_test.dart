import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/main.dart';

void main() {
  testWidgets('App renders home page', (WidgetTester tester) async {
    await tester.pumpWidget(const SelfMusicApp());
    expect(find.text('SelfMusic'), findsOneWidget);
    expect(find.text('Welcome to SelfMusic'), findsOneWidget);
  });
}
