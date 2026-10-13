import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// File/compute operations must run in real async time, not FakeAsync's clock.
Future<void> pressAsyncButton(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  final button = tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ),
  );
  await tester.runAsync(button.onPressed! as Future<void> Function());
  await tester.pumpAndSettle();
}
