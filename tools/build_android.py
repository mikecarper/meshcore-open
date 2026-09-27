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
    return {"abis": sorted(abis), "onnx": onnx, "llamadart": llama}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=PROFILES)
    parser.add_argument("--flutter", required=True, type=Path)
    parser.add_argument("--sideload", action="store_true",
                        help="Explicitly use the local debug certificate; not a store release")
    parser.add_argument("--signing-properties", type=Path,
                        help="Private key.properties with an absolute storeFile path")
    parser.add_argument("--test", action="store_true", help="Run the full Flutter test suite")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    flutter = args.flutter.expanduser().resolve()
    profile = PROFILES[args.profile]
    version = json.loads(run([flutter, "--version", "--machine"], ROOT, capture=True))
    if version["frameworkVersion"] != profile["flutter"]:
        parser.error(f"{args.profile} requires Flutter {profile['flutter']}")
    if not args.prepare_only and not (args.sideload or args.signing_properties):
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
    if args.test:
        run([flutter, "test", "--no-pub", define, "--reporter", "expanded"], workspace, env)
    run([flutter, "build", "apk", "--release", "--no-pub", define,
         "--target-platform", profile["target"]], workspace, env)
    output = workspace / "artifacts"
    output.mkdir()
    label = "sideload" if args.sideload else "release"
    apk = output / f"meshcore-open-{args.profile}-{label}.apk"
    shutil.copy2(workspace / "build/app/outputs/flutter-apk/app-release.apk", apk)
    manifest["packaging"] = verify_apk(apk, args.profile)
    manifest["apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
    manifest["apk_bytes"] = apk.stat().st_size
    (output / "build-profile.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"APK: {apk}\nSHA256: {manifest['apk_sha256']}", flush=True)


if __name__ == "__main__":
    main()
