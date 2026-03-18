# Testing Guide for Pulse Meter

This document outlines the testing infrastructure and how to verify your code works.

## Quick Start

### Run All Tests
```bash
flutter test
```

### Run Tests with Coverage
```bash
flutter test --coverage
```

### Run Specific Test File
```bash
flutter test test/app_test.dart
```

## Available VS Code Tasks

Open the Task menu (Cmd+Shift+B on macOS) or use Terminal > Run Task:

- **Run All Tests** (default) - Runs entire test suite with verbose output
- **Run Tests with Coverage** - Generates coverage report
- **Run Widget Tests** - Tests Flutter UI components
- **Run Unit Tests** - Tests utility functions and logic
- **Analyze Code** - Checks code for lint issues
- **Format Code** - Formats all Dart files

## Project Test Structure

```
test/
├── widget_test.dart        # Basic widget tests
├── app_test.dart           # Main app initialization tests
├── test_helpers.dart       # Reusable test utilities
├── unit/
│   └── utilities_test.dart  # Unit tests for helpers
└── integration/
    └── (add integration tests here)
```

## Writing Tests

### Widget Test Example
```dart
testWidgets('Button click works', (WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  
  // Find and interact with widgets
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
  
  // Verify expected behavior
  expect(find.text('Expected Text'), findsOneWidget);
});
```

### Unit Test Example
```dart
test('Function returns expected value', () {
  final result = myFunction('input');
  expect(result, 'expected output');
});
```

## Test Utilities

Use helpers from `test_helpers.dart`:

- `pumpTestWidget()` - Quickly pump a widget for testing
- `tapButtonByText()` - Tap button by its text label
- `enterText()` - Type text into TextField
- `expectWidgetExists<T>()` - Verify widget type exists
- `findByText()`, `findByType()`, `findByKey()` - Common finders

## Verification Agent

Use the custom `/verify` agent to make testing even easier:

```
/verify Test the speech-to-text feature
/verify Run all tests and report coverage
/verify Create tests for new feature X
```

The agent will automatically:
- Run flutter test
- Create test files if needed
- Generate coverage reports
- Fix test failures

## Continuous Testing

Keep tests running while developing:

```bash
flutter test --watch
```

This will re-run tests whenever files change.

## Coverage Reports

```bash
flutter test --coverage
open coverage/lcov.html  # View coverage report
```

## Troubleshooting

**Tests won't run**: Make sure flutter is installed
```bash
flutter doctor
```

**Import errors in tests**: Ensure pubspec.yaml has all dependencies
```bash
flutter pub get
```

**Tests fail with permissions**: Some tests need permission handling (implemented in app)

**Mock errors**: Use `mockito` or `mocktail` packages if you need to mock classes

## Next Steps

1. Add more unit tests for app logic
2. Add integration tests for critical flows
3. Set up code coverage threshold (e.g., 80%+)
4. Use `/verify` agent for ongoing validation
