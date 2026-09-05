String confirmedBootloaderInstallCommand({
  required String status,
  required String expectedManifestId,
  required String expectedImageHashPrefix,
}) {
  final match = RegExp(
    r'\bstaged:ready\s+mid=([0-9a-f]{8})\s+hash=([0-9a-f]{16})(?:\s|$)',
    caseSensitive: false,
  ).firstMatch(status);
  if (match == null) {
    throw StateError(
      'The target did not report a staged bootloader ready for explicit '
      'approval. Installation was not attempted. Target reply: $status',
    );
  }

  final targetManifestId = match.group(1)!.toUpperCase();
  final targetImageHashPrefix = match.group(2)!.toUpperCase();
  final selectedManifestId = expectedManifestId.toUpperCase();
  final selectedImageHashPrefix = expectedImageHashPrefix.toUpperCase();
  if (targetManifestId != selectedManifestId ||
      targetImageHashPrefix != selectedImageHashPrefix) {
    throw StateError(
      'The staged bootloader does not match the selected file '
      '(target MID $targetManifestId, hash $targetImageHashPrefix; selected '
      'MID $selectedManifestId, hash $selectedImageHashPrefix). Installation '
      'was not attempted.',
    );
  }

  return 'ota bootloader install $selectedManifestId '
      '$selectedImageHashPrefix';
}
