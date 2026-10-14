import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/utils/lora_airtime.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';
import 'package:meshcore_open/widgets/image_send_preview_sheet.dart';

/// A real 1x1 PNG. Image.memory reports decode failures through FlutterError,
/// which fails the test even though the sheet has an errorBuilder, so the test
/// must hand it bytes that actually decode.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// Radio settings a connected device would report: SF10 / BW 250k / CR 4/5.
/// The coding rate is given in the raw 1..4 firmware domain on purpose, to keep
/// the sheet's normalisation on the tested path.
const ImageSendRadio _knownRadio = ImageSendRadio(
  spreadingFactor: 10,
  bandwidthHz: 250000,
  rawCodingRate: 1,
);

/// Packets the sheet must report for the fake codec's ft32 mean payload:
/// the chunker's own data-chunk count plus the XOR parity packet, which is on by
/// default. Derived, because the chunk capacities have moved before.
final int _expectedPackets =
    imageChunkCount(ImageCodecRateStats.standard.meanBytes) + 1;

/// Nothing known yet — the state right after connecting, before SELF_INFO.
const ImageSendRadio _unknownRadio = ImageSendRadio();

Future<ImageSendPreviewResult?> _openSheet(
  WidgetTester tester, {
  required ImageSendRadio radio,
  ImageSendCodec codec = const FakeImageSendCodec(latency: Duration.zero),
  bool waitForPreparation = true,
  bool scoped = false,
  void Function(ImageSendPreviewResult?)? onResult,
}) async {
  ImageSendPreviewResult? result;
  var closed = false;

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showImageSendPreviewSheet(
                  context: context,
                  imageBytes: _onePixelPng,
                  originalFileBytes: 2 * 1024 * 1024,
                  codec: codec,
                  radio: radio,
                  scoped: scoped,
                );
                closed = true;
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  if (waitForPreparation) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }
  expect(closed, isFalse, reason: 'sheet should still be open');
  return result;
}

/// Every string rendered by the sheet, so assertions can look for a value
/// without knowing which widget carries it.
List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .toList();

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

class _RecordingNativeCodec extends FakeImageSendCodec {
  final List<int?> requestedSizes = [];

  _RecordingNativeCodec()
    : super(
        sendRatePoint: ImageCodecRatePoint.nativeFt2,
        latency: Duration.zero,
      );

  @override
  Future<Uint8List> encode(
    Uint8List bytes,
    ImageCodecRatePoint rate, {
    int? resolution,
  }) {
    requestedSizes.add(resolution);
    return super.encode(bytes, rate, resolution: resolution);
  }
}

class _ControlledNativeCodec extends FakeImageSendCodec
    implements ImageSendCodecJobControl {
  final calls = <String>[];
  final pending = Completer<Uint8List>();
  final cancelFinished = Completer<void>();

  _ControlledNativeCodec()
    : super(sendRatePoint: ImageCodecRatePoint.nativeFt2);

  @override
  bool get canPause => true;
  @override
  bool isPaused = false;

  @override
  Future<Uint8List> encode(
    Uint8List bytes,
    ImageCodecRatePoint rate, {
    int? resolution,
  }) => pending.future;

  @override
  Future<void> pause() async {
    calls.add('pause');
    isPaused = true;
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    isPaused = false;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    await cancelFinished.future;
    pending.completeError(StateError('Cancelled'));
  }
}

void main() {
  testWidgets('scoped native send estimate includes its transport-code bytes', (
    tester,
  ) async {
    ImageSendPreviewResult? sent;
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: _RecordingNativeCodec(),
      scoped: true,
      onResult: (result) => sent = result,
    );
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.pumpAndSettle();
    final expected = estimateSendFromRadioParams(
      payloadBytes: 137,
      spreadingFactor: 10,
      bandwidthHz: 250000,
      codingRate: 1,
      meshCoreGroupData: true,
      scoped: true,
    );
    expect(expected.totalBytes, 354);
    expect(sent?.airtime, expected.totalAirtime);
    expect(sent?.wallClock, expected.pacedWallClock);
  });

  testWidgets('phone back waits for preparation cancellation', (tester) async {
    final codec = _ControlledNativeCodec();
    var closed = false;
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: codec,
      waitForPreparation: false,
      onResult: (_) => closed = true,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(codec.calls, ['cancel']);
    expect(closed, isFalse);
    codec.cancelFinished.complete();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('measured size controls fit a small phone screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 533);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: _RecordingNativeCodec(),
    );
    await _scrollTo(
      tester,
      find.byKey(const ValueKey('image-preparation-stats')),
    );
    expect(_texts(tester), contains('0.137 kB (137 B)'));
    await _scrollTo(
      tester,
      find.byKey(const ValueKey('image-size-comparison')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pauses and resumes preparation, then awaits cancellation before closing',
    (tester) async {
      final codec = _ControlledNativeCodec();
      var closed = false;
      await _openSheet(
        tester,
        radio: _knownRadio,
        codec: codec,
        waitForPreparation: false,
        onResult: (_) => closed = true,
      );
      final pause = find.byKey(const ValueKey('image-codec-pause'));
      await tester.ensureVisible(pause);
      await tester.pump();
      await tester.tap(pause);
      await tester.pump();
      expect(codec.calls, ['pause']);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Image task paused'), findsOneWidget);
      await tester.tap(pause);
      await tester.pump();
      expect(codec.calls, ['pause', 'resume']);
      expect(find.text('Pause'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(codec.calls, ['pause', 'resume', 'cancel']);
      expect(
        closed,
        isFalse,
        reason: 'the native process must stop before dismissal',
      );
      codec.cancelFinished.complete();
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(find.byType(ImageSendPreviewSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native preview defaults to 128 and sends its actual header size',
    (tester) async {
      final codec = _RecordingNativeCodec();
      ImageSendPreviewResult? sent;
      await _openSheet(
        tester,
        radio: _knownRadio,
        codec: codec,
        onResult: (result) => sent = result,
      );
      expect(codec.requestedSizes, [128]);
      final selector = tester.widget<DropdownButtonFormField<int>>(
        find.byKey(const ValueKey('native-image-resolution')),
      );
      expect(selector.initialValue, 128);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.descendant(
          of: find.byKey(const ValueKey('native-image-resolution')),
          matching: find.byType(DropdownButton<int>),
        ),
      );
      expect(
        dropdown.items?.map((item) => item.value).toList(),
        kNativeImageCodecResolutions,
      );
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
      await tester.tap(
        find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      await tester.pumpAndSettle();
      expect(sent?.rate, ImageCodecRatePoint.nativeFt2);
      expect(sent?.resolution, 128);
      expect(
        NativeImageBitstreamHeader.tryParse(sent!.payload)?.resolution,
        128,
      );
    },
  );

  testWidgets('changing native size re-encodes before sending', (tester) async {
    final codec = _RecordingNativeCodec();
    ImageSendPreviewResult? sent;
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: codec,
      onResult: (result) => sent = result,
    );
    await tester.tap(find.byKey(const ValueKey('native-image-resolution')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('576 × 576').last);
    await tester.tap(find.text('576 × 576').last);
    await tester.pumpAndSettle();
    expect(codec.requestedSizes, [128, 576]);
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.pumpAndSettle();
    expect(sent?.resolution, 576);
    expect(sent?.payload.length, 1783);
    expect(NativeImageBitstreamHeader.tryParse(sent!.payload)?.resolution, 576);
  });

  testWidgets(
    'legacy preview retains the 512 stretch without a size selector',
    (tester) async {
      await _openSheet(tester, radio: _knownRadio);
      expect(
        find.byKey(const ValueKey('native-image-resolution')),
        findsNothing,
      );
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.fill);
    },
  );

  testWidgets(
    'shows measured compressed bytes and preparation separately from send estimate',
    (tester) async {
      final codec = _RecordingNativeCodec();
      await _openSheet(tester, radio: _knownRadio, codec: codec);
      expect(_texts(tester), contains('LoRa send (estimated)'));
      await _scrollTo(
        tester,
        find.byKey(const ValueKey('image-preparation-stats')),
      );
      await tester.pumpAndSettle();
      expect(_texts(tester), contains('0.137 kB (137 B)'));
      expect(_texts(tester), contains('Preparation (measured)'));
      expect(codec.requestedSizes, [
        128,
      ], reason: 'other sizes are not prepared automatically');
    },
  );

  testWidgets(
    'comparison retains real choices and reuses a previously prepared bitstream',
    (tester) async {
      final codec = _RecordingNativeCodec();
      ImageSendPreviewResult? sent;
      await _openSheet(
        tester,
        radio: _knownRadio,
        codec: codec,
        onResult: (result) => sent = result,
      );
      final comparison = find.byKey(const ValueKey('image-size-comparison'));
      await _scrollTo(tester, comparison);
      await tester.tap(
        find.descendant(
          of: comparison,
          matching: find.text('Compare image sizes'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Select to calculate this photo'), findsNWidgets(7));
      final choice576 = find.byKey(const ValueKey('image-size-choice-576'));
      await _scrollTo(tester, choice576);
      await tester.tap(choice576);
      await tester.pumpAndSettle();
      expect(codec.requestedSizes, [128, 576]);
      expect(
        _texts(tester).any((text) => text.startsWith('1.783 kB (1783 B)\n')),
        isTrue,
      );
      expect(
        _texts(tester).any((text) => text.startsWith('0.137 kB (137 B)\n')),
        isTrue,
      );
      final choice128 = find.byKey(const ValueKey('image-size-choice-128'));
      await _scrollTo(tester, choice128);
      await tester.tap(choice128);
      await tester.pumpAndSettle();
      expect(
        codec.requestedSizes,
        [128, 576],
        reason: 'returning to a measured size uses its cached bytes',
      );
      await tester.tap(
        find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      await tester.pumpAndSettle();
      expect(sent?.resolution, 128);
      expect(sent?.payload.length, 137);
    },
  );

  testWidgets(
    'parity updates measured choice send estimates without another encode',
    (tester) async {
      final codec = _RecordingNativeCodec();
      await _openSheet(tester, radio: _knownRadio, codec: codec);
      final comparison = find.byKey(const ValueKey('image-size-comparison'));
      await _scrollTo(tester, comparison);
      await tester.tap(
        find.descendant(
          of: comparison,
          matching: find.text('Compare image sizes'),
        ),
      );
      await tester.pumpAndSettle();
      String measured() => _texts(
        tester,
      ).singleWhere((text) => text.startsWith('0.137 kB (137 B)\n'));
      final withParity = measured();
      final switchTile = find.byType(SwitchListTile);
      await _scrollTo(tester, switchTile);
      await tester.tap(switchTile);
      await tester.pumpAndSettle();
      expect(measured(), isNot(withParity));
      expect(codec.requestedSizes, [128]);
    },
  );

  testWidgets('renders with a fake codec and shows the image preview', (
    tester,
  ) async {
    await _openSheet(tester, radio: _knownRadio);

    expect(find.byType(ImageSendPreviewSheet), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // The send action is enabled once the encode has settled.
    final send = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(send.onPressed, isNotNull);
  });

  testWidgets('shows the packet count for the encoded ft32 payload', (
    tester,
  ) async {
    await _openSheet(tester, radio: _knownRadio);

    // FakeImageSendCodec emits the measured ft32 mean (156 B) -> one data chunk,
    // plus the XOR parity packet, which is on by default.
    final expected = estimateSendFromRadioParams(
      payloadBytes: ImageCodecRateStats.standard.meanBytes,
      spreadingFactor: 10,
      bandwidthHz: 250000,
      codingRate: 1,
      meshCoreGroupData: true,
    );
    expect(expected.chunkCount, inInclusiveRange(2, 3));
    expect(_texts(tester), contains('${expected.chunkCount}'));
  });

  testWidgets('shows a concrete airtime when the radio settings are known', (
    tester,
  ) async {
    await _openSheet(tester, radio: _knownRadio);

    final texts = _texts(tester);
    expect(
      texts,
      isNot(contains('—')),
      reason: 'a connected radio must not render the unknown placeholder',
    );
    // The headline time figure is formatted as "<n> s" by the sheet.
    expect(
      texts.any((t) => RegExp(r'^\d+(\.\d)? s$').hasMatch(t)),
      isTrue,
      reason: 'expected a seconds figure among: $texts',
    );
  });

  testWidgets('headline time is the paced wall clock, not raw airtime', (
    tester,
  ) async {
    await _openSheet(tester, radio: _knownRadio);

    final expected = estimateSendFromRadioParams(
      payloadBytes: ImageCodecRateStats.standard.meanBytes,
      spreadingFactor: 10,
      bandwidthHz: 250000,
      codingRate: 1,
      meshCoreGroupData: true,
    );
    // Two packets, so pacing must have widened the figure.
    expect(
      expected.pacedWallClock!.inMicroseconds,
      greaterThan(expected.totalAirtime!.inMicroseconds),
    );

    String seconds(Duration d) {
      final total = d.inMilliseconds / 1000.0;
      return total < 10 ? total.toStringAsFixed(1) : total.round().toString();
    }

    final texts = _texts(tester);
    expect(texts, contains('${seconds(expected.pacedWallClock!)} s'));
    expect(texts, isNot(contains('${seconds(expected.totalAirtime!)} s')));
  });

  testWidgets('renders "unknown" airtime when the radio params are absent', (
    tester,
  ) async {
    await _openSheet(tester, radio: _unknownRadio);

    final texts = _texts(tester);
    // The em dash placeholder, never a fabricated duration.
    expect(texts, contains('—'));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('image-send-time'))).data,
      '—',
      reason: 'send duration cannot be invented; preparation time is measured',
    );
    await _scrollTo(
      tester,
      find.byKey(const ValueKey('image-preparation-stats')),
    );
    expect(_texts(tester), contains('Preparation (measured)'));
    // The packet count is still meaningful and must survive.
    expect(texts, contains('$_expectedPackets'));
  });

  testWidgets('zero-valued radio settings show unavailable send time', (
    tester,
  ) async {
    await _openSheet(
      tester,
      radio: const ImageSendRadio(
        spreadingFactor: 0,
        bandwidthHz: 0,
        rawCodingRate: 0,
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('image-send-time'))).data,
      '—',
    );
    await _scrollTo(tester, find.text('Radio settings unknown'));
    expect(_texts(tester), contains('Radio settings unknown'));
  });

  testWidgets('offers no quality selector', (tester) async {
    await _openSheet(tester, radio: _knownRadio);

    final texts = _texts(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(texts, isNot(contains(l10n.imageSend_quality)));
    expect(texts, isNot(contains(l10n.imageSend_qualityStandard)));
    expect(texts, isNot(contains(l10n.imageSend_qualityHigh)));
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('returns null when the user cancels', (tester) async {
    ImageSendPreviewResult? result;
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showImageSendPreviewSheet(
                    context: context,
                    imageBytes: _onePixelPng,
                    originalFileBytes: 1024,
                    codec: const FakeImageSendCodec(latency: Duration.zero),
                    radio: _knownRadio,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNull);
    expect(find.byType(ImageSendPreviewSheet), findsNothing);
  });

  testWidgets('confirming returns the payload, packet count and both times', (
    tester,
  ) async {
    ImageSendPreviewResult? result;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showImageSendPreviewSheet(
                    context: context,
                    imageBytes: _onePixelPng,
                    originalFileBytes: 1024,
                    codec: const FakeImageSendCodec(latency: Duration.zero),
                    radio: _knownRadio,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.payload.length, ImageCodecRateStats.standard.meanBytes);
    // ft32 is the only rate point the sheet can produce.
    expect(result!.rate, kImageSendRatePoint);
    expect(result!.includeParity, isTrue);
    expect(result!.packetCount, _expectedPackets);
    expect(result!.airtime, isNotNull);
    expect(
      result!.wallClock!.inMicroseconds,
      greaterThan(result!.airtime!.inMicroseconds),
    );
  });

  testWidgets('a codec that is still downloading cannot be sent from', (
    tester,
  ) async {
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: const FakeImageSendCodec(
        availability: ImageCodecAvailability.downloading,
        latency: Duration.zero,
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(_texts(tester), contains(l10n.imageSend_codecDownloading));
    final send = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('an unavailable codec explains itself with unavailableReason, '
      'not the generic string', (tester) async {
    const reason =
        'This build ships the image decoder only. Encoding and '
        'decoding a bitstream also needs the entropy-side graph and the rANS '
        'coder, which are not included yet.';
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: const FakeImageSendCodec(
        availability: ImageCodecAvailability.unavailable,
        unavailableReason: reason,
        latency: Duration.zero,
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final texts = _texts(tester);
    expect(texts, contains(reason));
    expect(
      texts,
      isNot(contains(l10n.imageSend_codecUnavailable)),
      reason: 'the concrete reason must REPLACE the generic sentence',
    );
    final send = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('an unavailable codec that gives no reason falls back to the '
      'generic string', (tester) async {
    await _openSheet(
      tester,
      radio: _knownRadio,
      codec: const FakeImageSendCodec(
        availability: ImageCodecAvailability.unavailable,
        latency: Duration.zero,
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(_texts(tester), contains(l10n.imageSend_codecUnavailable));
  });
}
