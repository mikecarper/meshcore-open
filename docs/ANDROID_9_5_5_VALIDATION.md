# Android 9.5.5+21 sideload candidates

Validated on 2026-09-26. These are private sideload candidates, not a public
store release or a MeshCore firmware release.

## Builds

| Profile | SDK | Package | Minimum Android | Size |
| --- | --- | --- | --- | --- |
| Legacy | Flutter 3.32.8 / Dart 3.8.1 | ARMv7, version 9.5.5+21 | API 21; tested on API 22 | 19,836,949 bytes |
| Modern | Flutter 3.47.5 / Dart 3.13.4 | ARM64, version 9.5.5+21 | API 28 / Android 9 | 83,821,730 bytes |

APK SHA256:

```text
legacy ce86c82fc7a6b4cc757fb9ca392d62c1b5530650b67ee667e5b5cf82d67df2cc
modern 9385985acc7b370a4eda83da6d031e79a4d5db7b4c223ea5772bc08eb82a97e1
```

Both APKs use the existing local Android debug certificate for sideload update
continuity. Its SHA256 fingerprint is:

```text
e8df62dd670ed490905ec8865d3c5d20f829b2bb624eeb8cfae4d73dec562303
```

The private key is backed up outside the repository with owner-only permissions.
No signing passwords, private keys, or Wi-Fi credentials were added to Git.

## Checks completed

- 807 Flutter tests passed in each configuration, with no skips. External
  detools oracle and ESP32 migration fixtures were supplied.
- Nine Python host tests passed (five build-profile tests and four existing
  translation-tool tests).
- App/test static analysis: no errors or warnings. There are three existing
  style infos on legacy, and 28 style/deprecation infos on modern. Older APIs
  remain where the Flutter 3.32 build needs them.
- Actual APK contents checked: legacy has only ARMv7 and no ONNX/llamadart;
  modern has only ARM64 and both native inference engines. The unused API 31
  LiteRT-LM runtime is excluded. Both include the partition LUT and legacy TLS
  public roots. Manifest minimum SDKs and signatures were checked independently.
- Legacy APK installed over 9.5.4 on the attached LG Android 5.1.1 phone without
  uninstalling or clearing data. Version 9.5.5+21 confirmed after installation.
- The phone reconnected to the saved Companion, retained its channel state,
  and identified Heltec V4.3 OLED through the Companion update screen.
- Live GitHub lookup matched the board and refused an older firmware selection.
  The first lookup had a connection error; a manual retry succeeded on SlowFi.

## Remaining release qualifications

- No suitable modern Android phone was attached. Native translation and image
  inference are restored, packaged, and covered by host-level connection and
  codec tests, but were not exercised end to end on modern Android hardware.
- No firmware was flashed during this app-validation pass. Earlier OTA work
  and automated migration tests do not replace final hardware qualification of
  every firmware, transport, bootloader, or partition-expansion combination.
- The pinned modern SDK warns that future Flutter versions will require newer
  Gradle, Android Gradle Plugin, and Kotlin versions. This build succeeds with
  the shared toolchain; those migrations remain separate compatibility work.

Build instructions and signing limitations are in `ANDROID_BUILDS.md`. Local
APKs, build manifests, and phone screenshots are under `.build/releases/9.5.5/`.
