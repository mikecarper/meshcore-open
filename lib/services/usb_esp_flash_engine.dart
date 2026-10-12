import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'usb_flash_transport.dart';

class UsbFlashReenumerationRequired implements Exception {
  const UsbFlashReenumerationRequired(this.original, this.message);
  final UsbFlashDevice original;
  final String message;
  @override
  String toString() => message;
}

class UsbEspChipInfo {
  const UsbEspChipInfo({
    required this.chip,
    required this.flashBytes,
    required this.mac,
    this.name = 'ESP32',
  });

  factory UsbEspChipInfo.fromMap(Map<Object?, Object?> map) => UsbEspChipInfo(
    chip: map['chip'] as int,
    flashBytes: map['flashBytes'] as int,
    mac: normalizeMac(map['mac'] as String),
    name: map['name'] as String? ?? 'ESP32',
  );

  final int chip;
  final int flashBytes;
  final String mac;
  final String name;

  static String normalizeMac(String mac) {
    final value = mac.replaceAll(':', '').replaceAll('-', '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(value)) {
      throw FormatException('ROM returned an invalid chip MAC');
    }
    return value;
  }
}

/// Runs pinned Espressif esptool-js offline in an isolated Android WebView.
/// Its SerialPort shim uses the same native driver as [transport]. No remote
/// JavaScript, Python runtime, or web flasher is needed.
class UsbEspFlashEngine {
  UsbEspFlashEngine(this.transport, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('meshcore_open/usb_esp');

  final UsbFlashTransport transport;
  final MethodChannel _channel;
  UsbEspChipInfo? _chip;
  UsbEspChipInfo? get chipInfo => _chip;
  UsbFlashDevice? _connectedDevice;
  UsbFlashDevice? get connectedDevice => _connectedDevice;

  Future<UsbEspChipInfo> connect(
    UsbFlashDevice device, {
    bool reset = true,
  }) async {
    // Runtime capability, not OS version: updated Lollipop WebView supports
    // the offline engine. A failed preflight must not open/reset any USB node.
    try {
      await _channel.invokeMethod<void>('preflight');
    } on PlatformException catch (error) {
      if (error.code != 'usb_esp_webview_incompatible') rethrow;
      throw StateError(
        'ESP32 USB flashing needs an updated Android System WebView '
        '(61 or newer; WebView 95 supports Android 5.1). Update WebView '
        'before continuing. Backup and nRF52 USB DFU remain available.',
      );
    }
    var endpoint = device;
    var shouldReset = reset;
    // TinyUSB application's CDC port is not the hardware USB-Serial/JTAG
    // endpoint. Its deliberate 1200-baud touch hands control to ROM. A passive
    // migration reconnect must never take this path or toggle any signals.
    if (reset &&
        device.isNativeUsb &&
        !(device.vendorId == 0x303a && device.productId == 0x1001)) {
      final original = await transport.readIdentity(device);
      if (original.serialNumber?.isNotEmpty != true) {
        throw UsbFlashReenumerationRequired(
          original,
          'USB serial identity is unavailable. Put the selected node in its '
          'bootloader, then explicitly select that USB endpoint.',
        );
      }
      await transport.open(original);
      await transport.touch1200();
      try {
        endpoint = await transport.reacquire(
          original,
          timeout: const Duration(seconds: 20),
        );
      } on Exception catch (error) {
        throw UsbFlashReenumerationRequired(
          original,
          'Select the original node\'s new ROM USB endpoint to continue. $error',
        );
      }
      shouldReset = false;
    }
    final info = await _channel.invokeMapMethod<Object?, Object?>('connect', {
      ...endpoint.toMap(),
      'reset': shouldReset,
    });
    if (info == null) throw StateError('ESP ROM did not return chip identity');
    final connected = UsbEspChipInfo.fromMap(info);
    if (connected.flashBytes <= 0) throw StateError('Unknown flash capacity');
    _chip = connected;
    _connectedDevice = endpoint;
    return connected;
  }

  void _checkRange(int offset, int length) {
    final chip = _chip;
    if (chip == null) throw StateError('ESP32 bootloader is not connected');
    if (offset < 0 || length <= 0 || offset + length > chip.flashBytes) {
      throw RangeError('Flash region is outside the detected flash capacity');
    }
  }

  Future<Uint8List> readFlash(int offset, int length) async {
    _checkRange(offset, length);
    final output = BytesBuilder(copy: false);
    for (var read = 0; read < length; read += 65536) {
      final count = (length - read).clamp(0, 65536);
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'readFlash',
        {'offset': offset + read, 'length': count, 'expectedMac': _chip!.mac},
      );
      final bytes = response?['data'] as Uint8List?;
      if (bytes == null || bytes.length != count) {
        throw StateError('ESP flash read returned an incomplete region');
      }
      if (md5.convert(bytes).toString() != response?['md5']) {
        throw StateError('ESP flash read integrity verification failed');
      }
      output.add(bytes);
    }
    return output.takeBytes();
  }

  Future<void> writeFlash(
    int offset,
    Uint8List bytes, {
    required String expectedMac,
  }) async {
    _checkRange(offset, bytes.length);
    final mac = UsbEspChipInfo.normalizeMac(expectedMac);
    if (mac != _chip!.mac) throw StateError('Connected chip identity changed');
    if (offset % 4096 != 0) {
      throw ArgumentError('Flash writes must begin at a sector boundary');
    }
    // esptool writes 4-byte padding; verify exactly the payload bytes after it
    // completes, rather than accepting the block acknowledgement as proof.
    final expected = md5.convert(bytes).toString();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'writeFlash',
      {
        'offset': offset,
        'data': bytes,
        'expectedMac': mac,
        'expectedMd5': expected,
      },
    );
    if (result?['md5'] != expected || result?['mac'] != mac) {
      throw StateError('ESP flash verification failed; do not reboot');
    }
  }

  Future<void> runApplication({bool migrationBridge = false}) async {
    if (_chip == null) throw StateError('ESP32 bootloader is not connected');
    await _channel.invokeMethod<void>('runApplication', {
      'expectedMac': _chip!.mac,
      'migrationBridge': migrationBridge,
    });
    _chip = null;
  }

  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } finally {
      _chip = null;
      _connectedDevice = null;
      await transport.close();
    }
  }
}
