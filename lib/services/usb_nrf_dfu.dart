import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'usb_flash_transport.dart';
import 'usb_firmware_package.dart';

/// Legacy Adafruit USB serial DFU, not Nordic's BLE/secure DFU protocol.
/// Wire format follows adafruit-nrfutil's published HCI/SLIP protocol.
enum UsbNrfDfuKind { application, bootloader, softdeviceBootloader, softdevice }

class UsbNrfDfuPackage {
  UsbNrfDfuPackage._(
    this.name,
    this.payload,
    this.initPacket,
    this.sha256,
    this.hardwareId,
    this.firmwareVersion,
    this.kind,
    this.softdeviceSize,
    this.bootloaderSize,
    this.applicationSize,
    this.deviceType,
    this.deviceRevision,
    this.requiredSoftdevices,
    this.isUnverified,
    List<String> warnings,
  ) : _payloadSha256 = crypto.sha256.convert(payload).toString(),
      _initSha256 = crypto.sha256.convert(initPacket).toString(),
      warnings = List.unmodifiable(warnings);

  final String name;
  final Uint8List payload;
  // Retained for existing application-only callers. New code uses payload.
  Uint8List get application => payload;
  final Uint8List initPacket;
  final String sha256;
  final String? hardwareId;
  final String? firmwareVersion;
  final UsbNrfDfuKind kind;
  final int softdeviceSize;
  final int bootloaderSize;
  final int applicationSize;
  final int deviceType;
  final int deviceRevision;
  final List<int> requiredSoftdevices;
  final bool isUnverified;
  final List<String> warnings;
  final String _payloadSha256;
  final String _initSha256;
  bool get isBootloaderUpdate => kind != UsbNrfDfuKind.application;
  int get dfuMode => switch (kind) {
    UsbNrfDfuKind.application => 4,
    UsbNrfDfuKind.bootloader => 2,
    UsbNrfDfuKind.softdeviceBootloader => 3,
    UsbNrfDfuKind.softdevice => 1,
  };
  String get displayName => switch (kind) {
    UsbNrfDfuKind.application => 'Application',
    UsbNrfDfuKind.bootloader => 'Bootloader',
    UsbNrfDfuKind.softdeviceBootloader => 'SoftDevice + bootloader',
    UsbNrfDfuKind.softdevice => 'SoftDevice',
  };

  factory UsbNrfDfuPackage.fromBytes(
    String name,
    Uint8List bytes, {
    bool allowUnverified = false,
  }) {
    final warnings = <String>[];
    void verify(bool valid, String message) {
      if (valid) return;
      if (!allowUnverified) throw FormatException(message);
      warnings.add(message);
    }

    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('Invalid nRF52 DFU ZIP size');
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
    final components = {
      'application': UsbNrfDfuKind.application,
      'bootloader': UsbNrfDfuKind.bootloader,
      'softdevice_bootloader': UsbNrfDfuKind.softdeviceBootloader,
      if (allowUnverified) 'softdevice': UsbNrfDfuKind.softdevice,
    };
    final present = components.keys.where(manifest.containsKey).toList();
    if (manifest.keys.any(
          (key) => key != 'dfu_version' && !components.containsKey(key),
        ) ||
        present.length != 1 ||
        manifest[present.single] is! Map ||
        (manifest['dfu_version'] != null && manifest['dfu_version'] != 0.5)) {
      throw const FormatException(
        'Only one legacy application, bootloader, or combined SoftDevice/bootloader image is supported; mixed images and secure DFU are refused',
      );
    }
    final kind = components[present.single]!;
    final image = manifest[present.single] as Map;
    final binName = image['bin_file'];
    final datName = image['dat_file'];
    if (binName is! String ||
        datName is! String ||
        binName == datName ||
        binName == 'manifest.json' ||
        datName == 'manifest.json' ||
        files.length != 3 ||
        !files.containsKey(binName) ||
        !files.containsKey(datName)) {
      throw const FormatException(
        'nRF52 ZIP inventory does not match manifest',
      );
    }
    final payload = Uint8List.fromList(files[binName]!).asUnmodifiableView();
    final init = Uint8List.fromList(files[datName]!).asUnmodifiableView();
    if (payload.isEmpty ||
        payload.length > 900 * 1024 ||
        payload.length % 4 != 0 ||
        init.length < 12) {
      throw const FormatException(
        'Invalid nRF52 firmware/init packet length or word alignment',
      );
    }
    var softdeviceSize = 0;
    var bootloaderSize = 0;
    var applicationSize = 0;
    switch (kind) {
      case UsbNrfDfuKind.application:
        applicationSize = payload.length;
      case UsbNrfDfuKind.bootloader:
        bootloaderSize = payload.length;
      case UsbNrfDfuKind.softdevice:
        softdeviceSize = payload.length;
        warnings.add(
          'Standalone SoftDevice replacement is an expert-only DFU attempt.',
        );
      case UsbNrfDfuKind.softdeviceBootloader:
        final sd = image['sd_size'];
        final bl = image['bl_size'];
        if (sd is! int ||
            bl is! int ||
            sd <= 0 ||
            bl <= 0 ||
            sd % 4 != 0 ||
            bl % 4 != 0 ||
            sd + bl != payload.length) {
          throw const FormatException(
            'Combined DFU requires word-aligned sd_size and bl_size matching the complete BIN',
          );
        }
        softdeviceSize = sd;
        bootloaderSize = bl;
    }
    if (kind != UsbNrfDfuKind.softdeviceBootloader &&
        (image.containsKey('sd_size') || image.containsKey('bl_size'))) {
      throw const FormatException('Component sizes do not match the DFU kind');
    }
    final data = ByteData.sublistView(init);
    final requiredCount = data.getUint16(8, Endian.little);
    final crcOffset = 10 + requiredCount * 2;
    if (requiredCount > 32 || init.length != crcOffset + 2) {
      throw const FormatException('Invalid legacy DFU init packet structure');
    }
    verify(
      data.getUint16(crcOffset, Endian.little) == nrfDfuCrc16(payload),
      'DFU init CRC does not match the provided firmware; the device may reject it.',
    );
    final required = List<int>.unmodifiable([
      for (var index = 0; index < requiredCount; index++)
        data.getUint16(10 + index * 2, Endian.little),
    ]);
    final deviceType = data.getUint16(0, Endian.little);
    final deviceRevision = data.getUint16(2, Endian.little);
    verify(
      deviceType == 0x52 || deviceType == 0xffff,
      'Legacy DFU init packet is not declared for an nRF52 device.',
    );
    final initMetadata = image['init_packet_data'];
    if (initMetadata != null) {
      verify(
        initMetadata is Map &&
            !initMetadata.keys.any(
              (key) => !const {
                'device_type',
                'device_revision',
                'application_version',
                'softdevice_req',
                'firmware_crc16',
              }.contains(key),
            ),
        'Unsupported or inconsistent legacy DFU manifest metadata.',
      );
    }
    if (initMetadata is Map) {
      final expected = <String, int>{
        'device_type': deviceType,
        'device_revision': deviceRevision,
        'application_version': data.getUint32(4, Endian.little),
        'firmware_crc16': data.getUint16(crcOffset, Endian.little),
      };
      verify(
        !expected.entries.any(
          (entry) =>
              initMetadata.containsKey(entry.key) &&
              (initMetadata[entry.key] is! int ||
                  initMetadata[entry.key] != entry.value),
        ),
        'nRF52 manifest and provided DAT metadata disagree.',
      );
      if (initMetadata.containsKey('softdevice_req')) {
        final declared = initMetadata['softdevice_req'];
        verify(
          declared is List &&
              !declared.any((value) => value is! int) &&
              _same(declared.cast<int>(), required),
          'Manifest and provided DAT SoftDevice requirements disagree.',
        );
      }
    }
    String? hardware;
    String? version;
    if (kind == UsbNrfDfuKind.application && payload.length >= 56) {
      final tail = payload.sublist(payload.length - 56);
      if (ascii.decode(tail.sublist(0, 4), allowInvalid: true) == 'EndF') {
        final tailData = ByteData.sublistView(tail);
        final body = payload.sublist(0, payload.length - 56);
        final validIdentity =
            tailData.getUint32(4, Endian.little) == body.length &&
            _same(
              tail.sublist(8, 16),
              crypto.sha256.convert(body).bytes.sublist(0, 8),
            ) &&
            tailData.getUint32(16, Endian.little) != 0;
        verify(validIdentity, 'MeshCore EndF identity verification failed.');
        if (validIdentity) {
          final field = tail
              .sublist(24)
              .takeWhile((byte) => byte != 0)
              .toList();
          final validHardware =
              tail.sublist(24).every((byte) => byte <= 0x7f) &&
              RegExp(
                r'^[A-Za-z0-9_-]{1,32}$',
              ).hasMatch(ascii.decode(field, allowInvalid: true));
          verify(validHardware, 'Invalid MeshCore hardware identity.');
          if (validHardware) {
            hardware = ascii.decode(field);
            final packed = tailData.getUint32(16, Endian.little);
            version =
                '${packed >> 24}.${(packed >> 16) & 255}.${(packed >> 8) & 255}.${packed & 255}';
          }
        }
      }
    }
    return UsbNrfDfuPackage._(
      name,
      payload,
      init,
      crypto.sha256.convert(bytes).toString(),
      hardware,
      version,
      kind,
      softdeviceSize,
      bootloaderSize,
      applicationSize,
      deviceType,
      deviceRevision,
      required,
      allowUnverified,
      warnings,
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
    bool allowBootloaderUpdate = false,
    bool allowUnverified = false,
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (package.isUnverified && !allowUnverified) {
      throw StateError('Unverified DFU requires explicit expert authorization');
    }
    if (package.isBootloaderUpdate && !allowBootloaderUpdate) {
      throw StateError(
        'Bootloader DFU requires explicit recovery authorization',
      );
    }
    if (expectedDevice != null &&
        (transport.activeDevice == null ||
            !expectedDevice.matchesAfterReenumeration(
              transport.activeDevice!,
            ))) {
      throw StateError('nRF52 DFU USB identity changed before flashing');
    }
    // Immutable private copies still get fresh hash checks before any write.
    final dat = ByteData.sublistView(package.initPacket);
    final crcOffset = 10 + dat.getUint16(8, Endian.little) * 2;
    if (crypto.sha256.convert(package.payload).toString() !=
            package._payloadSha256 ||
        crypto.sha256.convert(package.initPacket).toString() !=
            package._initSha256 ||
        crcOffset + 2 != package.initPacket.length ||
        (!package.isUnverified &&
            dat.getUint16(crcOffset, Endian.little) !=
                nrfDfuCrc16(package.payload))) {
      throw StateError('DFU payload changed after validation');
    }
    _sequence = 0;
    _receive.clear();
    await transport.setSignals(dtr: true, rts: false);
    await transport.purge();
    onProgress?.call(0, 'Preparing ${package.displayName} DFU');
    await _send(
      _words([
        3,
        package.dfuMode,
        package.softdeviceSize,
        package.bootloaderSize,
        package.applicationSize,
      ]),
    );
    final pages = package.payload.length ~/ 4096 + 1;
    final eraseWait = (pages * 89.7).ceil().clamp(500, 30000);
    await _delay(Duration(milliseconds: eraseWait));
    await _send(
      Uint8List.fromList([
        ..._words([1]),
        ...package.initPacket,
        0,
        0,
      ]),
    );
    for (var offset = 0; offset < package.payload.length; offset += 512) {
      final end = (offset + 512).clamp(0, package.payload.length);
      await _send(
        Uint8List.fromList([
          ..._words([4]),
          ...package.payload.sublist(offset, end),
        ]),
      );
      onProgress?.call(
        end / package.payload.length * .95,
        'Writing ${package.displayName}',
      );
      // Adafruit bootloaders block during flash writes: never reset meanwhile.
      if ((offset ~/ 512) % 8 == 0) {
        await _delay(const Duration(milliseconds: 205));
      }
    }
    await _delay(const Duration(milliseconds: 205));
    await _send(_words([5]));
    onProgress?.call(.96, 'Activating ${package.displayName}; do not unplug');
    // Dual-bank activation erases bank0 and copies bank1. Keep the port quiet.
    // Preserve nrfutil's minimum erase delay even for small images. This wait
    // is deliberately conservative for single-bank application bootloaders.
    await _delay(Duration(milliseconds: eraseWait + (pages * 204.8).ceil()));
    onProgress?.call(
      1,
      package.isBootloaderUpdate
          ? 'Bootloader DFU transport completed; installed version remains unverified'
          : 'DFU transport completed; application verification required',
    );
    return UsbNrfDfuResult(package.payload.length, package.sha256);
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
