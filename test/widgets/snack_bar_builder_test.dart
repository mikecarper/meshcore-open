import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/snack_bar_builder.dart';

void main() {
  testWidgets(
    'persistent snack bar remains until the user dismisses it on either SDK',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDismissibleSnackBar(
                  context,
                  content: const Text('Persistent notice'),
                  persist: true,
                  duration: const Duration(milliseconds: 20),
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Persistent notice'), findsOneWidget);
      await tester.tap(find.text('Persistent notice'));
      await tester.pumpAndSettle();
      expect(find.text('Persistent notice'), findsNothing);
    },
  );
}
