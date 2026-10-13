import 'package:flutter_test/flutter_test.dart';

import 'package:finora/main.dart';

void main() {
  testWidgets('Finora portfolio dashboard renders', (tester) async {
    await tester.pumpWidget(const FinoraApp());

    expect(find.text('finora'), findsOneWidget);
    expect(find.text('Your portfolio'), findsOneWidget);
    expect(find.text('Market Watch'), findsOneWidget);
  });
}
