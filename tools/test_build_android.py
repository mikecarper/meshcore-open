"""Regression tests for isolated, secret-free Android build profiles."""

from pathlib import Path
import hashlib
import json
import struct
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import build_android as build


class AndroidProfileTests(unittest.TestCase):
    def setUp(self):
        self.inventory = hashlib.sha256(b"upstream fixture").hexdigest().encode() + b"  src/fixture.c\n"
        inventory_patch = patch.object(build, "ESP_NATIVE_INVENTORY_SHA256",
                                      hashlib.sha256(self.inventory).hexdigest())
        inventory_patch.start()
        self.addCleanup(inventory_patch.stop)
        self.native_assets = {
            "PROVENANCE.json": json.dumps({
                "backend": build.ESP_NATIVE_BACKEND,
                "version": build.ESP_NATIVE_VERSION,
                "source_commit": build.ESP_NATIVE_COMMIT,
                "upstream": "https://github.com/espressif/esp-serial-flasher",
                "archive_sha256": build.ESP_NATIVE_ARCHIVE_SHA256,
                "source_inventory_sha256": build.ESP_NATIVE_INVENTORY_SHA256,
            }, sort_keys=True).encode(),
            "SHA256SUMS.source": self.inventory,
            "LICENSE.esp-serial-flasher": b"Apache-2.0 test fixture",
            "LICENSE.usb-serial": b"MIT test fixture",
            "LICENSE.md5": b"BSD test fixture",
            "NOTICE": b"Copyright test fixture",
        }
        asset_patch = patch.object(build, "native_esp_assets", return_value=self.native_assets)
        asset_patch.start()
        self.addCleanup(asset_patch.stop)

    @staticmethod
    def native_elf(abi):
        data = bytearray(64)
        data[:7] = b"\x7fELF" + bytes((1 if abi == "armeabi-v7a" else 2, 1, 1))
        struct.pack_into("<HH", data, 16, 3, 40 if abi == "armeabi-v7a" else 183)
        return bytes(data)

    def package(self, apk, abi, *libraries, omit=(), tamper_asset=False,
                wrong_elf=False, browser_asset=False, include_drivers=True,
                include_jni=True):
        with zipfile.ZipFile(apk, "w") as archive:
            for library in ("libflutter.so", *libraries):
                archive.writestr(f"lib/{abi}/{library}", b"fixture")
            for asset in ("esp32_partition_catalog.json", "github_legacy_roots.pem"):
                archive.writestr(f"assets/flutter_assets/{asset}", b"fixture")
            for name, data in self.native_assets.items():
                if name not in omit:
                    archive.writestr(build.ESP_NATIVE_ASSETS + name,
                                     b"tampered" if tamper_asset and name == "PROVENANCE.json" else data)
            if build.ESP_NATIVE_LIBRARY not in omit:
                native_abi = "arm64-v8a" if wrong_elf and abi == "armeabi-v7a" else abi
                archive.writestr(f"lib/{abi}/{build.ESP_NATIVE_LIBRARY}", self.native_elf(native_abi))
            descriptors = [build.ESP_NATIVE_CLASS.encode()] if include_jni else []
            if include_drivers:
                descriptors += [f"Lcom/hoho/android/usbserial/driver/{driver};".encode()
                                for driver in build.USB_DRIVERS]
            archive.writestr("classes.dex", b"\0".join(descriptors))
            if browser_asset:
                archive.writestr("assets/esptool/bundle.js", b"retired browser engine")

    def test_apk_checks_native_libraries_and_required_update_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            def package(abi, *libraries):
                self.package(apk, abi, *libraries)
            package("armeabi-v7a")
            verified = build.verify_apk(apk, "legacy")
            self.assertFalse(verified["onnx"])
            self.assertEqual(verified["esp_backend"], "esp-serial-flasher")
            self.assertEqual(verified["esp_backend_commit"], build.ESP_NATIVE_COMMIT)
            self.assertEqual(verified["esp_native_sha256"], hashlib.sha256(self.native_elf("armeabi-v7a")).hexdigest())
            self.assertNotIn("esptool_js", verified)
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

    def test_usb_packaging_refuses_missing_native_engine_and_tampered_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            self.package(apk, "armeabi-v7a", omit=("PROVENANCE.json",))
            with self.assertRaisesRegex(RuntimeError, "native ESP provenance/license asset"):
                build.verify_apk(apk, "legacy")
            self.package(apk, "armeabi-v7a", tamper_asset=True)
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                build.verify_apk(apk, "legacy")
            self.package(apk, "armeabi-v7a", omit=(build.ESP_NATIVE_LIBRARY,))
            with self.assertRaisesRegex(RuntimeError, "native ESP flashing library"):
                build.verify_apk(apk, "legacy")

    def test_usb_packaging_requires_native_architecture_drivers_jni_and_no_browser(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "test.apk"
            self.package(apk, "armeabi-v7a", wrong_elf=True)
            with self.assertRaisesRegex(RuntimeError, "ELF architecture"):
                build.verify_apk(apk, "legacy")
            self.package(apk, "armeabi-v7a", include_drivers=False)
            with self.assertRaisesRegex(RuntimeError, "native USB driver"):
                build.verify_apk(apk, "legacy")
            self.package(apk, "armeabi-v7a", include_jni=False)
            with self.assertRaisesRegex(RuntimeError, "native ESP JNI channel class"):
                build.verify_apk(apk, "legacy")
            self.package(apk, "armeabi-v7a", browser_asset=True)
            with self.assertRaisesRegex(RuntimeError, "retired browser flashing assets"):
                build.verify_apk(apk, "legacy")

    def test_native_source_requires_exact_inventory_and_unchanged_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vendor = root / "android/app/src/main/cpp/vendor/esp-serial-flasher"
            source = vendor / "src/fixture.c"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"upstream fixture")
            self.assertEqual(build.verify_native_source(root, self.native_assets), 1)
            source.write_bytes(b"mutation")
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                build.verify_native_source(root, self.native_assets)
            source.write_bytes(b"upstream fixture")
            (vendor / "extra.c").write_bytes(b"unreviewed")
            with self.assertRaisesRegex(RuntimeError, "missing or extra"):
                build.verify_native_source(root, self.native_assets)
            (vendor / "extra.c").unlink()
            source.unlink()
            with self.assertRaisesRegex(RuntimeError, "missing or extra"):
                build.verify_native_source(root, self.native_assets)
            modified = dict(self.native_assets, **{"SHA256SUMS.source": self.inventory + b"\n"})
            with self.assertRaisesRegex(RuntimeError, "inventory checksum"):
                build.verify_native_source(root, modified)

    def test_native_provenance_is_exact_pinned_and_unique(self):
        original = json.loads(self.native_assets["PROVENANCE.json"])
        for key, value in {"source_commit": "0" * 40, "version": "latest",
                           "archive_sha256": "bad", "backend": "esptool-js"}.items():
            changed = {**original, key: value}
            with self.assertRaises(RuntimeError):
                build.verify_native_provenance(json.dumps(changed).encode())
        duplicate = self.native_assets["PROVENANCE.json"][:-1] + b',"version":"2.1.0"}'
        with self.assertRaisesRegex(RuntimeError, "JSON is invalid"):
            build.verify_native_provenance(duplicate)

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
