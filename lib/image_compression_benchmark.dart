/// Hardware test entry point. The normal app uses the same production service.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';

import 'services/compact_image_codec_service.dart';
import 'services/image_chunk_transport.dart';
import 'widgets/image_send_codec_binding.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Benchmark()));
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final _service = CompactImageCodecService();
  String _status = 'Preparing local codec benchmark';
  Uint8List? _preview;
  final List<Map<String, Object?>> _runs = [];

  @override
  void initState() {
    super.initState();
    _service.addListener(() {
      if (mounted) setState(() => _status = _service.stage ?? _status);
    });
    unawaited(_run());
  }

  Future<void> _run() async {
    var directory = await getApplicationDocumentsDirectory();
    if (Platform.isAndroid && const bool.fromEnvironment('LEGACY_ARM32')) {
      // This test entry point only handles the bundled public fixtures.
      directory = Directory(
        '/storage/emulated/0/Download/MeshCore-image-compression-test',
      );
      await directory.create(recursive: true);
    }
    final reportFile = File(
      '${directory.path}/image-compression-benchmark.json',
    );
    final report = <String, Object?>{
      'schema': 1,
      'platform': Platform.operatingSystem,
      'system_version': Platform.operatingSystemVersion,
      'per_algorithm_limit_ms': 120000,
      'capabilities': [
        for (final cap in await _service.capabilities())
          {
            'codec': cap.codec.wireName,
            'available': cap.available,
            if (cap.reason != null) 'reason': cap.reason,
          },
      ],
      'runs': _runs,
    };
    final source = (await rootBundle.load(
      'assets/image_compression/sample_photo.png',
    )).buffer.asUint8List();
    final diagram = image.Image(width: 239, height: 173, numChannels: 4);
    diagram.clear(image.ColorRgba8(250, 250, 250, 255));
    image.drawRect(
      diagram,
      x1: 28,
      y1: 30,
      x2: 108,
      y2: 135,
      color: image.ColorRgba8(30, 60, 140, 255),
      thickness: 4,
    );
    image.drawCircle(
      diagram,
      x: 170,
      y: 86,
      radius: 42,
      color: image.ColorRgba8(190, 50, 30, 255),
    );
    image.drawLine(
      diagram,
      x1: 108,
      y1: 83,
      x2: 130,
      y2: 83,
      color: image.ColorRgba8(30, 30, 30, 255),
      thickness: 3,
    );
    final cases = <String, Uint8List>{
      'portrait_512': source,
      'diagram_239x173': image.encodePng(diagram),
    };
    try {
      for (final entry in cases.entries) {
        for (final target in [
          2048,
          1024,
          if (entry.key == 'diagram_239x173') 473,
        ]) {
          _service.setTargetBytes(target);
          if (target == 473) _service.setPacketBudget(4);
          final started = Stopwatch()..start();
          final result = await _service.compress(
            entry.value,
            targetBytes: target,
          );
          final chunks = buildImageChunks(
            payload: result.payload,
            metadata: const ImageStreamMetadata(
              rate: ImageCodecRatePoint.compact,
            ),
            senderPrefix: 0x0102,
            imgId: _runs.length + 1,
            parity: true,
          );
          ImageReassemblyResult? reassembled;
          final reassembler = ImageReassembler(
            onImage: (value) {
              reassembled = value;
            },
          );
          // Deliver backwards and lose one data packet: exercise XOR recovery.
          for (var i = chunks.blobs.length - 1; i >= 0; i--) {
            if (i == 0) continue;
            reassembler.addChunk(chunks.blobs[i], channelIndex: 0);
          }
          final reconstructed = reassembled;
          if (reconstructed == null ||
              !reconstructed.recoveredWithParity ||
              reconstructed.metadata?.rate != ImageCodecRatePoint.compact) {
            throw StateError(
              'Parity reassembly did not reconstruct the compact image.',
            );
          }
          final receiver = CompactImageCodecService();
          late Uint8List receivedPng;
          try {
            receivedPng = await receiver.decodeToPng(reconstructed.data);
          } finally {
            receiver.dispose();
          }
          if (!_same(receivedPng, result.previewPng) ||
              result.payload.length > target ||
              chunks.blobs.length > _service.packetBudget) {
            throw StateError(
              'The receiving PNG differs or the target was exceeded.',
            );
          }
          final name = '${entry.key}-$target';
          await File('${directory.path}/$name.png').writeAsBytes(receivedPng);
          await File(
            '${directory.path}/$name.mci',
          ).writeAsBytes(result.payload);
          _runs.add({
            'case': entry.key,
            'source_bytes': entry.value.length,
            'target_bytes': target,
            'selected_total_packet_budget': _service.packetBudget,
            'elapsed_ms': started.elapsedMilliseconds,
            'data_packets': chunks.dataChunkCount,
            'total_packets': chunks.blobs.length,
            'receiver_png_identical': true,
            'parity_recovery_verified': true,
            ...result.toJson(),
          });
          await reportFile.writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          );
          if (mounted) setState(() => _preview = receivedPng);
          _emit('RESULT', _runs.last);
        }
      }
      report['success'] = true;
      if (mounted) {
        setState(
          () => _status = 'Benchmark passed: ${_runs.length} image round trips',
        );
      }
    } catch (error, stack) {
      report['success'] = false;
      report['error'] = error.toString();
      debugPrint('$error\n$stack');
      if (mounted) setState(() => _status = 'Benchmark failed: $error');
    } finally {
      await reportFile.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
      _emit('DONE', report);
    }
  }

  bool _same(Uint8List left, Uint8List right) =>
      left.length == right.length &&
      List.generate(left.length, (i) => left[i] == right[i]).every((v) => v);

  void _emit(String kind, Map<String, Object?> value) {
    final encoded = jsonEncode(value);
    final count = (encoded.length / 400).ceil();
    for (var index = 0; index < count; index++) {
      final end = (index + 1) * 400;
      debugPrint(
        'IMAGE_COMPRESSION_${kind}_PART $index/$count '
        '${encoded.substring(index * 400, end > encoded.length ? encoded.length : end)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Image compression test')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_status),
        if (_service.isBusy) const LinearProgressIndicator(),
        if (_preview != null)
          Image.memory(_preview!, height: 200, fit: BoxFit.contain),
        for (final run in _runs)
          Text(
            '${run['case']}: ${run['codec']} ${run['payload_bytes']} bytes, ${run['width']}x${run['height']}',
          ),
        const Text('All encoding and decoding runs locally on this phone.'),
      ],
    ),
  );
}
