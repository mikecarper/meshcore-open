import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/compact_image_codec_service.dart';
import '../services/image_chunk_transport.dart' show imageDataChunkCount;
import '../services/compact_image_preparation.dart'
    show CompactImagePreparation;
import '../widgets/adaptive_app_bar_title.dart';

/// Local image comparison. Opening this screen never transmits a packet.
class ImageCompressionScreen extends StatefulWidget {
  const ImageCompressionScreen({
    super.key,
    this.initialImageBytes,
    this.service,
  });

  final Uint8List? initialImageBytes;
  final CompactImageCodecService? service;

  @override
  State<ImageCompressionScreen> createState() => _ImageCompressionScreenState();
}

class _ImageCompressionScreenState extends State<ImageCompressionScreen> {
  CompactImageCodecService? _service;
  Uint8List? _source;
  Uint8List? _displaySource;
  CompactImageCrop? _crop;
  CompactImageCompressionResult? _result;
  List<CompactImageCodecCapability> _capabilities = const [];
  double _sourceAspect = 1;
  String? _error;
  bool _loading = false;
  bool _comparisonStarted = false;
  int _imageGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = widget.service ?? context.read<CompactImageCodecService>();
    if (identical(service, _service)) return;
    _service?.removeListener(_changed);
    _service = service;
    service.addListener(_changed);
    unawaited(_loadCapabilities(service));
    final initial = widget.initialImageBytes;
    if (_source == null && initial != null) {
      unawaited(_setImage(initial));
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCapabilities(CompactImageCodecService service) async {
    try {
      final capabilities = await service.capabilities();
      if (mounted && identical(_service, service)) {
        setState(() => _capabilities = capabilities);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not check the image codecs.');
      }
    }
  }

  Future<void> _setImage(Uint8List bytes) async {
    final generation = ++_imageGeneration;
    ui.Codec? decoder;
    ui.Image? image;
    try {
      final displayBytes = await compute(
        CompactImagePreparation.previewInput,
        bytes,
      );
      decoder = await ui.instantiateImageCodec(
        displayBytes,
        targetWidth: 256,
        allowUpscaling: false,
      );
      image = (await decoder.getNextFrame()).image;
      final aspect = image.width / image.height;
      if (!mounted || generation != _imageGeneration) return;
      setState(() {
        _source = bytes;
        _displaySource = displayBytes;
        _sourceAspect = aspect;
        _crop = null;
        _result = null;
        _comparisonStarted = false;
        _error = null;
      });
      _service?.setCrop(null);
    } catch (_) {
      if (mounted && generation == _imageGeneration) {
        setState(() => _error = 'This image could not be opened.');
      }
    } finally {
      image?.dispose();
      decoder?.dispose();
    }
  }

  Future<void> _pickImage() async {
    setState(() => _loading = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (file != null) await _setImage(await file.readAsBytes());
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not read the selected image.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sample() async {
    setState(() => _loading = true);
    try {
      final data = await rootBundle.load(
        'assets/image_compression/sample_photo.png',
      );
      await _setImage(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the sample photo.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _compress() async {
    final service = _service;
    final source = _source;
    if (service == null || source == null || service.isBusy) return;
    setState(() {
      _error = null;
      _result = null;
      _comparisonStarted = true;
    });
    try {
      final result = await service.compress(
        source,
        targetBytes: service.targetBytes,
        crop: _crop,
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        setState(() => _error = compactImageCompressionError(error, service));
      }
    }
  }

  Future<void> _cancel() async {
    final service = _service!;
    try {
      await service.cancelEncode();
    } catch (error) {
      if (mounted) {
        setState(() => _error = compactImageCompressionError(error, service));
      }
    }
  }

  @override
  void dispose() {
    _imageGeneration++;
    _service?.removeListener(_changed);
    // An encode belongs to this screen. Let the service stop native workers
    // before another route starts using the same codec instance.
    if (_service?.isBusy == true) {
      unawaited(_service!.cancelEncode().catchError((Object error) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = _service!;
    final busy = service.isBusy;
    final result = _result;
    final attempts =
        result?.attempts ??
        (_comparisonStarted
            ? service.attempts
            : const <CompactImageCodecAttempt>[]);
    return Scaffold(
      appBar: AppBar(title: const AdaptiveAppBarTitle('Image compression')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            const Text(
              'Compress on this phone. Each codec has a 2 minute limit. '
              'The preview is decoded from the compressed file.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('compression-pick-image'),
                  onPressed: busy || _loading ? null : _pickImage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose photo'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('compression-sample'),
                  onPressed: busy || _loading ? null : _sample,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Sample photo'),
                ),
              ],
            ),
            if (_source != null) ...[
              const SizedBox(height: 12),
              CompactImageCropPreview(
                bytes: _displaySource!,
                aspectRatio: _sourceAspect,
                crop: _crop,
              ),
              CompactImageCropControls(
                key: ValueKey(_imageGeneration),
                sourceAspectRatio: _sourceAspect,
                enabled: !busy && !_loading,
                onChanged: (crop) {
                  service.setCrop(crop);
                  setState(() {
                    _crop = crop;
                    _result = null;
                    _comparisonStarted = false;
                  });
                },
              ),
            ],
            const SizedBox(height: 8),
            CompactImagePacketBudgetSelector(
              packetBudget: service.packetBudget,
              includeParity: service.budgetIncludesParity,
              targetBytes: service.targetBytes,
              enabled: !busy && !_loading,
              onChanged: (packets) {
                service.setPacketBudget(
                  packets,
                  includeParity: service.budgetIncludesParity,
                );
                setState(() {
                  _result = null;
                  _comparisonStarted = false;
                });
              },
            ),
            SwitchListTile(
              key: const ValueKey('compression-parity-budget'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Include recovery packet'),
              subtitle: const Text('Counts toward the total packet budget'),
              value: service.budgetIncludesParity,
              onChanged: busy || _loading
                  ? null
                  : (includeParity) {
                      final minimum = includeParity ? 2 : 1;
                      final maximum = includeParity ? 16 : 15;
                      final packets = service.packetBudget.clamp(
                        minimum,
                        maximum,
                      );
                      service.setPacketBudget(
                        packets,
                        includeParity: includeParity,
                      );
                      setState(() {
                        _result = null;
                        _comparisonStarted = false;
                      });
                    },
            ),
            CompactImageTargetSelector(
              targetBytes: service.targetBytes,
              enabled: !busy && !_loading,
              onChanged: (bytes) {
                service.setTargetBytes(bytes);
                setState(() {
                  _result = null;
                  _comparisonStarted = false;
                });
              },
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: service.progress),
              const SizedBox(height: 6),
              Text(service.stage ?? 'Compressing image'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 16),
              Text(
                'Decoded PNG preview',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              CompactImageCropPreview(
                key: const ValueKey('compression-decoded-preview'),
                bytes: result.previewPng,
                aspectRatio: result.width / result.height,
              ),
              const SizedBox(height: 8),
              Text(
                '${result.codec.label}: ${result.payload.length} bytes, '
                '${result.width} x ${result.height}, '
                '${result.blockSize} x ${result.blockSize} blocks',
              ),
              const Text('Source metadata removed.'),
              Text(
                'Uses ${imageDataChunkCount(result.payload.length) + (service.budgetIncludesParity ? 1 : 0)} '
                'of ${service.packetBudget} LoRa packets'
                '${service.budgetIncludesParity ? ', including recovery' : ''}.',
              ),
              if (result.payload.length > service.targetBytes)
                Text(
                  'This result exceeds the selected size.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
            if (attempts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Comparison results',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final attempt in attempts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(attempt.codec.label),
                  subtitle: Text(_attemptSummary(attempt)),
                ),
            ],
            if (!busy &&
                result == null &&
                attempts.isEmpty &&
                _capabilities.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Codecs on this phone',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final capability in _capabilities)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(capability.codec.label),
                  subtitle: Text(
                    capability.available
                        ? 'Available'
                        : capability.reason ?? 'Unavailable',
                  ),
                ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('compression-compare'),
                onPressed: busy || _source == null || _loading
                    ? null
                    : _compress,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.compress),
                label: Text(busy ? 'Comparing' : 'Compare codecs'),
              ),
            ),
            if (busy) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('compression-cancel'),
                  onPressed: _cancel,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _attemptSummary(CompactImageCodecAttempt attempt) {
    final status = switch (attempt.status) {
      CompactImageCodecAttemptStatus.completed => 'Completed',
      CompactImageCodecAttemptStatus.unavailable => 'Unavailable',
      CompactImageCodecAttemptStatus.timedOut => 'Stopped at 2 minutes',
      CompactImageCodecAttemptStatus.failed => 'Failed',
      CompactImageCodecAttemptStatus.overBudget => 'Above target size',
    };
    final size = attempt.encodedBytes == null
        ? ''
        : ', ${attempt.encodedBytes} bytes';
    final time = ', ${(attempt.elapsedMs / 1000).toStringAsFixed(1)} s';
    final reason = attempt.reason == null ? '' : '\n${attempt.reason}';
    return '$status$size$time$reason';
  }
}

class CompactImagePacketBudgetSelector extends StatelessWidget {
  const CompactImagePacketBudgetSelector({
    super.key,
    required this.packetBudget,
    required this.includeParity,
    required this.targetBytes,
    required this.onChanged,
    this.enabled = true,
  });

  final int packetBudget;
  final bool includeParity;
  final int targetBytes;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<int>(
        key: const ValueKey('compression-packet-budget'),
        // The pinned API22-compatible Flutter predates initialValue.
        // ignore: deprecated_member_use
        value: packetBudget,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Total LoRa packets'),
        items: [
          for (
            var packets = includeParity ? 2 : 1;
            packets <= (includeParity ? 16 : 15);
            packets++
          )
            DropdownMenuItem(
              value: packets,
              child: Text('$packets total packets'),
            ),
        ],
        onChanged: enabled
            ? (value) {
                if (value != null) onChanged(value);
              }
            : null,
      ),
      const SizedBox(height: 6),
      Text(
        '${packetBudget - (includeParity ? 1 : 0)} data'
        '${includeParity ? ' + 1 recovery packet' : ' packets'}, '
        '$targetBytes bytes maximum.',
      ),
    ],
  );
}

String compactImageCompressionError(
  Object error,
  CompactImageCodecService service,
) {
  if (error is StateError &&
      error.message.toString().contains('verified image')) {
    return "Can't fit within ${service.packetBudget} packets at 128 pixels or larger. "
        'Choose more packets or a different crop.';
  }
  return error.toString().replaceFirst('Exception: ', '');
}

class CompactImageTargetSelector extends StatelessWidget {
  const CompactImageTargetSelector({
    super.key,
    required this.targetBytes,
    required this.onChanged,
    this.enabled = true,
  });

  final int targetBytes;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('Target size'),
      for (final bytes in [1024, 2048])
        ChoiceChip(
          key: ValueKey('compression-target-$bytes'),
          label: Text('${bytes ~/ 1024} KB'),
          selected: targetBytes == bytes,
          onSelected: enabled ? (_) => onChanged(bytes) : null,
        ),
    ],
  );
}

/// Shared crop editor for local comparisons and the actual send preview.
class CompactImageCropControls extends StatefulWidget {
  const CompactImageCropControls({
    super.key,
    required this.sourceAspectRatio,
    required this.onChanged,
    this.enabled = true,
  });

  final double sourceAspectRatio;
  final ValueChanged<CompactImageCrop?> onChanged;
  final bool enabled;

  @override
  State<CompactImageCropControls> createState() =>
      _CompactImageCropControlsState();
}

class _CompactImageCropControlsState extends State<CompactImageCropControls> {
  String _mode = 'Original';
  double _horizontal = 0.5;
  double _vertical = 0.5;

  (double, double) get _dimensions {
    final ratio = switch (_mode) {
      'Square' => 1.0,
      '4:3' => 4 / 3,
      '3:4' => 3 / 4,
      _ => widget.sourceAspectRatio,
    };
    final source = widget.sourceAspectRatio;
    return source > ratio ? (ratio / source, 1.0) : (1.0, source / ratio);
  }

  void _update() {
    if (_mode == 'Original') {
      widget.onChanged(null);
      return;
    }
    final (width, height) = _dimensions;
    final left = (1 - width) * _horizontal;
    final top = (1 - height) * _vertical;
    widget.onChanged(
      CompactImageCrop(
        left: left,
        top: top,
        right: left + width,
        bottom: top + height,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (width, height) = _dimensions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Crop'),
            for (final mode in ['Original', 'Square', '4:3', '3:4'])
              ChoiceChip(
                key: ValueKey('compression-crop-$mode'),
                label: Text(mode),
                selected: _mode == mode,
                onSelected: widget.enabled
                    ? (_) {
                        setState(() => _mode = mode);
                        _update();
                      }
                    : null,
              ),
          ],
        ),
        if (_mode != 'Original' && width < 0.999)
          _position('Horizontal position', _horizontal, (value) {
            setState(() => _horizontal = value);
            _update();
          }),
        if (_mode != 'Original' && height < 0.999)
          _position('Vertical position', _vertical, (value) {
            setState(() => _vertical = value);
            _update();
          }),
      ],
    );
  }

  Widget _position(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      Expanded(
        flex: 2,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        flex: 3,
        child: Slider(
          value: value,
          onChanged: widget.enabled ? onChanged : null,
        ),
      ),
    ],
  );
}

class CompactImageCropPreview extends StatelessWidget {
  const CompactImageCropPreview({
    super.key,
    required this.bytes,
    required this.aspectRatio,
    this.crop,
  });

  final Uint8List bytes;
  final double aspectRatio;
  final CompactImageCrop? crop;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180, maxWidth: 288),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              bytes,
              cacheWidth: 256,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, error, stack) =>
                  const Center(child: Icon(Icons.broken_image_outlined)),
            ),
            if (crop != null)
              LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [
                    Positioned(
                      left: crop!.left * constraints.maxWidth,
                      top: crop!.top * constraints.maxHeight,
                      width: (crop!.right - crop!.left) * constraints.maxWidth,
                      height:
                          (crop!.bottom - crop!.top) * constraints.maxHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
