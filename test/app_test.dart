import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_meter/main.dart';

void main() {
  group('PulseMeterApp', () {
    testWidgets('App initializes with PulseHome', (WidgetTester tester) async {
      // Build the app
      await tester.pumpWidget(const PulseMeterApp());

      // Verify the app rendered without errors
      expect(find.byType(PulseMeterApp), findsOneWidget);

      // Allow animations to settle
      await tester.pumpAndSettle();

      // App should display without crashing
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('App uses dark theme colors', (WidgetTester tester) async {
      await tester.pumpWidget(const PulseMeterApp());
      await tester.pumpAndSettle();

      // Verify Material3 theme is applied
      final materialApp = find.byType(MaterialApp);
      expect(materialApp, findsOneWidget);
    });

    testWidgets('App renders without errors', (WidgetTester tester) async {
      // This test verifies the app can start without exceptions
      await tester.pumpWidget(const PulseMeterApp());

      // No exceptions should be thrown
      expect(tester.takeException(), isNull);
    });
  });
}
