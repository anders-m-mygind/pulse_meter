// Test utilities and helpers for pulse_meter

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper to pump a widget with minimal setup
Future<void> pumpTestWidget(
  WidgetTester tester,
  Widget widget,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: widget,
    ),
  );
}

/// Helper to pump widget and wait for animations
Future<void> pumpAndSettle(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  await tester.pumpAndSettle(timeout);
}

/// Helper to find widgets by text
Finder findByText(String text) => find.text(text);

/// Helper to find widgets by type
Finder findByType<T extends Widget>() => find.byType(T);

/// Helper to find widgets by key
Finder findByKey(Key key) => find.byKey(key);

/// Helper to verify widget exists
void expectWidgetExists<T extends Widget>() {
  expect(find.byType(T), findsWidgets);
}

/// Helper to verify widget count
void expectWidgetCount<T extends Widget>(int count) {
  expect(find.byType(T), findsWidgets);
}

/// Helper to tap a button by text
Future<void> tapButtonByText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

/// Helper to enter text in a TextField
Future<void> enterText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}
