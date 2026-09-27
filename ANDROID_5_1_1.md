# Android 5.1.1 (API 22) build

This branch is a separate compatibility build for the connected 32-bit ARM
phone. The normal `dev` branch remains unchanged.

Use Flutter 3.32.8 (Dart 3.8.1). Flutter 3.35 and newer require Android API 24
at the engine level, so changing `minSdk` alone is insufficient. The app's
`minSdk` is 21 and the APK contains only `armeabi-v7a` native libraries.

```sh
flutter pub get
flutter test --dart-define=LEGACY_ARM32=true
flutter build apk --release --target-platform android-arm \
  --dart-define=LEGACY_ARM32=true
```

The local `legacy_shims/` packages keep Dart source compatible with this SDK:

- `llamadart` is a nonfunctional API shim because its native runtime does not
  ship for 32-bit ARM. The translation UI and model downloads are disabled.
- `flutter_onnxruntime` retains the Dart API for test compilation but has no
  Android plugin registration. The neural image codec is disabled because its
  Android package requires API 24 and its memory needs exceed a 32-bit process.
- `cryptography_flutter` is the API-21-capable 2.3.2 release with an Android
  namespace declaration and its obsolete Flutter v1 import removed.

The older mobile scanner plugin retains QR scanning. `legacy_radio.dart` adapts
the newer `RadioGroup` API to the older Material `RadioListTile` API. The build
also uses the older `DropdownButtonFormField.value` spelling.

## Phone update workflow

The scanner has one persistent Scan/Stop action. Connect to the Companion,
then open Settings > Update Companion to find board-matched GitHub releases
or select a Nordic DFU ZIP / ESP32 application image from phone Downloads.
Long confirmations scroll, and show the last battery voltage when available.
Firmware updates still require the correct board image and stable radio power.

Remote management includes phone-generated LoRa differential packages,
Bluetooth DFU, Wi-Fi updates, and an explicit two-step partition migration
for supported exact-board migration bundles. Unsupported layouts are not
automatically repartitioned.

Admin identity backups require Companion firmware advertising
`ephemeral-routed-v1`. Replies bypass chat and debug logs, and the phone
encrypts the backup with a user passphrase before saving it. Keep the
encrypted backup and passphrase separately. No network credentials or private
identity keys belong in this repository.
