import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/path_hash_filter_dialog.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester,
    ValueChanged<String?> onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => const PathHashFilterDialog(),
                  ),
                );
              },
              child: const Text('Open filter'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open filter'));
    await tester.pumpAndSettle();
  }

  testWidgets('prepares the 1-byte command only after explicit review', (
    tester,
  ) async {
    String? result;
    await openDialog(tester, (value) => result = value);
    expect(result, isNull);
    expect(
      find.textContaining('no command is sent by this dialog'),
      findsOneWidget,
    );
    await tester.tap(find.text('Prepare command'));
    await tester.pumpAndSettle();
    expect(result, 'set fr any pb=1 d');
  });

  testWidgets('validates a rate before preparing the selected-width command', (
    tester,
  ) async {
    String? result;
    await openDialog(tester, (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('path-hash-filter-width')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3-byte hashes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('Prepare command'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Enter a whole number from 1 to 65534'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '7');
    await tester.tap(find.text('Prepare command'));
    await tester.pumpAndSettle();
    expect(result, 'set fr any pb=3 q=7');
  });

  testWidgets('cancel returns no command and fits a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var called = false;
    String? result;
    await openDialog(tester, (value) {
      called = true;
      result = value;
    });
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(called, true);
    expect(result, isNull);
  });

  testWidgets('2+ prepares one range rule without sending it', (tester) async {
    String? result;
    await openDialog(tester, (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('path-hash-filter-width')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2+ bytes (2 or 3)').last);
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('Prepare command'));
    await tester.pumpAndSettle();
    expect(result, 'set fr any pb=2+ d');
  });
}
