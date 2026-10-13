#!/usr/bin/env python3
"""Build either Android profile from the same source in an isolated workspace."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "legacy": {"flutter": "3.32.8", "target": "android-arm", "min_sdk": 21},
    "modern": {"flutter": "3.47.5", "target": "android-arm64", "min_sdk": 28},
}
ESP_BUNDLE_SHA256 = "00ebe6fb0b202976d3e2a3c6b9a6bd438c26a81d2af6739c95ac276a64c1a84e"
USB_DRIVERS = ("CdcAcmSerialDriver", "Ch34xSerialDriver", "Cp21xxSerialDriver", "FtdiSerialDriver")
IMAGE_CODEC_LIBRARIES = (
    "libmesh_image_codec.so", "libmesh_image_worker.so", "libmesh_bpg_worker.so",
    "libheif.so", "libde265.so",
)
IMAGE_CODECS = ("webp", "jpeg", "png", "avif", "jxl", "jp2", "vvc", "heic", "bpg")
IMAGE_CODEC_LICENSES = (
    "GPL-3.0.txt", "aom-LICENSE.txt", "aom-PATENTS.txt",
    "aom-fastfeat-LICENSE.txt", "aom-vector-LICENSE.txt", "avif-LICENSE.txt",
    "bpg-LGPL-2.1.txt", "bpg-wrapper-LICENSE.txt", "bpg-x265-GPL-2.0.txt",
    "brotli-LICENSE.txt", "de265-COPYING.txt", "heif-COPYING.txt",
    "highway-LICENSE-BSD3.txt", "highway-LICENSE.txt", "jpeg-LICENSE.txt",
    "jpeg-README.ijg.txt", "jxl-LICENSE.txt", "jxl-PATENTS.txt",
    "kvazaar-LICENSE.txt", "libyuv-LICENSE.txt", "openjpeg-LICENSE.txt",
    "png-LICENSE.txt", "skcms-LICENSE.txt", "vvdec-LICENSE.txt",
    "vvenc-LICENSE.txt", "webp-LICENSE.txt", "webp-PATENTS.txt",
)


def summarize_tests(log):
    """Retain machine-readable evidence and exclude hidden suite-loader tests."""
    completed = {}
    for line in log.read_text().splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        # Real-async widget workers may emit test-platform process-event arrays.
        # They are not test results and must not corrupt the profile evidence.
        if not isinstance(event, dict):
            continue
        if event.get("type") == "done" and event.get("success") is False:
            raise RuntimeError("Flutter reported an unsuccessful test run")
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


def verify_apk(apk, profile):
    """Check real packaged runtimes, not just Dart capability declarations."""
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        usb_assets = ROOT / "android/app/src/main/assets/esptool"
        for asset in sorted(usb_assets.iterdir()):
            if not asset.is_file():
                continue
            packaged = "assets/esptool/" + asset.name
            if packaged not in names:
                raise RuntimeError(f"APK is missing offline USB asset: {packaged}")
            digest = hashlib.sha256(archive.read(packaged)).hexdigest()
            expected_digest = (ESP_BUNDLE_SHA256 if asset.name == "bundle.js" else
                               hashlib.sha256(asset.read_bytes()).hexdigest())
            if digest != expected_digest:
                raise RuntimeError(f"APK offline USB asset checksum mismatch: {packaged}")
        dex = b"".join(archive.read(name) for name in names
                       if name.startswith("classes") and name.endswith(".dex"))
        for driver in USB_DRIVERS:
            descriptor = f"Lcom/hoho/android/usbserial/driver/{driver};".encode()
            if descriptor not in dex:
                raise RuntimeError(f"APK is missing required native USB driver: {driver}")
        image_license_assets = ROOT / "android/app/src/main/assets/image_codecs/licenses"
        license_files = {path.name: path for path in image_license_assets.iterdir()
                         if path.is_file()}
        for required in IMAGE_CODEC_LICENSES:
            if required not in license_files:
                raise RuntimeError(f"Source is missing required image codec license: {required}")
        # Check every notice in the source directory, including future additions.
        for filename, asset in sorted(license_files.items()):
            packaged = "assets/image_codecs/licenses/" + filename
            if packaged not in names:
                raise RuntimeError(f"APK is missing image codec license asset: {packaged}")
            if archive.read(packaged) != asset.read_bytes():
                raise RuntimeError(f"APK image codec license checksum mismatch: {packaged}")
    libraries = [name for name in names if name.startswith("lib/") and name.endswith(".so")]
    abis = {name.split("/")[1] for name in libraries}
    expected = {"armeabi-v7a"} if profile == "legacy" else {"arm64-v8a"}
    if abis != expected:
        raise RuntimeError(f"Unexpected APK ABIs: {abis}; expected {expected}")
    for abi in sorted(expected):
        for library in IMAGE_CODEC_LIBRARIES:
            packaged = f"lib/{abi}/{library}"
            if packaged not in libraries:
                raise RuntimeError(f"APK is missing required native image codec library: {packaged}")
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
            "usb_drivers": list(USB_DRIVERS), "esptool_js": "0.7.0",
            "esptool_bundle_sha256": ESP_BUNDLE_SHA256,
            "image_codecs": {"codecs": list(IMAGE_CODECS),
                             "libraries": list(IMAGE_CODEC_LIBRARIES),
                             "license_assets": sorted(license_files)}}


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
    staging_root = ROOT / ".build"
    staging_root.mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix=f"android-{args.profile}-", dir=staging_root))
    source_hash = prepare(ROOT, workspace, args.profile)
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
    manifest["packaging"] = verify_apk(apk, args.profile)
    manifest["apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
    manifest["apk_bytes"] = apk.stat().st_size
    (output / "build-profile.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"APK: {apk}\nSHA256: {manifest['apk_sha256']}", flush=True)


if __name__ == "__main__":
    main()
