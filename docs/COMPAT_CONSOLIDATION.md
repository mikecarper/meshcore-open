# Compatibility branch consolidation

Date: 2026-09-26
Destination: `android-5.1.1-compat` in `mikecarper/meshcore-open`.

The branch incorporates the histories of all 29 fork branch heads listed below.
Superseded implementations are not duplicated or restored over newer fixes.
Other branch pointers and the separate MeshCore firmware repository are unchanged.

## Integration decisions

- Retain the Android API 21 minimum, ARM32 build, Flutter 3.32.8, Dart 3.8,
  local compatibility shims, and phone-native OTA/update UI.
- Retain newer multibyte paths, telemetry privacy, compact layouts, sync pipeline,
  image handling, and update-screen disconnect protection over older equivalents.
- Merge phone GPS tracking with opt-in permission checks, saved GPX tracks,
  coarse transmitted coordinates, and no automatic change to privacy settings.
  This requests foreground location access, not unrestricted background tracking.
- Merge offline contacts, channels, messages, and last-companion storage scopes.
  Radio-only actions remain gated on connection.
- Merge lifecycle reconnect, remembered BLE devices, notification grouping and
  tap navigation. A manual disconnect clears the remembered BLE connection,
  not the offline companion cache. OS process termination can still stop BLE.
- Merge translation backends while retaining template-copy and locale filters.
  Keys come from runtime options or environment variables, never source constants.
- Retain actual TCP/USB screen widget tests instead of replacing them with the
  background branch's duplicated screen-logic helper tests.

## Validation

- `flutter test --dart-define=LEGACY_ARM32=true`: 773 passed, 2 skipped.
- `python3 -m unittest discover -s tools -p test_translate.py -v`: 4 passed.
- Full analyzer: no errors; 11 existing warnings/info in unchanged files.
- Release validation uses:
  `flutter build apk --release --target-platform android-arm --dart-define=LEGACY_ARM32=true`.

The new regression tests cover GPS permissions, sampling, file retention,
callback failures, offline scope isolation, channel deduplication, missing saved
devices, reconnect persistence, lifecycle callbacks, and translation selection.

## Source branch heads

These are the fetched source tips before consolidation (including the original
compatibility branch tip), not a promise that every branch points at the same commit.

| Branch | Source commit |
| --- | --- |
| `#401-make-multi-ack-a-toggle` | `e53c493e789716d582744ced0bdef367934886e4` |
| `android-5.1.1-compat` | `939f10f4817eef5e8d3123c5ca7f0bbd60181053` |
| `copilot/sub-pr-175` | `3a06c36ec4dea8a82f221972eac398ecb3a55c8f` |
| `debug-log` | `00636c90843425561ce14a7fcfcf67211bc2be1c` |
| `dev` | `27f22b42ed5d0ced60fe8c1dff7996313b10293f` |
| `dev-GPSTracking` | `49665fd5636be76ab4ec99bdde390c037e4cd3b3` |
| `dev-dbDevicePrefix` | `f870e77e982a1aae92891cf4f069d5242661d078` |
| `dev-guessed-locations` | `81548fdc21a6cb6ccb8a53d5044d64ae2d2c3013` |
| `dev-improments` | `60e8ee013053a06d1f8c74d8f654d3ecf97f0288` |
| `dev-mapOverlap` | `2c8a15538e030fa585c2fa77b574471dec96a228` |
| `dev-offline` | `ba4fd3eff55479de170d76b775139d292cbf7e2d` |
| `dev-pathtraceFixes` | `e930ef008e5d242418ba0d9e6b1c7121088d600a` |
| `dev-privacy` | `5ad9263cc42254059f0a4e529b1067dba69b1cb5` |
| `dev-reconntion` | `92d2b224e75ad261e4b6e1149c718c32ddac51cf` |
| `dev-searchHintText` | `0135d56ddcce2c738926e825b890cd64ac50f71f` |
| `dev-toolTranslate` | `d104edd65c5b93157e95cbbd5f0dc00de8f39767` |
| `dev-unifiedData` | `0228c3862165bf91a3243f2b80572445674e91f9` |
| `docs/privacy-open-meteo-location` | `80629c5f290b1e1261697a263ea8bbfd1d40e669` |
| `ez_group_dropdown3` | `566e3aadf83d9124007014617cc5e36e8679ee50` |
| `favorite_filter_ez` | `50af2e0bc9c2ddedc4bdbafcc8709071e055b886` |
| `feature/ml-timeout-prediction` | `fffcff3b74896e9fe0dd64d02756fd94d7565062` |
| `feature/usb` | `fef73b7b62caeb31d4e214a41094474aac9822eb` |
| `fix-bg-fg` | `d529ce922886f2abf005b12cd5a4fbfbfd5952da` |
| `fix/radio-params-fw-compat` | `4239fb11edea2d26468be19d5efd99257e19ef7f` |
| `main` | `c78c77309e366dea05f528ba6cd7b6e40df5bdd6` |
| `map-set-location-and-connector-improvements` | `fa4da979af2c7ad4cead7b06d7b8d32528e838b6` |
| `ui` | `becfbedc99b8e64bf415007af9c176c392833f7e` |
| `unused-plugin` | `bdd7fc0cdd32c449cefb62536855e26887a8a4b9` |
| `zjs81-patch-1` | `ea2354712d3cb2a237381442c517b720537fbb7e` |
