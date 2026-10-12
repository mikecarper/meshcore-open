#!/usr/bin/env python3
"""Build either Android profile from the same source in an isolated workspace."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "legacy": {"flutter": "3.32.8", "target": "android-arm", "min_sdk": 21},
    "modern": {"flutter": "3.47.5", "target": "android-arm64", "min_sdk": 28},
}
ESP_NATIVE_LIBRARY = "libmeshcore_esp_flasher.so"
ESP_NATIVE_BACKEND = "esp-serial-flasher"
ESP_NATIVE_VERSION = "2.1.0"
ESP_NATIVE_COMMIT = "24997fe693ff17e6598d7eb1d37af312752100aa"
ESP_NATIVE_ARCHIVE_SHA256 = "4e798bd2de98e595addda3064eeaf190b09843a45ed83ffb968279bfd4b05242"
ESP_NATIVE_INVENTORY_SHA256 = "c81abf3598a4e20cdad0ef8dbcda64dc9bbaf466be8c9c89aa69d9d04492e259"
ESP_NATIVE_ASSETS = "assets/native_flasher/"
ESP_NATIVE_CLASS = "Lcom/meshcore/meshcore_open/MeshcoreUsbEspEngine;"
USB_DRIVERS = ("CdcAcmSerialDriver", "Ch34xSerialDriver", "Cp21xxSerialDriver", "FtdiSerialDriver")


def summarize_tests(log):
    """Retain machine-readable evidence and exclude hidden suite-loader tests."""
    completed = {}
    for line in log.read_text().splitlines():
        event = json.loads(line)
        if event.get("type") == "testDone" and not event.get("hidden", False):
            completed[event["testID"]] = event
    if not completed:
        raise RuntimeError("Flutter test log contains no completed visible tests")
    summary = {"passed": 0, "failed": 0, "skipped": 0}
    for event in completed.values():
        result = "skipped" if event.get("skipped", False) else (
            "passed" if event.get("result") == "success" else "failed")
        summary[result] += 1
    if summary["failed"]:
        raise RuntimeError(f"Flutter test log contains failures: {summary}")
    return summary


def run(args, cwd, env=None, capture=False):
    return subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env, check=True,
        text=True, stdout=subprocess.PIPE if capture else None,
    ).stdout


def source_files(root):
    names = run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        root, capture=True,
    ).split("\0")
    return sorted({name for name in names if name and (root / name).is_file()})


def prepare(root, destination, profile):
    """Copy versioned/non-ignored sources, never local keys or build outputs."""
    digest = hashlib.sha256()
    for name in source_files(root):
        path = Path(name)
        if path.name in {"key.properties", "local.properties"} or name == "pubspec_overrides.yaml":
            # The selected override is copied explicitly below.
            continue
        if path.suffix in {".jks", ".keystore"} or path.name.startswith(".env"):
            continue
        source = root / path
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        digest.update(name.encode() + b"\0" + source.read_bytes())
    if profile == "legacy":
        legacy = root / "build_profiles" / "legacy"
        for name in ("pubspec.lock", "pubspec_overrides.yaml"):
            shutil.copy2(legacy / name, destination / name)
    return digest.hexdigest()


def native_esp_assets(root=ROOT):
    """Pinned provenance/license inputs from the frozen source checkout."""
    directory = root / "android/app/src/main/assets/native_flasher"
    assets = {}
    for name in ("PROVENANCE.json", "SHA256SUMS.source",
                 "LICENSE.esp-serial-flasher", "LICENSE.usb-serial",
                 "LICENSE.md5", "NOTICE"):
        path = directory / name
        if not path.is_file() or path.stat().st_size > 1024 * 1024:
            raise RuntimeError(f"Native ESP source asset is missing or too large: {name}")
        assets[name] = path.read_bytes()
    return assets


def verify_native_provenance(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate native provenance key")
            result[key] = value
        return result
    try:
        provenance = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise RuntimeError("Native ESP provenance JSON is invalid") from None
    if not isinstance(provenance, dict) or any(
        provenance.get(key) != value for key, value in {
            "backend": ESP_NATIVE_BACKEND, "version": ESP_NATIVE_VERSION,
            "source_commit": ESP_NATIVE_COMMIT,
            "archive_sha256": ESP_NATIVE_ARCHIVE_SHA256,
            "source_inventory_sha256": ESP_NATIVE_INVENTORY_SHA256,
            "upstream": "https://github.com/espressif/esp-serial-flasher",
        }.items()
    ):
        raise RuntimeError("Native ESP provenance does not match the pinned backend")
    for key in ("archive_sha256", "source_inventory_sha256"):
        value = provenance.get(key)
        if (not isinstance(value, str) or len(value) != 64
                or any(char not in "0123456789abcdef" for char in value)):
            raise RuntimeError(f"Native ESP provenance has invalid {key}")
    return provenance


def verify_native_source(root, assets):
    """Bind every vendored upstream source byte to the reviewed inventory."""
    verify_native_provenance(assets["PROVENANCE.json"])
    inventory = assets["SHA256SUMS.source"]
    if hashlib.sha256(inventory).hexdigest() != ESP_NATIVE_INVENTORY_SHA256:
        raise RuntimeError("Native ESP source inventory checksum mismatch")
    try:
        lines = inventory.decode("utf-8").splitlines(keepends=True)
    except UnicodeError:
        raise RuntimeError("Native ESP source inventory is invalid UTF-8") from None
    vendor = root / "android/app/src/main/cpp/vendor/esp-serial-flasher"
    entries = {}
    for line in lines:
        match = re.fullmatch(r"([a-f0-9]{64})  ([A-Za-z0-9_./-]+)\n", line)
        if not match:
            raise RuntimeError("Native ESP source inventory has an invalid entry")
        digest, name = match.groups()
        parts = name.split("/")
        if any(part in ("", ".", "..") for part in parts) or name in entries:
            raise RuntimeError("Native ESP source inventory has an unsafe or duplicate path")
        entries[name] = digest
    # The pinned inventory digest binds its exact ordering. Do not reinterpret
    # the producer's path collation using the build host's sorting rules.
    if not entries:
        raise RuntimeError("Native ESP source inventory is empty")
    actual = set()
    for path in vendor.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("Native ESP vendored source must not contain symlinks")
        if path.is_file():
            actual.add(path.relative_to(vendor).as_posix())
    if actual != set(entries):
        raise RuntimeError("Native ESP vendored source inventory has missing or extra files")
    for name, digest in entries.items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Native ESP vendored source changed: {name}")
    return len(entries)


def verify_native_elf(data, abi):
    """Reject mislabeled/non-native engine files, not just a .so filename."""
    expected = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183)}[abi]
    if (len(data) < 64 or data[:4] != b"\x7fELF" or data[4:7] != bytes((expected[0], 1, 1))
            or struct.unpack_from("<HH", data, 16) != (3, expected[1])):
        raise RuntimeError(f"Native ESP library ELF architecture is invalid for {abi}")


def verify_apk(apk, profile, source_root=ROOT):
    """Check real packaged runtimes, not just Dart capability declarations."""
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError("APK contains duplicate packaged entries")
        if any(name.startswith("assets/esptool/") for name in names):
            raise RuntimeError("APK contains retired browser flashing assets")
        source_assets = native_esp_assets(source_root)
        provenance = verify_native_provenance(source_assets["PROVENANCE.json"])
        for name, expected_data in source_assets.items():
            packaged = ESP_NATIVE_ASSETS + name
            if packaged not in names:
                raise RuntimeError(f"APK is missing native ESP provenance/license asset: {packaged}")
            if archive.read(packaged) != expected_data:
                raise RuntimeError(f"APK native ESP asset checksum mismatch: {packaged}")
        abi = "armeabi-v7a" if profile == "legacy" else "arm64-v8a"
        native_library = f"lib/{abi}/{ESP_NATIVE_LIBRARY}"
        if native_library not in names:
            raise RuntimeError(f"APK is missing native ESP flashing library: {native_library}")
        native_data = archive.read(native_library)
        verify_native_elf(native_data, abi)
        native_digest = hashlib.sha256(native_data).hexdigest()
        dex = b"".join(archive.read(name) for name in names
                       if name.startswith("classes") and name.endswith(".dex"))
        for driver in USB_DRIVERS:
            descriptor = f"Lcom/hoho/android/usbserial/driver/{driver};".encode()
            if descriptor not in dex:
                raise RuntimeError(f"APK is missing required native USB driver: {driver}")
        if ESP_NATIVE_CLASS.encode() not in dex:
            raise RuntimeError("APK is missing the native ESP JNI channel class")
    libraries = [name for name in names if name.startswith("lib/") and name.endswith(".so")]
    abis = {name.split("/")[1] for name in libraries}
    expected = {"armeabi-v7a"} if profile == "legacy" else {"arm64-v8a"}
    if abis != expected:
        raise RuntimeError(f"Unexpected APK ABIs: {abis}; expected {expected}")
    onnx = any("onnxruntime" in name for name in libraries)
    llama = any("llamadart" in name for name in libraries)
    if profile == "modern" and not (onnx and llama):
        raise RuntimeError("Modern APK is missing a native inference runtime")
    if any("LiteRtLm" in name for name in libraries):
        raise RuntimeError("APK includes an unused runtime requiring a newer Android API")
    if profile == "legacy" and (onnx or llama):
        raise RuntimeError("Legacy APK unexpectedly includes native AI")
    for asset in ("esp32_partition_catalog.json", "github_legacy_roots.pem"):
        if not any(name.endswith("/" + asset) for name in names):
            raise RuntimeError(f"APK is missing required asset: {asset}")
    return {"abis": sorted(abis), "onnx": onnx, "llamadart": llama,
            "usb_drivers": list(USB_DRIVERS), "esp_backend": ESP_NATIVE_BACKEND,
            "esp_backend_version": ESP_NATIVE_VERSION,
            "esp_backend_commit": ESP_NATIVE_COMMIT,
            "esp_native_library": native_library, "esp_native_sha256": native_digest,
            "esp_native_provenance_sha256": hashlib.sha256(source_assets["PROVENANCE.json"]).hexdigest(),
            "esp_backend_archive_sha256": provenance["archive_sha256"],
            "esp_backend_source_inventory_sha256": provenance["source_inventory_sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=PROFILES)
    parser.add_argument("--flutter", required=True, type=Path)
    parser.add_argument("--sideload", action="store_true",
                        help="Explicitly use the local debug certificate; not a store release")
    parser.add_argument("--signing-properties", type=Path,
                        help="Private key.properties with an absolute storeFile path")
    parser.add_argument("--test", action="store_true", help="Run the full Flutter test suite")
    parser.add_argument("--test-only", action="store_true",
                        help="Run full profile tests and save evidence without building/signing an APK")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    flutter = args.flutter.expanduser().resolve()
    profile = PROFILES[args.profile]
    version = json.loads(run([flutter, "--version", "--machine"], ROOT, capture=True))
    if version["frameworkVersion"] != profile["flutter"]:
        parser.error(f"{args.profile} requires Flutter {profile['flutter']}")
    if not (args.prepare_only or args.test_only) and not (args.sideload or args.signing_properties):
        parser.error("Choose --sideload or --signing-properties; signing is never implicit")
    if args.sideload and args.signing_properties:
        parser.error("Choose only one signing mode")
    verify_native_source(ROOT, native_esp_assets())
    staging_root = ROOT / ".build"
    staging_root.mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix=f"android-{args.profile}-", dir=staging_root))
    source_hash = prepare(ROOT, workspace, args.profile)
    native_source_count = verify_native_source(workspace, native_esp_assets(workspace))
    manifest = {
        "profile": args.profile, "flutter": version["frameworkVersion"],
        "app_version": next(line.split(":", 1)[1].strip() for line in
                            (workspace / "pubspec.yaml").read_text().splitlines()
                            if line.startswith("version:")),
        "dart": version["dartSdkVersion"], "target": profile["target"],
        "min_sdk": profile["min_sdk"], "source_sha256": source_hash,
        "git_commit": run(["git", "rev-parse", "HEAD"], ROOT, capture=True).strip(),
        "dirty": bool(run(["git", "status", "--porcelain"], ROOT, capture=True).strip()),
        "native_ai": args.profile == "modern",
        "esp_native_source_files_verified": native_source_count,
        "signing": ("local-debug-sideload" if args.sideload else
                    "private-key" if args.signing_properties else "not-configured"),
    }
    (workspace / "build-profile.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Workspace: {workspace}", flush=True)
    if args.prepare_only:
        return
    if args.signing_properties:
        shutil.copy2(args.signing_properties, workspace / "android" / "key.properties")
        os.chmod(workspace / "android" / "key.properties", 0o600)
    env = os.environ.copy()
    env["MESHCORE_ALLOW_TEST_SIGNING"] = "1" if args.sideload else "0"
    define = f"--dart-define=LEGACY_ARM32={'true' if args.profile == 'legacy' else 'false'}"
    run([flutter, "pub", "get", "--enforce-lockfile"], workspace, env)
    if args.test or args.test_only:
        test_log = workspace / "flutter-tests.jsonl"
        run([flutter, "test", "--no-pub", define, "--reporter", "expanded",
             "--file-reporter", f"json:{test_log}"], workspace, env)
        manifest["tests"] = summarize_tests(test_log)
    if args.test_only:
        output = workspace / "artifacts"
        output.mkdir()
        shutil.copy2(test_log, output / "flutter-tests.jsonl")
        (output / "build-profile.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Test evidence: {output}\nTests: {manifest['tests']}", flush=True)
        return
    run([flutter, "build", "apk", "--release", "--no-pub", define,
         "--target-platform", profile["target"]], workspace, env)
    output = workspace / "artifacts"
    output.mkdir()
    label = "sideload" if args.sideload else "release"
    apk = output / f"meshcore-open-{args.profile}-{label}.apk"
    shutil.copy2(workspace / "build/app/outputs/flutter-apk/app-release.apk", apk)
    if args.test:
        shutil.copy2(test_log, output / "flutter-tests.jsonl")
    manifest["packaging"] = verify_apk(apk, args.profile, workspace)
    manifest["apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
    manifest["apk_bytes"] = apk.stat().st_size
    (output / "build-profile.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"APK: {apk}\nSHA256: {manifest['apk_sha256']}", flush=True)


if __name__ == "__main__":
    main()
