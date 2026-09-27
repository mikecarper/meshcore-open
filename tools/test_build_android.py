"""Regression tests for isolated, secret-free Android build profiles."""

from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import build_android as build


class AndroidProfileTests(unittest.TestCase):
    def test_apk_checks_native_libraries_and_required_update_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            def package(abi, *libraries):
                with zipfile.ZipFile(apk, "w") as archive:
                    for library in ("libflutter.so", *libraries):
                        archive.writestr(f"lib/{abi}/{library}", b"fixture")
                    for asset in ("esp32_partition_catalog.json", "github_legacy_roots.pem"):
                        archive.writestr(f"assets/flutter_assets/{asset}", b"fixture")
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
