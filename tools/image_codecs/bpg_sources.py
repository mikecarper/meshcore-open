#!/usr/bin/env python3
"""Fetch and prepare the digest-pinned, scalar libbpg/x265 still-image backend."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
from pathlib import Path
import shutil
import urllib.request

from fetch_native_sources import extract_archive


URL = "https://bellard.org/bpg/libbpg-0.9.8.tar.gz"
SHA256 = "c0788e23bdf1a7d36cb4424ccb2fae4c7789ac94949563c4ad0e2569d3bf0095"


def fetch(destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    archives = destination / "archives"
    archives.mkdir(exist_ok=True)
    archive = archives / "libbpg-0.9.8.tar.gz"
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        request = urllib.request.Request(URL, headers={"User-Agent": "MeshCore-Open-image-codec-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read(16 * 1024 * 1024 + 1)
        if len(payload) > 16 * 1024 * 1024 or hashlib.sha256(payload).hexdigest() != SHA256:
            raise ValueError("The libbpg source archive digest does not match")
        archive.write_bytes(payload)
    source = destination / "bpg"
    marker = source / ".meshcore-source-sha256"
    if marker.exists() and marker.read_text().strip() == SHA256:
        return source
    if source.exists():
        raise ValueError(f"An unverified BPG source directory already exists: {source}")
    extract_archive(archive, source, True)
    marker.write_text(SHA256 + "\n")
    print(f"Verified native codec source: libbpg 0.9.8 ({SHA256})", flush=True)
    return source


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise ValueError(f"The pinned libbpg source patch anchor changed: {before[:70]}")
    return source.replace(before, after)


def prepare(source: Path, binary: Path) -> None:
    binary.mkdir(parents=True, exist_ok=True)
    encoder = (source / "bpgenc.c").read_text()
    encoder = replace_once(encoder, "#include <png.h>\n", "")
    encoder = replace_once(encoder, "#include <jpeglib.h>\n", "")
    # The backend accepts RGBA memory only. Remove camera-file metadata readers
    # and the CLI, preserving the original notices and the genuine encoder API.
    begin = encoder.index("Image *read_png(BPGMetaData **pmd,")
    end = encoder.index("void save_yuv1(Image *img, FILE *f)", begin)
    encoder = encoder[:begin] + encoder[end:]
    encoder = encoder[:encoder.index("static int my_write_func(void *opaque,")]
    (binary / "mesh_bpg_encoder_core.c").write_text(
        "/* MeshCore Open, 2026: RGBA memory API; no metadata readers or CLI. */\n" + encoder
    )

    glue = (source / "x265_glue.c").read_text()
    glue = replace_once(
        glue,
        's->api->param_default_preset(p, preset, "ssim");',
        's->api->param_default_preset(p, preset, "ssim");\n'
        '    /* MeshCore Open, 2026: bounded scalar, one-frame worker. */\n'
        '    p->frameNumThreads = 1;\n'
        '    p->numaPools = strdup("none");\n'
        '    p->bEnableWavefront = 0;\n'
        '    p->bDistributeModeAnalysis = 0;\n'
        '    p->bDistributeMotionEstimation = 0;\n'
        '    p->lookaheadDepth = 0;\n'
        '    p->bframes = 0;\n'
        '    p->minCUSize = 8;\n'
        '    p->maxCUSize = (params->width >= 64 && params->height >= 64) ? 64 :\n'
        '        ((params->width >= 32 && params->height >= 32) ? 32 : 16);\n'
        '    p->maxTUSize = p->maxCUSize < 32 ? p->maxCUSize : 32;',
    )
    glue = replace_once(
        glue,
        "s->enc = s->api->encoder_open(p);",
        "s->enc = s->api->encoder_open(p);\n"
        "    if (!s->enc) { s->api->param_free(p); free(s); return NULL; }",
    )
    glue = replace_once(glue, "p->logLevel = X265_LOG_NONE;", "p->logLevel = X265_LOG_ERROR;")
    glue = replace_once(
        glue,
        "size = s->buf_len + data_len;",
        "if (data_len < 0 || data_len > 4 * 1024 * 1024 ||\n"
        "        s->buf_len > 4 * 1024 * 1024 - data_len) {\n"
        '        fprintf(stderr, "BPG output exceeds its size limit\\n"); exit(1);\n'
        "    }\n    size = s->buf_len + data_len;",
    )
    (binary / "mesh_bpg_x265_glue.c").write_text(
        "/* MeshCore Open, 2026: one thread, small coding units, bounded output. */\n" + glue
    )

    # Keep the checked upstream cache intact. This old bundled x265 requires
    # x86 assembly by default; a generic scalar build also validates the same
    # C code used on ARMv7 and needs no Yasm/NEON/SSE assumptions.
    x265 = binary / "x265-source"
    shutil.copytree(source / "x265" / "source", x265, dirs_exist_ok=True)
    cmake_file = x265 / "CMakeLists.txt"
    cmake_source = cmake_file.read_text()
    cmake_source = replace_once(cmake_source, "cmake_policy(SET CMP0025 OLD)", "cmake_policy(SET CMP0025 NEW)")
    cmake_source = replace_once(cmake_source, "cmake_policy(SET CMP0054 OLD)", "cmake_policy(SET CMP0054 NEW)")
    cmake_source = replace_once(cmake_source, "cmake_minimum_required (VERSION 2.8.8)", "cmake_minimum_required (VERSION 3.5)")
    cmake_source = replace_once(
        cmake_source,
        'string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" SYSPROC)',
        'set(SYSPROC "meshcore_scalar") # MeshCore Open: scalar on every ABI',
    )
    cmake_file.write_text(cmake_source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--prepare-build", type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / ".meshcore-fetch.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        source = fetch(destination)
    if args.prepare_build is not None:
        prepare(source, args.prepare_build.resolve())
