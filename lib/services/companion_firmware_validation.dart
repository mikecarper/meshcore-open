import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'companion_image_validator.dart';
import 'nrf_dfu_package.dart';
import 'usb_firmware_package.dart';

typedef _NordicRequest = ({
  Uint8List bytes,
  String board,
  CompanionFirmwareProvenance? provenance,
  NrfDfuApplicationRole role,
});
typedef _EspRequest = ({
  String name,
  Uint8List bytes,
  String board,
  CompanionFirmwareProvenance? provenance,
});

NrfDfuPackage _inspectNordic(_NordicRequest request) {
  final package = NrfDfuPackage.inspect(request.bytes);
  package.validateForBoard(
    request.board,
    provenance: request.provenance,
    role: request.role,
  );
  return package;
}

NrfDfuPackage _inspectNordicPackage(Uint8List bytes) =>
    NrfDfuPackage.inspect(bytes);

UsbFirmwareImage _inspectEsp32(_EspRequest request) =>
    CompanionImageValidator.validateEsp32(
      request.name,
      request.bytes,
      request.board,
      provenance: request.provenance,
    );

/// Native compute workers keep large ZIP/CRC/EndF checks off the old phone's
/// UI isolate. Web compute follows Flutter's supported same-event-loop path.
/// Workers use only bytes and public validation metadata, never files,
/// platform channels, connectors, providers, or mutable UI state.
class CompanionFirmwareValidation {
  static Future<NrfDfuPackage> inspectNordic(
    Uint8List bytes, {
    required String board,
    CompanionFirmwareProvenance? provenance,
    NrfDfuApplicationRole role = NrfDfuApplicationRole.companion,
  }) => compute(_inspectNordic, (
    bytes: bytes,
    board: board,
    provenance: provenance,
    role: role,
  ), debugLabel: 'Nordic firmware validation');

  static Future<UsbFirmwareImage> inspectEsp32(
    String name,
    Uint8List bytes, {
    required String board,
    CompanionFirmwareProvenance? provenance,
  }) => compute(_inspectEsp32, (
    name: name,
    bytes: bytes,
    board: board,
    provenance: provenance,
  ), debugLabel: 'ESP32 firmware validation');

  /// Structural validation only, for independently authenticated dedicated
  /// bootloader migration workflows. Not permission for a Companion update.
  static Future<NrfDfuPackage> inspectNordicPackage(Uint8List bytes) => compute(
    _inspectNordicPackage,
    bytes,
    debugLabel: 'Nordic migration package validation',
  );
}
