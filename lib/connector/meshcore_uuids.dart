class MeshCoreUuids {
  static const String service = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String rxCharacteristic = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  static const String txCharacteristic = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  // Protocol-v14 nRF52 Full Companion service used by a paired phone to
  // provide a lazy .mota catalog. Normal Companion commands remain on NUS.
  static const String bleMotaService = "14518fc2-7e7a-4d84-8cae-6664b0234cf2";
  static const String bleMotaRequestCharacteristic =
      "2bfaa1ee-7030-459a-b65a-e7cfd5b09735";
  static const String bleMotaResponseCharacteristic =
      "acf38a51-dd58-4dce-917f-0b1135e41b1a";

  /// Known advertised-name prefixes used by stock MeshCore firmware builds.
  /// Discovery no longer filters on these (it filters on the [service] UUID so
  /// that community forks with custom names are still found); kept for
  /// reference and possible future display heuristics.
  static const List<String> deviceNamePrefixes = [
    "MeshCore-",
    "Whisper-",
    "WisCore-",
    "Seeed",
    "Lilygo",
    "HT-",
    "LowMesh_MC_",
    "NRF52",
  ];
}
