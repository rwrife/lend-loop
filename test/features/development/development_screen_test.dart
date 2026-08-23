import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/development_status.dart';
import 'package:lend_loop/features/development/development_screen.dart';

void main() {
  testWidgets('exposes the startup message as one semantic container', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DevelopmentScreen(status: DevelopmentStatus.current),
      ),
    );

    expect(
      find.bySemanticsLabel(
        'Lend Loop. Under development. '
        'Private, offline lending records are coming soon.',
      ),
      findsOneWidget,
    );
  });
}
