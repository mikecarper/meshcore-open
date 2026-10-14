import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/widgets/native_decoder_mode_setting.dart';

void main() {
  testWidgets('narrow setting selects Accurate and explains memory-safe Fast', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var mode = AeicDecoderMode.fast;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(16),
              child: NativeDecoderModeSetting(
                mode: mode,
                onChanged: (value) => setState(() => mode = value),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('memory-safe fallback'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<AeicDecoderMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accurate').last);
    await tester.pumpAndSettle();
    expect(mode, AeicDecoderMode.accurate);
    expect(find.text('Uses conservative decoding.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
