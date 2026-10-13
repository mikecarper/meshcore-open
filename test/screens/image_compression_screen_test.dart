import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/screens/image_compression_screen.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

final _source = Uint8List.fromList(
  image.encodePng(image.Image(width: 128, height: 64)),
);
final _preview = Uint8List.fromList(
  image.encodePng(image.Image(width: 32, height: 32)),
);

class _TestCompactCodec extends CompactImageCodecService {
  _TestCompactCodec({
    this.delayed = false,
    this.fail = false,
    this.minimumFailure = false,
  }) : super(enabled: () => false);

  final bool delayed;
  final bool fail;
  final bool minimumFailure;
  final Completer<CompactImageCompressionResult> pending = Completer();
  int compressCalls = 0;
  int cancelCalls = 0;
  int? requestedTarget;
  CompactImageCrop? requestedCrop;
  bool _busy = false;
  CompactImageCompressionResult? _result;

  @override
  bool get isBusy => _busy;
  @override
  String? get stage => _busy ? 'Comparing WebP' : null;
  @override
  double? get progress => _busy ? 0.25 : null;
  @override
  CompactImageCompressionResult? get result => _result;
  @override
  Future<List<CompactImageCodecCapability>> capabilities() async => const [
    CompactImageCodecCapability(codec: CompactImageCodec.webp, available: true),
    CompactImageCodecCapability(
      codec: CompactImageCodec.bpg,
      available: false,
      reason: 'No local BPG codec',
    ),
  ];

  @override
  Future<CompactImageCompressionResult> compress(
    Uint8List imageBytes, {
    int? targetBytes,
    CompactImageCrop? crop,
    List<CompactImageCodec>? codecs,
  }) async {
    compressCalls++;
    requestedTarget = targetBytes;
    requestedCrop = crop;
    _busy = true;
    notifyListeners();
    try {
      if (minimumFailure) {
        throw StateError(
          'No verified image at 128 pixels or larger fits the budget.',
        );
      }
      if (fail) {
        throw const FormatException('No verified image fits the byte target.');
      }
      _result = delayed
          ? await pending.future
          : CompactImageCompressionResult(
              payload: Uint8List(
                math.min(700, (targetBytes ?? this.targetBytes) - 10),
              ),
              previewPng: _preview,
              codec: CompactImageCodec.webp,
              width: 32,
              height: 32,
              blockSize: 16,
              quality: 45,
              score: 0.1,
              attempts: const [
                CompactImageCodecAttempt(
                  codec: CompactImageCodec.webp,
                  status: CompactImageCodecAttemptStatus.completed,
                  elapsedMs: 140,
                  encodedBytes: 700,
                ),
                CompactImageCodecAttempt(
                  codec: CompactImageCodec.avif,
                  status: CompactImageCodecAttemptStatus.timedOut,
                  elapsedMs: 120000,
                ),
                CompactImageCodecAttempt(
                  codec: CompactImageCodec.bpg,
                  status: CompactImageCodecAttemptStatus.unavailable,
                  elapsedMs: 0,
                  reason: 'No local BPG codec',
                ),
              ],
            );
      return _result!;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  Future<void> cancelEncode() async {
    cancelCalls++;
    if (delayed && !pending.isCompleted) {
      pending.completeError(const CompactImageCancelled());
    }
  }
}

Future<void> _mount(WidgetTester tester, _TestCompactCodec codec) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImageCompressionScreen(
          initialImageBytes: _source,
          service: codec,
        ),
      ),
    );
    final clock = Stopwatch()..start();
    while (tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('compression-compare')),
                )
                .onPressed ==
            null &&
        clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tester.pump();
    }
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('compression-compare')),
          )
          .onPressed,
      isNotNull,
    );
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'default is 1KB with an eight-packet budget and four packets use their real byte ceiling',
    (tester) async {
      final codec = _TestCompactCodec();
      addTearDown(codec.dispose);
      await _mount(tester, codec);
      expect(codec.packetBudget, 8);
      expect(codec.targetBytes, 1024);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-target-1024')).hitTestable(),
        150,
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('compression-target-1024')),
            )
            .selected,
        true,
      );
      final dropdown = find.descendant(
        of: find.byKey(const ValueKey('compression-packet-budget')),
        matching: find.byType(DropdownButton<int>),
      );
      await tester.scrollUntilVisible(dropdown.hitTestable(), 100);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('4 total packets').hitTestable(),
        -80,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('4 total packets').hitTestable());
      await tester.pumpAndSettle();
      expect(codec.packetBudget, 4);
      expect(codec.targetBytes, 473);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-compare')).hitTestable(),
        150,
      );
      await tester.tap(find.byKey(const ValueKey('compression-compare')));
      await tester.pumpAndSettle();
      expect(codec.requestedTarget, 473);
      await tester.scrollUntilVisible(
        find.textContaining('Uses 4 of 4 LoRa packets').hitTestable(),
        150,
      );
      expect(find.textContaining('Uses 4 of 4 LoRa packets'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'minimum resolution failure offers more packets or another crop',
    (tester) async {
      final codec = _TestCompactCodec(minimumFailure: true);
      addTearDown(codec.dispose);
      await _mount(tester, codec);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-compare')).hitTestable(),
        150,
      );
      await tester.tap(find.byKey(const ValueKey('compression-compare')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining("Can't fit within 8 packets").hitTestable(),
        150,
      );
      expect(
        find.textContaining(
          "Can't fit within 8 packets at 128 pixels or larger.",
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Choose more packets or a different crop.'),
        findsOneWidget,
      );
      expect(find.text('Decoded PNG preview'), findsNothing);
    },
  );

  testWidgets(
    'comparison runs with image messages disabled and uses target plus crop',
    (tester) async {
      final codec = _TestCompactCodec();
      addTearDown(codec.dispose);
      expect(codec.availability, ImageCodecAvailability.disabled);
      await _mount(tester, codec);
      await tester.scrollUntilVisible(find.text('No local BPG codec'), 150);
      expect(find.text('No local BPG codec'), findsOneWidget);
      expect(codec.compressCalls, 0);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-crop-Square')),
        -150,
      );
      await tester.tap(find.byKey(const ValueKey('compression-crop-Square')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('compression-target-1024')),
      );
      await tester.tap(find.byKey(const ValueKey('compression-target-1024')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-compare')).hitTestable(),
        150,
      );
      await tester.tap(find.byKey(const ValueKey('compression-compare')));
      await tester.pumpAndSettle();
      expect(codec.requestedTarget, 1024);
      expect(codec.requestedCrop!.left, closeTo(0.25, 0.01));
      expect(codec.requestedCrop!.right, closeTo(0.75, 0.01));
      await tester.scrollUntilVisible(
        find.text('Decoded PNG preview').hitTestable(),
        150,
      );
      expect(find.text('Decoded PNG preview'), findsOneWidget);
      final preview = tester.widget<CompactImageCropPreview>(
        find.byKey(const ValueKey('compression-decoded-preview')),
      );
      expect(preview.bytes, same(_preview));
      expect(preview.aspectRatio, 1);
      await tester.scrollUntilVisible(
        find.textContaining('Stopped at 2 minutes'),
        150,
      );
      expect(find.textContaining('Stopped at 2 minutes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel stops an active comparison and unlocks the controls', (
    tester,
  ) async {
    final codec = _TestCompactCodec(delayed: true);
    addTearDown(codec.dispose);
    await _mount(tester, codec);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('compression-compare')).hitTestable(),
      150,
    );
    await tester.tap(find.byKey(const ValueKey('compression-compare')));
    await tester.pump();
    expect(codec.isBusy, true);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('compression-compare')),
          )
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('compression-cancel')).hitTestable(),
      150,
    );
    await tester.tap(find.byKey(const ValueKey('compression-cancel')));
    await tester.pumpAndSettle();
    expect(codec.cancelCalls, 1);
    expect(codec.isBusy, false);
    await tester.scrollUntilVisible(
      find.text('Image compression cancelled.').hitTestable(),
      150,
    );
    expect(find.text('Image compression cancelled.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final height in [480.0, 568.0]) {
    testWidgets(
      'narrow API22-sized 320x$height screen fits crop and byte controls without overflow',
      (tester) async {
        tester.view.physicalSize = Size(320, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final codec = _TestCompactCodec();
        addTearDown(codec.dispose);
        await _mount(tester, codec);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('compression-crop-3:4')).hitTestable(),
          100,
        );
        await tester.tap(find.byKey(const ValueKey('compression-crop-3:4')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(const ValueKey('compression-crop-3:4')),
              )
              .selected,
          true,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('compression-compare')).hitTestable(),
          150,
        );
        expect(
          find.byKey(const ValueKey('compression-compare')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a failed comparison explains the failure and never shows source as decoded output',
    (tester) async {
      final codec = _TestCompactCodec(fail: true);
      addTearDown(codec.dispose);
      await _mount(tester, codec);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('compression-compare')).hitTestable(),
        150,
      );
      await tester.tap(find.byKey(const ValueKey('compression-compare')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('No verified image fits').hitTestable(),
        150,
      );
      expect(
        find.textContaining('No verified image fits the byte target.'),
        findsOneWidget,
      );
      expect(find.text('Decoded PNG preview'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('compression-compare')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
}
