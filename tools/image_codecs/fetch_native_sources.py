#!/usr/bin/env python3
"""Fetch immutable image codec sources outside the checkout, verifying every archive."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request


ARCHIVES = (
    ("avif", "https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.2.1.tar.gz", "9c859c7c12ccb0f407511bfe303e6a7247f5f6738f54852662c6df8048daddf4", True),
    ("webp", "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz", "7d6fab70cf844bf6769077bd5d7a74893f8ffd4dfb42861745750c63c2a5c92c", True),
    ("openjpeg", "https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.3.tar.gz", "368fe0468228e767433c9ebdea82ad9d801a3ad1e4234421f352c8b06e7aa707", True),
    ("jxl", "https://github.com/libjxl/libjxl/archive/refs/tags/v0.11.1.tar.gz", "1492dfef8dd6c3036446ac3b340005d92ab92f7d48ee3271b5dac1d36945d3d9", True),
    ("jxl/third_party/highway", "https://github.com/google/highway/archive/457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz", "5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a", True),
    ("jxl/third_party/brotli", "https://github.com/google/brotli/archive/36533a866ed1ca4b75cf049f4521e4ec5fe24727.tar.gz", "9dbeae5b67739ad00f8e355a20f9af5507ed578abace0a4939a54c6c2b597005", True),
    ("jxl/third_party/skcms", "https://github.com/google/skcms/archive/42030a771244ba67f86b1c1c76a6493f873c5f91.tar.gz", "f070f9f7ac770ea2aab977cdc628e087a0eabaae9dd04883a511dfd6e37232b5", True),
    ("jpeg", "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.0.tar.gz", "35fec2e1ddfb05ecf6d93e50bc57c1e54bc81c16d611ddf6eff73fff266d8285", True),
    ("png", "https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.47.tar.gz", "631a4c58ea6c10c81f160c4b21fa8495b715d251698ebc2552077e8450f30454", True),
    ("heif", "https://github.com/strukturag/libheif/archive/refs/tags/v1.23.6.tar.gz", "c9a00b0452f5c16d72ef71e5e40c0e90fbe2ad37148d27a1b2f9bb21546f5f03", True),
    ("de265", "https://github.com/strukturag/libde265/archive/refs/tags/v1.1.3.tar.gz", "189baa08fd6d2dd34db099de411bd6b2e6bd5eb88e81236a3d0fa3826b9715c4", True),
    ("kvazaar", "https://github.com/ultravideo/kvazaar/archive/refs/tags/v2.3.2.tar.gz", "ddd0038696631ca5368d8e40efee36d2bbb805854b9b1dda8b12ea9b397ea951", True),
)
AOM_COMMIT = "3b624af45b86646a20b11a9ff803aeae588cdee6"


def extract_archive(archive: Path, destination: Path, strip_root: bool) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            parts = Path(member.name).parts
            if strip_root:
                parts = parts[1:]
            if not parts:
                continue
            if any(part in ("..", "") for part in parts) or Path(*parts).is_absolute():
                raise ValueError("Unsafe source archive path")
            member.name = str(Path(*parts))
            # Upstream JPEG XL includes benchmark script symlinks. They are
            # unused by this build; skipping links also avoids extraction via
            # a source archive link outside the cache directory.
            if member.issym() or member.islnk():
                continue
            source.extract(member, destination, filter="data")


def fetch(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    archive_dir = destination / "archives"
    archive_dir.mkdir(exist_ok=True)
    for name, url, digest, strip_root in ARCHIVES:
        target = destination / name
        marker = target / ".meshcore-source-sha256"
        if marker.exists() and marker.read_text().strip() == digest:
            continue
        archive = archive_dir / (name.replace("/", "-") + ".tar.gz")
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            request = urllib.request.Request(url, headers={"User-Agent": "MeshCore-Open-image-codec-build"})
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read(64 * 1024 * 1024 + 1)
            if len(payload) > 64 * 1024 * 1024 or hashlib.sha256(payload).hexdigest() != digest:
                raise ValueError(f"Source digest mismatch for {name}")
            archive.write_bytes(payload)
        print(f"Verified native codec source: {name}", flush=True)
        extract_archive(archive, target, strip_root)
        marker.write_text(digest + "\n")
    aom = destination / "aom"
    if not (aom / ".git").exists():
        subprocess.run(["git", "clone", "--depth", "1", "--branch", "v3.12.0", "https://aomedia.googlesource.com/aom", str(aom)], check=True, timeout=180)
    actual = subprocess.check_output(["git", "-C", str(aom), "rev-parse", "HEAD"], text=True).strip()
    if actual != AOM_COMMIT:
        raise ValueError("libaom source commit mismatch")
    if subprocess.check_output(["git", "-C", str(aom), "status", "--porcelain"], text=True).strip():
        raise ValueError("libaom source checkout has modifications")
    print(f"Verified native codec source: aom {actual}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "meshcore-image-codecs-v1")
    args = parser.parse_args()
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    # Gradle can configure multiple ABIs at once. Hold a process-wide lock so
    # one fetch cannot truncate an archive while another extracts it.
    with (destination / ".meshcore-fetch.lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        fetch(destination)
