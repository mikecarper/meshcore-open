"""Regression tests for isolated, secret-free Android build profiles."""

from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import build_android as build


class AndroidProfileTests(unittest.TestCase):
    def package_apk(self, apk, abi, *libraries, omit_library=None,
                    omit_license=None, tamper_license=None):
        with zipfile.ZipFile(apk, "w") as archive:
            for library in ("libflutter.so", *build.IMAGE_CODEC_LIBRARIES, *libraries):
                if library != omit_library:
                    archive.writestr(f"lib/{abi}/{library}", b"fixture")
            for asset in ("esp32_partition_catalog.json", "github_legacy_roots.pem"):
                archive.writestr(f"assets/flutter_assets/{asset}", b"fixture")
            for asset in (build.ROOT / "android/app/src/main/assets/esptool").iterdir():
                if asset.is_file():
                    archive.writestr("assets/esptool/" + asset.name, asset.read_bytes())
            licenses = build.ROOT / "android/app/src/main/assets/image_codecs/licenses"
            for asset in licenses.iterdir():
                if asset.is_file() and asset.name != omit_license:
                    archive.writestr(
                        "assets/image_codecs/licenses/" + asset.name,
                        b"tampered" if asset.name == tamper_license else asset.read_bytes(),
                    )
            archive.writestr("classes.dex", b"\0".join(
                f"Lcom/hoho/android/usbserial/driver/{driver};".encode()
                for driver in build.USB_DRIVERS))

    def test_apk_checks_native_libraries_and_required_update_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            def package(abi, *libraries):
                self.package_apk(apk, abi, *libraries)
            package("armeabi-v7a")
            self.assertFalse(build.verify_apk(apk, "legacy")["onnx"])
            with self.assertRaises(RuntimeError):
                build.verify_apk(apk, "modern")
            package("arm64-v8a")
            with self.assertRaises(RuntimeError):
                build.verify_apk(apk, "modern")
            package("arm64-v8a", "libonnxruntime.so", "libllamadart.so")
            self.assertTrue(build.verify_apk(apk, "modern")["llamadart"])
            package("armeabi-v7a", "libonnxruntime.so")
            with self.assertRaises(RuntimeError):
                build.verify_apk(apk, "legacy")

    def test_image_codec_packaging_records_both_workers_and_all_licenses(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            for profile, abi, runtimes in (
                ("legacy", "armeabi-v7a", ()),
                ("modern", "arm64-v8a", ("libonnxruntime.so", "libllamadart.so")),
            ):
                with self.subTest(profile=profile):
                    self.package_apk(apk, abi, *runtimes)
                    marker = build.verify_apk(apk, profile)["image_codecs"]
                    self.assertEqual(marker["codecs"], list(build.IMAGE_CODECS))
                    self.assertEqual(marker["libraries"], list(build.IMAGE_CODEC_LIBRARIES))
                    self.assertEqual(marker["license_assets"], sorted(build.IMAGE_CODEC_LICENSES))

    def test_image_codec_packaging_refuses_each_missing_native_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            for profile, abi, runtimes in (
                ("legacy", "armeabi-v7a", ()),
                ("modern", "arm64-v8a", ("libonnxruntime.so", "libllamadart.so")),
            ):
                for library in build.IMAGE_CODEC_LIBRARIES:
                    with self.subTest(profile=profile, library=library):
                        self.package_apk(apk, abi, *runtimes, omit_library=library)
                        with self.assertRaisesRegex(RuntimeError, "native image codec library"):
                            build.verify_apk(apk, profile)

    def test_image_codec_packaging_refuses_each_missing_license(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            for license_name in build.IMAGE_CODEC_LICENSES:
                with self.subTest(license=license_name):
                    self.package_apk(apk, "armeabi-v7a", omit_license=license_name)
                    with self.assertRaisesRegex(RuntimeError, "missing image codec license asset"):
                        build.verify_apk(apk, "legacy")

    def test_image_codec_packaging_refuses_changed_license_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            self.package_apk(apk, "armeabi-v7a", tamper_license="vvenc-LICENSE.txt")
            with self.assertRaisesRegex(RuntimeError, "image codec license checksum mismatch"):
                build.verify_apk(apk, "legacy")

    def test_usb_packaging_refuses_missing_drivers_and_wrong_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/armeabi-v7a/libflutter.so", b"fixture")
            with self.assertRaisesRegex(RuntimeError, "offline USB asset"):
                build.verify_apk(apk, "legacy")
            with zipfile.ZipFile(apk, "w") as archive:
                for asset in (build.ROOT / "android/app/src/main/assets/esptool").iterdir():
                    archive.writestr("assets/esptool/" + asset.name,
                                     b"tampered" if asset.name == "bundle.js" else asset.read_bytes())
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                build.verify_apk(apk, "legacy")
            with zipfile.ZipFile(apk, "w") as archive:
                for asset in (build.ROOT / "android/app/src/main/assets/esptool").iterdir():
                    archive.writestr("assets/esptool/" + asset.name, asset.read_bytes())
            with self.assertRaisesRegex(RuntimeError, "native USB driver"):
                build.verify_apk(apk, "legacy")

    def test_machine_test_summary_counts_visible_cases_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "tests.jsonl"
            log.write_text('\n'.join([
                '{"type":"testDone","testID":0,"result":"success","hidden":true}',
                '{"type":"testDone","testID":1,"result":"success"}',
                '{"type":"testDone","testID":2,"result":"success","skipped":true}',
            ]))
            self.assertEqual(build.summarize_tests(log), {"passed": 1, "failed": 0, "skipped": 1})
            log.write_text('{"type":"testDone","testID":1,"result":"failure"}')
            with self.assertRaisesRegex(RuntimeError, "failures"):
                build.summarize_tests(log)

    def test_profiles_pin_sdk_abi_and_minimum_android(self):
        self.assertEqual(build.PROFILES["legacy"], {
            "flutter": "3.32.8", "target": "android-arm", "min_sdk": 21,
        })
        self.assertEqual(build.PROFILES["modern"], {
            "flutter": "3.47.5", "target": "android-arm64", "min_sdk": 28,
        })

    def test_shared_sources_with_legacy_overrides_and_no_secrets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            destination = Path(temporary) / "stage"
            files = {
                "lib/main.dart": "shared source",
                "pubspec.yaml": "shared dependencies",
                "pubspec.lock": "modern lock",
                "android/key.properties": "secret",
                "android/local.properties": "local SDK path",
                "android/release.jks": "secret",
                "android/release.keystore": "secret",
                ".env": "secret",
                "build_profiles/legacy/pubspec.lock": "legacy lock",
                "build_profiles/legacy/pubspec_overrides.yaml": "legacy packages",
            }
            for name, data in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            with patch.object(build, "source_files", return_value=list(files)):
                digest = build.prepare(root, destination, "legacy")
            self.assertEqual(len(digest), 64)
            self.assertEqual((destination / "lib/main.dart").read_text(), "shared source")
            self.assertEqual((destination / "pubspec.lock").read_text(), "legacy lock")
            self.assertEqual((destination / "pubspec_overrides.yaml").read_text(), "legacy packages")
            for name in ("android/key.properties", "android/local.properties",
                         "android/release.jks", "android/release.keystore", ".env"):
                self.assertFalse((destination / name).exists(), name)

    def test_modern_uses_real_runtimes_and_legacy_replaces_all_three(self):
        pubspec = (build.ROOT / "pubspec.yaml").read_text()
        override = (build.ROOT / "build_profiles/legacy/pubspec_overrides.yaml").read_text()
        self.assertNotIn("path: legacy_shims", pubspec)
        for package in ("llamadart", "cryptography_flutter", "flutter_onnxruntime"):
            self.assertIn(f"path: legacy_shims/{package}", override)
        self.assertIn("android-arm64:", pubspec)
        self.assertIn("android-arm64: [llama_cpp]", pubspec)

    def test_gradle_shares_the_dart_feature_gate_and_requires_explicit_signing(self):
        gradle = (build.ROOT / "android/app/build.gradle.kts").read_text()
        self.assertIn('dartDefines.contains("LEGACY_ARM32=true")', gradle)
        self.assertIn('MESHCORE_ALLOW_TEST_SIGNING', gradle)
        self.assertIn('else if (allowTestSigning)', gradle)
        self.assertIn('check(keystorePropertiesFile.exists() || allowTestSigning)', gradle)
        properties = (build.ROOT / "android/gradle.properties").read_text()
        self.assertIn('disable-abi-filtering=true', properties)
        self.assertIn('else listOf("arm64-v8a")', gradle)


if __name__ == "__main__":
    unittest.main()
