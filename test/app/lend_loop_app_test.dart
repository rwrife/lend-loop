import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/lend_loop_app.dart';

void main() {
  testWidgets('starts on the honest development screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LendLoopApp());

    expect(find.text('Lend Loop'), findsOneWidget);
    expect(find.text('Under development'), findsOneWidget);
    expect(
      find.text('Private, offline lending records are coming soon.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.handshake_outlined), findsOneWidget);
  });
}
