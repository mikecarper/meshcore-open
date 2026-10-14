# Android build profiles

The normal project manifest keeps the modern dependencies. `tools/build_android.py`
creates a separate `.build/android-<profile>-...` checkout for each build; it never
rewrites the source `pubspec.yaml` or its lockfile. Keep widget tests, smoke builds,
and release builds in different workspaces: Flutter rewrites plugin registration
when switching between test and release modes.

The legacy production copy also omits the `integration_test` SDK dev plugin:
Flutter 3.32 can register it while excluding its native class from a release APK.
Smoke builds retain that plugin in a separate workspace; widget/unit tests remain
available in the production build copy.

| Profile | Flutter / Dart | APK architecture | Android minimum | Image codec | Optional translation |
| --- | --- | --- | --- | --- | --- |
| `legacy` | 3.32.8 / 3.8.1 | ARMv7 | API 21; includes Android 5.1 / API 22 | Native FT2 | Unavailable; explicitly disabled |
| `modern` | 3.41.2 / 3.11 | ARM64 | API 24 Flutter floor; plugins may raise it | Native FT2 and existing ONNX models | Existing implementation retained |

Use the pinned Flutter SDK, JDK 17, Android SDK platform 36, build tools 35.0.0, and NDK
29.0.14206865. Flutter SDK downloads are available in the
[official archive](https://docs.flutter.dev/install/archive).

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/Android/Sdk
python3 tools/build_android.py legacy --flutter /path/to/flutter-3.32.8/bin/flutter --sideload --trial
```

`--sideload` uses a local debug signing certificate and must be selected explicitly.
`--trial` changes the application ID to `com.meshcore.meshcore_open.aeictrial`, so
an existing installation and its data remain intact. Without it, the normal
application ID is retained. A store-signed build accepts `--signing-properties`
with a private `key.properties` containing an absolute keystore path instead.
Signing files, environment files, generated caches, and files linked outside the
repository are excluded from the build copy.

The legacy profile pins compatible scanner, notifications, picker, sharing, and
package-info dependencies in `legacy/pubspec-pins.json`. Overrides in
`legacy/pubspec_overrides.yaml` omit the incompatible optional LLM and ONNX
Android runtimes and retain the API-21-compatible cryptography plugin. These
stubs report unavailable operations rather than generating translation or image
results. Native FT2 uses its own separate executable and remains available.
Each profile keeps an explicit lockfile. The modern lock retains the original
application dependency versions where possible; updates cover the new archive
import dependency and the pinned Flutter SDK's test dependencies.

Each build saves an APK and `build-profile.json` under its workspace's
`artifacts/` directory, including source/APK hashes, profile, SDK, architecture,
and signing mode. The script checks packaged inference libraries and rejects an
APK with the wrong architecture or a missing native FT2 executable.

Run profile-preparation/packaging tests with:

```sh
python3 -m unittest discover -s tools -p test_build_android.py
```

Native FT2 model weights are separate from the APK and use about 2 GB of storage.
Import the verified `aeic-native-ft2-bundle-v1` TAR from Image messages settings,
or use **Check installed phone model** after a verified private-file installation.
The installer checks every regular file and creates only bounded internal links.
The native model offers eight square sizes: 128, 192, 256, 320, 384, 448, 512,
and 576 pixels; the send preview starts at 128. Compressed size depends on the
photo and must fit the transport's 2,369-byte limit, including the native header.

Strict decoding is the default. A failed native image can be retried with
**Recover image** after explicit confirmation; recovered images display
“Recovered image. Some detail may be missing.” Details absent from a damaged
stream cannot be restored. Detailed model/recovery diagnostics remain in logs.

The native process bridge, binary hashes, licenses, and reproducible native build
are documented in [Android native codec](../android/app/NATIVE_CODEC.md).
Training/export instructions and the CC0 benchmark photo are in
[AEIC mobile](https://github.com/mikecarper/AEIC/tree/main/mobile).
