#!/usr/bin/env python3
"""Fetch digest-pinned VVenC/VVdeC sources for the bundled still-image worker."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
from pathlib import Path
import urllib.request

from fetch_native_sources import extract_archive


ARCHIVES = (
    ("vvenc", "https://codeload.github.com/fraunhoferhhi/vvenc/tar.gz/refs/tags/v1.14.0",
     "dd43d061d59dbc0d9b9ae5b99cb40672877dd811646228938f065798939ee174"),
    ("vvdec", "https://codeload.github.com/fraunhoferhhi/vvdec/tar.gz/refs/tags/v3.2.1",
     "5c334557a33cd93e981b84ba0e77126ef970a38e2481b67f0475db40f75379b8"),
)


def fetch(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    archives = destination / "archives"
    archives.mkdir(exist_ok=True)
    for name, url, digest in ARCHIVES:
        target = destination / name
        marker = target / ".meshcore-source-sha256"
        if marker.exists() and marker.read_text().strip() == digest:
            continue
        if target.exists():
            raise ValueError(f"Unverified VVC source directory already exists: {target}")
        archive = archives / f"{name}.tar.gz"
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            request = urllib.request.Request(url, headers={"User-Agent": "MeshCore-Open-image-codec-build"})
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read(64 * 1024 * 1024 + 1)
            if len(data) > 64 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"VVC source digest mismatch: {name}")
            archive.write_bytes(data)
        extract_archive(archive, target, True)
        marker.write_text(digest + "\n")
        print(f"Verified native codec source: {name} ({digest})", flush=True)
    # VVenC supports superprojects, but its module path is still relative to
    # the top-level project in this release. Apply one deterministic build-only
    # correction after verifying/extracting the pinned archive.
    cmake_file = destination / "vvenc" / "CMakeLists.txt"
    source = cmake_file.read_text()
    original = 'set( CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake/modules" )'
    patched = 'set( CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules" )'
    if source.count(original) == 1:
        cmake_file.write_text(source.replace(original, patched))
    elif source.count(patched) != 1:
        raise ValueError("The pinned VVenC CMake integration anchor changed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / ".meshcore-fetch.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        fetch(destination)
