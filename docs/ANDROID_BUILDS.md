# Android builds from one source tree

Both APKs contain the same mesh, messaging, mapping, on-phone mOTA delta and key
generation, admin key backup, GitHub release discovery, companion Bluetooth/Wi-Fi
updates, and supported two-step ESP32 partition expansion workflows. Hardware and
target firmware still determine which update transports are available.

| Profile | Flutter | Android | CPU | Native AI |
| --- | --- | --- | --- | --- |
| legacy | 3.32.8 | API 21+, tested on Android 5.1.1/API 22 | ARMv7 | Not available |
| modern | 3.47.5 | API 28+ (Android 9+) | ARM64 | Translation and ONNX image codec included |

The modern minimum follows the packaged llama.cpp binaries (API 28), not just
Flutter's lower API 24 minimum. Only the GGUF translation runtime used by this
app is bundled; the unrelated API 31 LiteRT-LM runtime is excluded.

The legacy phone cannot run the translation native backend or fit the neural
image decoder in its 32-bit address space. These operations stay unavailable in
that profile, rather than appearing to work. This does not disable OTA crypto,
on-phone patch generation, normal attachments, or normal messaging.

The root pubspec and lockfile describe the modern build. The legacy dependency
overrides and lockfile live in `build_profiles/legacy/`. Do not replace the root
pubspec with a legacy copy or split feature development across two branches.

## Reproducible sideload candidates

Install the pinned SDKs separately. Set JAVA_HOME to JDK 17 and ANDROID_HOME to
your Android SDK. Then run:

```sh
python3 tools/build_android.py legacy --flutter /path/to/flutter-3.32.8/bin/flutter --sideload --test
python3 tools/build_android.py modern --flutter /path/to/flutter-3.47.5/bin/flutter --sideload --test
```

Each invocation creates an isolated `.build/android-<profile>-*` workspace. It
copies shared sources but excludes local keys, SDK settings, and ignored files.
Dependency resolution uses the selected lockfile with `--enforce-lockfile`.
The APK and a JSON build manifest (SDK, source digest, ABI, signing mode, and APK
SHA256) are placed in that workspace's `artifacts/` directory. Generated Flutter
files cannot dirty the original checkout. `--prepare-only` prepares a workspace
for manual diagnostics without building it.

`--sideload` explicitly uses the build machine's existing Android debug
certificate. This is suitable for these private test installs, not a public
production signing identity. Keep the same private keystore securely backed up
outside Git: changing it prevents an in-place update of installed APKs. CI uses
its own ephemeral debug key, so a CI APK will not upgrade a locally signed APK.
The APKs share an application ID and version; do not try to install the modern
APK on the API 22 phone. Never uninstall the app just to bypass a key mismatch.

For a dedicated distribution identity, supply `--signing-properties` pointing
to private Android signing properties with an absolute `storeFile` path. The
builder will not silently fall back to debug signing when that mode is chosen.
Private keys, passwords, and Wi-Fi credentials must never enter the repository.

## Validation and release limits

Run the full Flutter suite for both profiles, not just the default profile. The
profile tests check the inference backend selection and actual worker-to-rANS
wiring. Host tests also check isolated source copying and signing safeguards:

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
```

Some integration tests additionally require external mOTA/partition fixtures.
Set `MOTA_DETOOLS_PYTHON`, `MOTA_DETOOLS_SHIM`, and
`MESHCORE_MIGRATION_FIXTURE` to validated local fixtures when qualifying a release;
without them, inspect test skips rather than claiming complete integration
coverage. Never substitute mocked success for a hardware OTA test.

A passing build is not proof that native inference ran on a modern phone.
Qualify Bluetooth reconnect, Wi-Fi handoff, GitHub lookup, OTA recovery and the
large-model paths on their supported hardware before advertising a general
release. App readiness does not qualify or publish a MeshCore firmware release.
