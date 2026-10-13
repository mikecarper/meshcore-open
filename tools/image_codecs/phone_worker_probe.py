#!/usr/bin/env python3
"""Exercise the exact native codec worker on one explicitly selected phone."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import time

from PIL import Image, ImageOps


MAGIC = 0x31434D49
CODECS = {"webp": 1, "jpeg": 2, "png": 3, "avif": 4, "jxl": 5, "jp2": 6,
          "vvc": 7, "heic": 8, "bpg": 9}
REMOTE_DIRECTORY = "/data/local/tmp/meshcore-image-codec-probe"


class WorkerStopUnconfirmed(RuntimeError):
    """Do not start another algorithm while a timed-out child may still run."""


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Native codec exceeded its phone probe budget")
    return remaining


def _stop_remote_worker(serial, remote, pidfile):
    # Check the task PID's actual executable before sending a signal. No global
    # pkill/USB/ADB/Bluetooth reset can affect another phone or radio test.
    quote = shlex.quote
    command = (
        f"if [ ! -r {quote(pidfile)} ]; then exit 1; fi; "
        f"read task_pid < {quote(pidfile)}; "
        "case \"$task_pid\" in ''|*[!0-9]*) exit 1;; esac; "
        "if [ ! -r /proc/$task_pid/cmdline ]; then exit 0; fi; "
        "task_command=$(tr '\\000' '\\n' < /proc/$task_pid/cmdline | sed -n '1p'); "
        f"if [ \"$task_command\" != {quote(remote)} ]; then exit 0; fi; "
        "kill -9 \"$task_pid\" || exit 1; "
        "task_checks=0; "
        "while [ -r /proc/$task_pid/cmdline ]; do "
        "task_command=$(tr '\\000' '\\n' < /proc/$task_pid/cmdline | sed -n '1p'); "
        f"if [ \"$task_command\" != {quote(remote)} ]; then exit 0; fi; "
        "task_checks=$((task_checks + 1)); "
        "if [ \"$task_checks\" -ge 30 ]; then exit 1; fi; "
        "sleep 0.1; done"
    )
    try:
        stopped = subprocess.run(["adb", "-s", serial, "shell", command],
                                 capture_output=True, timeout=5)
        return stopped.returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def codec_request(serial, remote, codec, operation, payload, quality=45, width=0, height=0,
                  budget=120):
    header = struct.pack("<7I", MAGIC, operation, codec, quality, width, height, len(payload))
    started = time.monotonic()
    deadline = started + min(120, budget)
    # Android 5's shell service only offers a PTY. Push binary input and use
    # the raw exec service so terminal CR/LF processing cannot corrupt bytes.
    token = f"{codec}-{operation}-{time.monotonic_ns()}"
    remote_input = f"{REMOTE_DIRECTORY}/{token}.input"
    remote_pid = f"{REMOTE_DIRECTORY}/{token}.pid"
    with tempfile.NamedTemporaryFile(prefix="meshcore-image-request-", suffix=".bin") as request:
        request.write(header + payload)
        request.flush()
        subprocess.run(["adb", "-s", serial, "push", request.name, remote_input],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=_remaining(deadline))
    command = (f"echo $$ > {shlex.quote(remote_pid)}; "
               f"export LD_LIBRARY_PATH={shlex.quote(REMOTE_DIRECTORY)}; "
               f"exec {shlex.quote(remote)} < {shlex.quote(remote_input)}")
    process = subprocess.Popen(["adb", "-s", serial, "exec-out",
                                command],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        output, error = process.communicate(timeout=_remaining(deadline))
    except (subprocess.TimeoutExpired, TimeoutError):
        stopped = _stop_remote_worker(serial, remote, remote_pid)
        process.kill()
        try:
            process.communicate(timeout=5)
        except subprocess.SubprocessError:
            stopped = False
        if not stopped:
            raise WorkerStopUnconfirmed("Could not confirm the previous phone codec stopped")
        raise TimeoutError("Native codec exceeded its phone probe budget")
    finally:
        # These two files belong only to this request in the dedicated task dir.
        try:
            subprocess.run(["adb", "-s", serial, "shell",
                            f"rm -f {shlex.quote(remote_input)} {shlex.quote(remote_pid)}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (subprocess.SubprocessError, OSError):
            pass
    elapsed = time.monotonic() - started
    # API21's linker prints a warning about modern PIE flags on stderr, which
    # old adbd combines with stdout. The app bridge uses separate IPC pipes;
    # only this developer exec probe needs to remove that known preamble.
    marker = struct.pack('<I', MAGIC)
    position = output.find(marker)
    if position > 0 and all(line.startswith(b'WARNING: linker:')
                            for line in output[:position].splitlines()):
        output = output[position:]
    if len(output) < 20:
        raise RuntimeError(f"Worker returned no header: {error.decode(errors='replace')[:300]}")
    magic, status, out_width, out_height, length = struct.unpack("<5I", output[:20])
    if magic != MAGIC or len(output) != length + 20:
        raise RuntimeError(f"Worker returned invalid binary framing: {output[:100]!r}")
    if status or process.returncode:
        raise RuntimeError(output[20:].decode(errors="replace")[:300])
    return output[20:], out_width, out_height, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--bpg-worker", type=Path,
                        help="The separate real BPG/x265 child executable")
    parser.add_argument("--library-dir", type=Path,
                        help="Directory containing the main worker's libheif.so and libde265.so")
    parser.add_argument("--codecs", nargs="+", choices=list(CODECS), default=list(CODECS))
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--skip-upload", action="store_true",
                        help="Use the exact worker already uploaded by this test run")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Only this task-specific directory is written on the selected phone.
    remote = f"{REMOTE_DIRECTORY}/libmesh_image_worker.so"
    remote_bpg = f"{REMOTE_DIRECTORY}/libmesh_bpg_worker.so"
    subprocess.run(["adb", "-s", args.serial, "shell", "mkdir", "-p", REMOTE_DIRECTORY],
                   check=True, timeout=30)
    if not args.skip_upload:
        subprocess.run(["adb", "-s", args.serial, "push", str(args.worker), remote], check=True, timeout=60)
        if args.bpg_worker is not None:
            subprocess.run(["adb", "-s", args.serial, "push", str(args.bpg_worker), remote_bpg], check=True, timeout=60)
        if args.library_dir is not None:
            for name in ("libheif.so", "libde265.so"):
                library = args.library_dir / name
                if not library.is_file():
                    raise ValueError(f"Missing required worker library: {library}")
                subprocess.run(["adb", "-s", args.serial, "push", str(library),
                                f"{REMOTE_DIRECTORY}/{name}"], check=True, timeout=60)
    executables = [remote] + ([remote_bpg] if args.bpg_worker is not None else [])
    subprocess.run(["adb", "-s", args.serial, "shell", "chmod", "755", *executables], check=True, timeout=30)
    with Image.open(args.image) as original:
        raster = ImageOps.exif_transpose(original).convert("RGBA")
    raster.thumbnail((512, 512))
    rgba = raster.tobytes()
    results = []
    quarantined = False
    for name in args.codecs:
        codec = CODECS[name]
        started = time.monotonic()
        try:
            if quarantined:
                raise WorkerStopUnconfirmed("Skipped because the previous worker stop was unconfirmed")
            if name == "bpg" and args.bpg_worker is None:
                raise RuntimeError("The separate BPG worker was not supplied")
            selected_worker = remote_bpg if name == "bpg" else remote
            encoded, _, _, encode_seconds = codec_request(
                args.serial, selected_worker, codec, 0, rgba, width=raster.width, height=raster.height)
            remaining = _remaining(started + 120)
            decoded, width, height, decode_seconds = codec_request(
                args.serial, selected_worker, codec, 1, encoded, budget=remaining)
            if (width, height, len(decoded)) != (raster.width, raster.height, len(rgba)):
                raise RuntimeError("Decoded raster dimensions do not match")
            display_path = args.output.with_name(f"{args.output.stem}-{name}.png")
            # Build a new PNG from pixels only; camera metadata is not copied.
            Image.frombytes("RGBA", (width, height), decoded).save(display_path, format="PNG")
            results.append({"codec": name, "success": True, "width": width,
                            "height": height, "encoded_bytes": len(encoded),
                            "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
                            "encode_seconds": encode_seconds, "decode_seconds": decode_seconds,
                            "display_png": str(display_path),
                            "display_png_sha256": hashlib.sha256(display_path.read_bytes()).hexdigest()})
        except Exception as error:
            if isinstance(error, WorkerStopUnconfirmed):
                quarantined = True
            results.append({"codec": name, "success": False, "error": str(error),
                            "elapsed_seconds": time.monotonic() - started})
        print(json.dumps(results[-1]), flush=True)
    report = {"serial": args.serial, "worker_sha256": hashlib.sha256(args.worker.read_bytes()).hexdigest(),
              "image_sha256": hashlib.sha256(args.image.read_bytes()).hexdigest(),
              "per_algorithm_limit_seconds": 120, "results": results}
    if args.bpg_worker is not None:
        report["bpg_worker_sha256"] = hashlib.sha256(args.bpg_worker.read_bytes()).hexdigest()
    if args.library_dir is not None:
        report["library_sha256"] = {
            name: hashlib.sha256((args.library_dir / name).read_bytes()).hexdigest()
            for name in ("libheif.so", "libde265.so")
        }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    if not all(result["success"] for result in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
