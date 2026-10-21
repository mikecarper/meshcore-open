import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:meshcore_open/widgets/dfu_bootloader_choice.dart';

void main() {
  for (final cancel in [false, true]) {
    testWidgets(
      'multiple updater choice ${cancel ? 'cancels' : 'selects one radio'}',
      (tester) async {
        String? result = 'not completed';
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await chooseDfuBootloader(
                    context,
                    board: 'RAK 4631',
                    candidates: const [
                      DfuAdvertisement('C3:C6:A8:FC:AD:A6', '4631_DFU', [
                        legacyDfuServiceUuid,
                      ]),
                      DfuAdvertisement('C3:C6:A8:FC:AD:A7', '4631_DFU', [
                        legacyDfuServiceUuid,
                      ]),
                    ],
                  );
                },
                child: const Text('Recover update'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Recover update'));
        await tester.pumpAndSettle();
        expect(find.text('Which radio is in update mode?'), findsOneWidget);
        expect(find.text('RAK 4631 updater'), findsNWidgets(2));
        expect(result, 'not completed');
        await tester.tap(
          cancel
              ? find.text('Cancel')
              : find.textContaining('C3:C6:A8:FC:AD:A7'),
        );
        await tester.pumpAndSettle();
        expect(result, cancel ? isNull : 'C3:C6:A8:FC:AD:A7');
      },
    );
  }
}
