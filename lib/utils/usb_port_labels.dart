String normalizeUsbPortName(String portLabel) {
  final separatorIndex = portLabel.indexOf(' - ');
  final normalized = separatorIndex >= 0
      ? portLabel.substring(0, separatorIndex)
      : portLabel;
  return normalized.trim();
}

enum UsbPortRole { companion, logging, unknown }

final RegExp _loggingInterfacePattern = RegExp(
  r'(^|[^a-z0-9])(if0*2|mi[_-]?0*2|interface\s*0*2)([^0-9]|$)',
);
final RegExp _companionInterfacePattern = RegExp(
  r'(^|[^a-z0-9])(if0*0|mi[_-]?0*0|interface\s*0*0)([^0-9]|$)',
);

/// Identifies the two interfaces exposed by MeshCore dual-CDC firmware.
///
/// Interface 00 carries Companion framing and flashing. Interface 02 is the
/// output-only plaintext logging endpoint. Labels differ by operating system,
/// so both USB descriptors and common `ifNN`/`MI_NN` forms are recognized.
UsbPortRole classifyUsbPortRole(String portLabel) {
  final value = portLabel.toLowerCase();
  if (value.contains('meshcore logging') ||
      _loggingInterfacePattern.hasMatch(value)) {
    return UsbPortRole.logging;
  }
  if (value.contains('meshcore companion') ||
      _companionInterfacePattern.hasMatch(value)) {
    return UsbPortRole.companion;
  }
  return UsbPortRole.unknown;
}

List<String> orderUsbPortsForCompanion(Iterable<String> ports) {
  final indexed = ports.indexed.toList();
  int priority(String label) {
    if (normalizeUsbPortName(label) == 'web:request') return -1;
    return switch (classifyUsbPortRole(label)) {
      UsbPortRole.companion => 0,
      UsbPortRole.unknown => 1,
      UsbPortRole.logging => 2,
    };
  }

  indexed.sort((a, b) {
    final byRole = priority(a.$2).compareTo(priority(b.$2));
    return byRole != 0 ? byRole : a.$1.compareTo(b.$1);
  });
  return indexed.map((entry) => entry.$2).toList();
}

String usbPortDisplayName(String portLabel) {
  final base = friendlyUsbPortName(portLabel);
  final lower = base.toLowerCase();
  return switch (classifyUsbPortRole(portLabel)) {
    UsbPortRole.logging when !lower.contains('logging') =>
      '$base - MeshCore Logging',
    UsbPortRole.companion when !lower.contains('companion') =>
      '$base - MeshCore Companion',
    _ => base,
  };
}

/// Returns a human-readable name for a serial port label.
///
/// The native flserial library encodes port info as a ` - `-separated string:
///   `"<port> - <description> - <hardware_id>"`
///
/// This function extracts the *description* field (index 1) and discards the
/// raw hardware_id, which is not user-friendly. If the description is missing
/// or unhelpful (e.g. "n/a"), it falls back to the raw port name.
String friendlyUsbPortName(String portLabel) {
  final parts = portLabel.split(' - ');
  if (parts.length < 2) {
    return portLabel.trim();
  }
  // parts[0] = port name, parts[1] = description, parts[2+] = hardware id
  final description = parts[1].trim();
  if (description.isEmpty || description.toLowerCase() == 'n/a') {
    return parts[0].trim();
  }
  return description;
}

String describeWebUsbPort({
  required int? vendorId,
  required int? productId,
  String requestPortLabel = 'Choose USB Device',
  String fallbackDeviceName = 'Web Serial Device',
  Map<String, String> knownUsbNames = const <String, String>{},
}) {
  if (vendorId == null && productId == null) {
    return requestPortLabel;
  }

  final vendorHex = vendorId?.toRadixString(16).padLeft(4, '0').toUpperCase();
  final productHex = productId?.toRadixString(16).padLeft(4, '0').toUpperCase();
  final knownName = (vendorHex != null && productHex != null)
      ? knownUsbNames['${vendorHex.toLowerCase()}:${productHex.toLowerCase()}']
      : null;

  final parts = <String>[knownName ?? fallbackDeviceName];
  if (vendorHex != null) {
    parts.add('VID:$vendorHex');
  }
  if (productHex != null) {
    parts.add('PID:$productHex');
  }
  return '${parts.first} (${parts.skip(1).join(' ')})';
}

String buildUsbDisplayLabel({
  required String basePortLabel,
  String? deviceName,
}) {
  final trimmedName = deviceName?.trim() ?? '';
  if (trimmedName.isEmpty) {
    return basePortLabel;
  }
  return '$basePortLabel - $trimmedName';
}
