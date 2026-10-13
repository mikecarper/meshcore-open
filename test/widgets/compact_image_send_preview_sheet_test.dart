import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/image_compression_screen.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';
import 'package:meshcore_open/widgets/image_send_preview_sheet.dart';

final _source = Uint8List.fromList(
  image.encodePng(image.Image(width: 128, height: 64)),
);
final _decoded = Uint8List.fromList(
  image.encodePng(image.Image(width: 32, height: 64)),
);

class _PreviewCodec extends CompactImageCodecService {
  _PreviewCodec({this.delayed = false, this.oversized = false});
  final bool delayed;
  final bool oversized;
  final pending = Completer<Uint8List>();
  int encodes = 0;
  int cancels = 0;
  ImageCodecRatePoint? encodedRate;
  CompactImageCompressionResult? _result;

  @override
  CompactImageCompressionResult? get result => _result;

  @override
  Future<Uint8List> encode(Uint8List bytes, ImageCodecRatePoint rate) async {
    encodes++;
    encodedRate = rate;
    if (delayed) return pending.future;
    _result = CompactImageCompressionResult(
      payload: Uint8List(
        oversized
            ? 2000
            : targetBytes <= 1024
            ? math.min(700, targetBytes - 10)
            : 1400,
      ),
      previewPng: _decoded,
      codec: CompactImageCodec.webp,
      width: 32,
      height: 64,
      blockSize: 32,
      quality: 45,
      score: 0.1,
      attempts: const [],
    );
    return _result!.payload;
  }

  @override
  Future<void> cancelEncode() async {
    cancels++;
    if (!pending.isCompleted) {
      pending.completeError(const CompactImageCancelled());
    }
  }
}

Future<void> _open(
  WidgetTester tester,
  _PreviewCodec codec,
  ValueChanged<ImageSendPreviewResult?> onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => onResult(
              await showImageSendPreviewSheet(
                context: context,
                imageBytes: _source,
                originalFileBytes: _source.length,
                codec: codec,
                radio: const ImageSendRadio(
                  spreadingFactor: 7,
                  bandwidthHz: 250000,
                  rawCodingRate: 1,
                ),
              ),
            ),
            child: const Text('Open preview'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open preview'));
  await tester.pump();
  await tester.runAsync(() async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 2)) {
      final crop = find.byType(CompactImageCropControls);
      if (crop.evaluate().isNotEmpty &&
          tester.widget<CompactImageCropControls>(crop).sourceAspectRatio ==
              2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tester.pump();
    }
  });
  if (codec.delayed) {
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pumpAndSettle();
  }
}

Finder get _send => find.byWidgetPredicate((widget) => widget is FilledButton);

Future<void> _choosePackets(WidgetTester tester, int packets) async {
  final dropdown = find.descendant(
    of: find.byKey(const ValueKey('compression-packet-budget')),
    matching: find.byType(DropdownButton<int>),
  );
  await tester.scrollUntilVisible(dropdown.hitTestable(), 100);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  final option = find.text('$packets total packets').hitTestable();
  await tester.scrollUntilVisible(
    option,
    -80,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<void> _recompress(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('image-send-compress'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'compact send returns verified preview and its separate wire rate',
    (tester) async {
      final codec = _PreviewCodec();
      addTearDown(codec.dispose);
      ImageSendPreviewResult? result;
      await _open(tester, codec, (value) => result = value);
      expect(codec.encodedRate, ImageCodecRatePoint.compact);
      expect(find.text('Decoded PNG preview'), findsOneWidget);
      final preview = tester.widget<CompactImageCropPreview>(
        find.byKey(const ValueKey('image-send-compact-preview')),
      );
      expect(preview.bytes, same(_decoded));
      expect(preview.aspectRatio, 0.5);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(result!.rate, ImageCodecRatePoint.compact);
      expect(result!.previewPng, same(_decoded));
      expect(result!.aspectRatio, 0.5);
      expect(result!.compressionLabel, 'WebP');
      expect(result!.payload.length, 700);
      expect(codec.packetBudget, 8);
      expect(codec.targetBytes, 1024);
      expect(result!.packetCount, lessThanOrEqualTo(8));
    },
  );

  testWidgets(
    'changing byte target invalidates old payload until recompressed',
    (tester) async {
      final codec = _PreviewCodec()..setTargetBytes(2048);
      addTearDown(codec.dispose);
      ImageSendPreviewResult? result;
      await _open(tester, codec, (value) => result = value);
      await tester.ensureVisible(
        find.byKey(const ValueKey('compression-target-1024')),
      );
      await tester.tap(find.byKey(const ValueKey('compression-target-1024')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      expect(find.text('Decoded PNG preview'), findsNothing);
      expect(codec.encodes, 1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('image-send-compress')),
      );
      await tester.tap(find.byKey(const ValueKey('image-send-compress')));
      await tester.pumpAndSettle();
      expect(codec.encodes, 2);
      expect(tester.widget<FilledButton>(_send).onPressed, isNotNull);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(result!.payload.length, 700);
      expect(result!.rate, ImageCodecRatePoint.compact);
    },
  );

  testWidgets('cancel while encoding stops the worker and sends no payload', (
    tester,
  ) async {
    final codec = _PreviewCodec(delayed: true);
    addTearDown(codec.dispose);
    ImageSendPreviewResult? result;
    var closed = false;
    await _open(tester, codec, (value) {
      result = value;
      closed = true;
    });
    expect(tester.widget<FilledButton>(_send).onPressed, isNull);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(codec.cancels, 1);
    expect(closed, true);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'four total packets include recovery and changing parity invalidates the payload',
    (tester) async {
      final codec = _PreviewCodec();
      addTearDown(codec.dispose);
      ImageSendPreviewResult? result;
      await _open(tester, codec, (value) => result = value);
      await _choosePackets(tester, 4);
      expect(codec.packetBudget, 4);
      expect(codec.targetBytes, 473);
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      await _recompress(tester);
      final parity = find.byType(SwitchListTile);
      await tester.scrollUntilVisible(parity.hitTestable(), 100);
      await tester.pumpAndSettle();
      await tester.tap(parity);
      await tester.pumpAndSettle();
      expect(codec.packetBudget, 4);
      expect(codec.budgetIncludesParity, false);
      expect(codec.targetBytes, 631);
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      await _recompress(tester);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(result!.includeParity, false);
      expect(result!.packetCount, 4);
      expect(result!.payload.length, 621);
    },
  );

  testWidgets(
    'an oversized codec result cannot be sent above the selected packet budget',
    (tester) async {
      final codec = _PreviewCodec(oversized: true);
      addTearDown(codec.dispose);
      ImageSendPreviewResult? result;
      await _open(tester, codec, (value) => result = value);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(ImageSendPreviewSheet), findsOneWidget);
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      await tester.scrollUntilVisible(
        find.textContaining('above the 8-packet budget').hitTestable(),
        150,
      );
      expect(find.textContaining('above the 8-packet budget'), findsOneWidget);
    },
  );

  testWidgets(
    'one packet without parity clamps to two when recovery is enabled',
    (tester) async {
      final codec = _PreviewCodec()..setPacketBudget(1, includeParity: false);
      addTearDown(codec.dispose);
      ImageSendPreviewResult? result;
      await _open(tester, codec, (value) => result = value);
      final parity = find.byType(SwitchListTile);
      await tester.scrollUntilVisible(parity.hitTestable(), 100);
      await tester.pumpAndSettle();
      await tester.tap(parity);
      await tester.pumpAndSettle();
      expect(codec.packetBudget, 2);
      expect(codec.budgetIncludesParity, true);
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      await _recompress(tester);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(result!.packetCount, 2);
      expect(result!.includeParity, true);
    },
  );
}
