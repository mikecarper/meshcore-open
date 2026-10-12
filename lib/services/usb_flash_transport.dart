import 'dart:async';

import 'package:flutter/services.dart';

/// A USB endpoint, not proof of a particular board's identity. Flash engines
/// must independently verify the chip's immutable identity before writing.
class UsbFlashDevice {
  const UsbFlashDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    this.serialNumber,
    this.manufacturerName,
    this.productName,
    this.portNumber = 0,
    this.driver = 'unknown',
  });

  factory UsbFlashDevice.fromMap(Map<Object?, Object?> map) => UsbFlashDevice(
    deviceName: map['deviceName'] as String,
    vendorId: map['vendorId'] as int,
    productId: map['productId'] as int,
    serialNumber: map['serialNumber'] as String?,
    manufacturerName: map['manufacturerName'] as String?,
    productName: map['productName'] as String?,
    portNumber: map['portNumber'] as int? ?? 0,
    driver: map['driver'] as String? ?? 'unknown',
  );

  final String deviceName;
  final int vendorId;
  final int productId;
  final String? serialNumber;
  final String? manufacturerName;
  final String? productName;
  final int portNumber;
  final String driver;

  bool get isNativeUsb =>
      driver == 'CdcAcmSerialDriver' &&
      !const {0x1a86, 0x0403, 0x10c4, 0x067b}.contains(vendorId);
  bool get isNrfDfu {
    // Same observed bootloader identities as firmware.cmd. This is a mode
    // hint for skipping impossible application backups, never board proof.
    if (vendorId == 0x239a && productId >= 0 && productId <= 0xff) {
      return true;
    }
    if (vendorId == 0x2886 &&
        const {0x0044, 0x0045, 0x0057, 0x1667}.contains(productId)) {
      return true;
    }
    final name = '${productName ?? ''} ${manufacturerName ?? ''}'.toLowerCase();
    return name.contains('dfu') ||
        name.contains('bootloader') ||
        name.contains('otafix') ||
        (vendorId != 0x303a && RegExp(r'\b\w*boot\b').hasMatch(name));
  }

  String get identityKey => '${serialNumber ?? deviceName}:$portNumber';
  String get displayName =>
      '${productName ?? driver} ($deviceName, port $portNumber)';

  Map<String, Object?> toMap() => {
    'deviceName': deviceName,
    'vendorId': vendorId,
    'productId': productId,
    'serialNumber': serialNumber,
    'manufacturerName': manufacturerName,
    'productName': productName,
    'portNumber': portNumber,
    'driver': driver,
  };

  /// Checks a selected endpoint before opening/resetting it. Android bus paths
  /// are recyclable: a known serial must never be silently replaced by a new
  /// node that happens to inherit the same deviceName.
  bool matchesSelectedDescriptor(UsbFlashDevice actual) =>
      deviceName == actual.deviceName &&
      portNumber == actual.portNumber &&
      vendorId == actual.vendorId &&
      productId == actual.productId &&
      (serialNumber == null || serialNumber == actual.serialNumber) &&
      (manufacturerName == null ||
          manufacturerName == actual.manufacturerName) &&
      (productName == null || productName == actual.productName) &&
      (driver == 'unknown' || driver == actual.driver);

  /// Passive endpoint matching. VID/PID alone can never select a replacement.
  bool matchesAfterReenumeration(UsbFlashDevice candidate) {
    if (candidate.portNumber != portNumber) return false;
    if (serialNumber?.isNotEmpty ?? false) {
      return candidate.serialNumber == serialNumber &&
          candidate.manufacturerName == manufacturerName;
    }
    return candidate.deviceName == deviceName &&
        candidate.vendorId == vendorId &&
        candidate.productId == productId;
  }
}

/// Exclusive unframed USB transport. Opening/enumerating never performs a
/// bootloader reset; touching 1200 baud is a separate explicit operation.
class UsbFlashTransport {
  UsbFlashTransport({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('meshcore_open/usb_flash');

  final MethodChannel channel;
  UsbFlashDevice? _device;
  UsbFlashDevice? get activeDevice => _device;

  Future<List<UsbFlashDevice>> listDevices() async {
    final result = await channel.invokeListMethod<Object?>('listDevices');
    return [
      for (final map in result ?? const <Object?>[])
        UsbFlashDevice.fromMap(Map<Object?, Object?>.from(map as Map)),
    ];
  }

  Future<void> open(UsbFlashDevice device, {int baudRate = 115200}) async {
    if (_device != null) throw StateError('Raw USB transport is already open');
    if (baudRate <= 0) throw ArgumentError.value(baudRate, 'baudRate');
    await channel.invokeMethod<void>('open', {
      ...device.toMap(),
      'baudRate': baudRate,
    });
    _device = device;
    // Refresh permission-protected serial descriptors without opening another
    // port or affecting DTR/RTS. A selected descriptor may lack its serial.
    final fresh = (await listDevices()).where(
      (item) =>
          item.deviceName == device.deviceName &&
          item.portNumber == device.portNumber,
    );
    if (fresh.length != 1 || !device.matchesSelectedDescriptor(fresh.single)) {
      await close();
      throw StateError('The selected USB node identity changed during open');
    }
    _device = fresh.single;
  }

  /// Requests the OS permission and reads USB descriptors without opening the
  /// serial driver or changing signals. Re-enumerated endpoints need a fresh
  /// Android USB grant even when they belong to the same physical node.
  Future<UsbFlashDevice> readIdentity(UsbFlashDevice device) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'readIdentity',
      device.toMap(),
    );
    if (result == null) {
      throw StateError('USB descriptor identity is unavailable');
    }
    final actual = UsbFlashDevice.fromMap(result);
    if (!device.matchesSelectedDescriptor(actual)) {
      throw StateError(
        'The selected USB node identity changed before permission',
      );
    }
    return actual;
  }

  Future<Uint8List> read({
    int maxBytes = 4096,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (maxBytes <= 0 || maxBytes > 65536 || timeout.inMilliseconds <= 0) {
      throw ArgumentError('Invalid USB read size or timeout');
    }
    return await channel.invokeMethod<Uint8List>('read', {
          'maxBytes': maxBytes,
          'timeoutMs': timeout.inMilliseconds,
        }) ??
        Uint8List(0);
  }

  Future<void> write(Uint8List bytes) =>
      channel.invokeMethod<void>('write', {'data': bytes});

  Future<void> setSignals({required bool dtr, required bool rts}) =>
      channel.invokeMethod<void>('setSignals', {'dtr': dtr, 'rts': rts});

  Future<void> setBaudRate(int baudRate) {
    if (baudRate <= 0) throw ArgumentError.value(baudRate, 'baudRate');
    return channel.invokeMethod<void>('setBaudRate', {'baudRate': baudRate});
  }

  Future<void> purge() => channel.invokeMethod<void>('purge');

  Future<void> setKeepAwake(bool enabled) =>
      channel.invokeMethod<void>('setKeepAwake', {'enabled': enabled});

  Future<void> touch1200() async {
    await setBaudRate(1200);
    await setSignals(dtr: true, rts: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setSignals(dtr: false, rts: false);
    await close();
  }

  Future<UsbFlashDevice> reacquire(
    UsbFlashDevice original, {
    Duration timeout = const Duration(seconds: 180),
  }) async {
    if (original.serialNumber?.isNotEmpty != true) {
      throw StateError(
        'USB serial identity is unavailable; select the node again',
      );
    }
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final attached = await listDevices();
      final candidates = attached
          .where(
            (item) =>
                item.portNumber == original.portNumber &&
                item.manufacturerName == original.manufacturerName &&
                (item.serialNumber == null ||
                    item.serialNumber == original.serialNumber),
          )
          .toList();
      if (candidates.length == 1 && candidates.single.serialNumber == null) {
        final identified = await readIdentity(candidates.single);
        if (!original.matchesAfterReenumeration(identified)) {
          throw StateError(
            'USB node identity changed; select the original node',
          );
        }
        return identified;
      }
      final matches = attached
          .where(original.matchesAfterReenumeration)
          .toList();
      if (matches.length > 1) {
        throw StateError('USB identity is ambiguous; select the node again');
      }
      if (matches.length == 1) return matches.single;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException(
      'The original USB node did not return; select its new USB endpoint',
      timeout,
    );
  }

  Future<void> close() async {
    try {
      await channel.invokeMethod<void>('close');
    } finally {
      _device = null;
    }
  }
}
