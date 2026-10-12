import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'usb_flash_transport.dart';
import 'usb_firmware_package.dart';

/// Legacy Adafruit USB serial DFU, not Nordic's BLE/secure DFU protocol.
/// Wire format follows adafruit-nrfutil's published HCI/SLIP protocol.
class UsbNrfDfuPackage {
  UsbNrfDfuPackage._(
    this.name,
    this.application,
    this.initPacket,
    this.sha256,
    this.hardwareId,
    this.firmwareVersion,
  ) : _applicationSha256 = crypto.sha256.convert(application).toString(),
      _initSha256 = crypto.sha256.convert(initPacket).toString();

  final String name;
  final Uint8List application;
  final Uint8List initPacket;
  final String sha256;
  final String? hardwareId;
  final String? firmwareVersion;
  final String _applicationSha256;
  final String _initSha256;

  factory UsbNrfDfuPackage.fromBytes(String name, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('Invalid nRF52 application ZIP size');
    }
    final files = checkedZipEntries(
      bytes,
      maxArchiveBytes: 4 * 1024 * 1024,
      maxExpandedBytes: 2 * 1024 * 1024,
      maxEntries: 3,
    );
    final manifestFile = files['manifest.json'];
    if (manifestFile == null || manifestFile.length > 64 * 1024) {
      throw const FormatException('nRF52 ZIP has no bounded manifest');
    }
    final decoded = usbStrictJson(manifestFile);
    if (decoded is! Map || decoded['manifest'] is! Map) {
      throw const FormatException('Invalid nRF52 manifest');
    }
    final manifest = decoded['manifest'] as Map;
    if (manifest.keys.any(
          (key) => key != 'application' && key != 'dfu_version',
        ) ||
        manifest['application'] is! Map ||
        (manifest['dfu_version'] != null && manifest['dfu_version'] != 0.5)) {
      throw const FormatException(
        'Only legacy application-only DFU is supported; bootloader and SoftDevice packages are prohibited',
      );
    }
    final app = manifest['application'] as Map;
    final binName = app['bin_file'];
    final datName = app['dat_file'];
    if (binName is! String ||
        datName is! String ||
        binName == datName ||
        files.length != 3 ||
        !files.containsKey(binName) ||
        !files.containsKey(datName)) {
      throw const FormatException(
        'nRF52 ZIP inventory does not match manifest',
      );
    }
    final application = Uint8List.fromList(files[binName]!);
    final init = Uint8List.fromList(files[datName]!);
    if (application.isEmpty ||
        application.length > 900 * 1024 ||
        init.length < 12) {
      throw const FormatException(
        'Invalid nRF52 application/init packet length',
      );
    }
    final data = ByteData.sublistView(init);
    final requiredCount = data.getUint16(8, Endian.little);
    final crcOffset = 10 + requiredCount * 2;
    if (requiredCount > 32 ||
        init.length != crcOffset + 2 ||
        data.getUint16(crcOffset, Endian.little) != nrfDfuCrc16(application)) {
      throw const FormatException(
        'nRF52 init packet CRC does not match application',
      );
    }
    final initMetadata = app['init_packet_data'];
    if (initMetadata is Map &&
        initMetadata['firmware_crc16'] != null &&
        initMetadata['firmware_crc16'] != nrfDfuCrc16(application)) {
      throw const FormatException(
        'nRF52 manifest CRC does not match application',
      );
    }
    String? hardware;
    String? version;
    if (application.length >= 56) {
      final tail = application.sublist(application.length - 56);
      if (ascii.decode(tail.sublist(0, 4), allowInvalid: true) == 'EndF') {
        final tailData = ByteData.sublistView(tail);
        final body = application.sublist(0, application.length - 56);
        if (tailData.getUint32(4, Endian.little) != body.length ||
            !_same(
              tail.sublist(8, 16),
              crypto.sha256.convert(body).bytes.sublist(0, 8),
            ) ||
            tailData.getUint32(16, Endian.little) == 0) {
          throw const FormatException(
            'MeshCore EndF identity verification failed',
          );
        }
        hardware = ascii
            .decode(tail.sublist(24), allowInvalid: false)
            .split('\x00')
            .first;
        final packed = tailData.getUint32(16, Endian.little);
        version =
            '${packed >> 24}.${(packed >> 16) & 255}.${(packed >> 8) & 255}.${packed & 255}';
        if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(hardware)) {
          throw const FormatException('Invalid MeshCore hardware identity');
        }
      }
    }
    return UsbNrfDfuPackage._(
      name,
      application,
      init,
      crypto.sha256.convert(bytes).toString(),
      hardware,
      version,
    );
  }
}

class UsbNrfDfuResult {
  const UsbNrfDfuResult(this.bytesWritten, this.packageSha256);
  final int bytesWritten;
  final String packageSha256;
  bool get transportVerified => true;
  // Legacy bootloader ACKs prove reception, not a running application.
  bool get applicationBootVerified => false;
}

class UsbNrfDfuUpdater {
  UsbNrfDfuUpdater(this.transport, {Future<void> Function(Duration)? delay})
    : _delay = delay ?? Future<void>.delayed;

  final UsbFlashTransport transport;
  final Future<void> Function(Duration) _delay;
  final List<int> _receive = [];
  int _sequence = 0;

  /// The caller owns DFU mode, physical identity matching, and port open/close.
  /// The caller must reconnect and verify application identity after this.
  Future<UsbNrfDfuResult> flash(
    UsbNrfDfuPackage package, {
    UsbFlashDevice? expectedDevice,
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (expectedDevice != null &&
        (transport.activeDevice == null ||
            !expectedDevice.matchesAfterReenumeration(
              transport.activeDevice!,
            ))) {
      throw StateError('nRF52 DFU USB identity changed before flashing');
    }
    // Package buffers are mutable; check again immediately before any write.
    final dat = ByteData.sublistView(package.initPacket);
    final crcOffset = 10 + dat.getUint16(8, Endian.little) * 2;
    if (crypto.sha256.convert(package.application).toString() !=
            package._applicationSha256 ||
        crypto.sha256.convert(package.initPacket).toString() !=
            package._initSha256 ||
        crcOffset + 2 != package.initPacket.length ||
        dat.getUint16(crcOffset, Endian.little) !=
            nrfDfuCrc16(package.application)) {
      throw StateError('DFU payload changed after validation');
    }
    _sequence = 0;
    _receive.clear();
    await transport.setSignals(dtr: true, rts: false);
    await transport.purge();
    onProgress?.call(0, 'Preparing application DFU');
    await _send(_words([3, 4, 0, 0, package.application.length]));
    final pages = package.application.length ~/ 4096 + 1;
    await _delay(
      Duration(milliseconds: (pages * 89.7).ceil().clamp(500, 30000)),
    );
    await _send(
      Uint8List.fromList([
        ..._words([1]),
        ...package.initPacket,
        0,
        0,
      ]),
    );
    for (var offset = 0; offset < package.application.length; offset += 512) {
      final end = (offset + 512).clamp(0, package.application.length);
      await _send(
        Uint8List.fromList([
          ..._words([4]),
          ...package.application.sublist(offset, end),
        ]),
      );
      onProgress?.call(
        end / package.application.length * .95,
        'Writing application',
      );
      // Adafruit bootloaders block during flash writes: never reset meanwhile.
      if ((offset ~/ 512) % 8 == 0) {
        await _delay(const Duration(milliseconds: 205));
      }
    }
    await _delay(const Duration(milliseconds: 205));
    await _send(_words([5]));
    onProgress?.call(.96, 'Activating application; do not unplug');
    // Dual-bank activation erases bank0 and copies bank1. Keep the port quiet.
    await _delay(Duration(milliseconds: (pages * (89.7 + 204.8)).ceil()));
    onProgress?.call(
      1,
      'DFU transport completed; application verification required',
    );
    return UsbNrfDfuResult(package.application.length, package.sha256);
  }

  Future<void> _send(Uint8List payload) async {
    _sequence = (_sequence + 1) & 7;
    final packet = nrfDfuHciPacket(payload, _sequence);
    for (var attempt = 0; attempt < 3; attempt++) {
      await transport.write(packet);
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 2)) {
        final ack = await _readAck(const Duration(milliseconds: 250));
        if (ack == ((_sequence + 1) & 7)) return;
      }
    }
    throw TimeoutException('nRF52 DFU did not acknowledge packet $_sequence');
  }

  Future<int?> _readAck(Duration timeout) async {
    final input = await transport.read(timeout: timeout);
    _receive.addAll(input);
    if (_receive.length > 4096) {
      throw const FormatException('DFU reply exceeds limit');
    }
    while (true) {
      final start = _receive.indexOf(0xc0);
      if (start < 0) {
        _receive.clear();
        return null;
      }
      if (start > 0) _receive.removeRange(0, start);
      final end = _receive.indexOf(0xc0, 1);
      if (end < 0) return null;
      final escaped = _receive.sublist(1, end);
      _receive.removeRange(0, end);
      if (escaped.isEmpty) {
        continue;
      }
      final frame = nrfDfuSlipDecode(escaped);
      if (frame.length < 4 ||
          ((frame[0] + frame[1] + frame[2] + frame[3]) & 0xff) != 0) {
        throw const FormatException('DFU ACK header checksum failed');
      }
      final length = (frame[1] >> 4) | (frame[2] << 4);
      final hasCrc = (frame[0] & 0x40) != 0;
      if ((frame[1] & 0xf) != 0 ||
          length != 0 ||
          frame.length != 4 + (hasCrc ? 2 : 0)) {
        throw const FormatException('Malformed DFU acknowledgement');
      }
      if (hasCrc &&
          nrfDfuCrc16(frame.sublist(0, 4)) != (frame[4] | frame[5] << 8)) {
        throw const FormatException('DFU ACK CRC failed');
      }
      return (frame[0] >> 3) & 7;
    }
  }
}

int nrfDfuCrc16(List<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
    }
  }
  return crc;
}

Uint8List nrfDfuHciPacket(Uint8List payload, int sequence) {
  final header = [
    sequence | (((sequence + 1) & 7) << 3) | 0xc0,
    0xe | ((payload.length & 0xf) << 4),
    (payload.length >> 4) & 0xff,
    0,
  ];
  header[3] = -(header[0] + header[1] + header[2]) & 0xff;
  final body = [...header, ...payload];
  final crc = nrfDfuCrc16(body);
  return nrfDfuSlipEncode([...body, crc & 0xff, crc >> 8]);
}

Uint8List nrfDfuSlipEncode(List<int> body) {
  final result = <int>[0xc0];
  for (final byte in body) {
    if (byte == 0xc0) {
      result.addAll([0xdb, 0xdc]);
    } else if (byte == 0xdb) {
      result.addAll([0xdb, 0xdd]);
    } else {
      result.add(byte);
    }
  }
  return Uint8List.fromList([...result, 0xc0]);
}

Uint8List nrfDfuSlipDecode(List<int> bytes) {
  final result = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != 0xdb) {
      result.add(bytes[i]);
      continue;
    }
    if (++i >= bytes.length || (bytes[i] != 0xdc && bytes[i] != 0xdd)) {
      throw const FormatException('Invalid DFU SLIP escape');
    }
    result.add(bytes[i] == 0xdc ? 0xc0 : 0xdb);
  }
  return Uint8List.fromList(result);
}

Uint8List _words(List<int> values) {
  final result = Uint8List(values.length * 4);
  final view = ByteData.sublistView(result);
  for (var i = 0; i < values.length; i++) {
    view.setUint32(i * 4, values[i], Endian.little);
  }
  return result;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
