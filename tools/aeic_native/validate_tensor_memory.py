#!/usr/bin/env python3
"""Compare complete native runs: every FP32 tensor hash and saved image bytes."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def read_run(directory):
    directory = Path(directory)
    text = (directory / "decode.log").read_text()
    final = re.search(r"^DECODE_COMPLETE .*peak_kb=(\d+).*output=(.+)$", text, re.M)
    if not final or "RESULT_STATUS degraded=false recovery_events=0" not in text:
        raise ValueError(f"Run did not complete normally: {directory}")
    tensors = dict(re.findall(r"^TENSOR (\S+) CHW=\S+ fnv1a64=(\w+)", text, re.M))
    image = Path(final.group(2).strip()).read_bytes()
    return tensors, image, int(final.group(1)), text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    args = parser.parse_args()
    old, old_image, old_peak, _ = read_run(args.baseline)
    new, new_image, new_peak, text = read_run(args.candidate)
    if old != new:
        changed = [key for key in old.keys() | new.keys() if old.get(key) != new.get(key)]
        raise ValueError(f"FP32 tensor hashes changed: {changed[:20]}")
    if old_image != new_image:
        raise ValueError("Saved image bytes differ")
    result = {"tensor_hashes_equal": len(new), "saved_image_bytes_equal": True,
              "image_sha256": hashlib.sha256(new_image).hexdigest(),
              "baseline_peak_kib": old_peak, "candidate_peak_kib": new_peak,
              "peak_reduction_kib": old_peak - new_peak,
              "row_tiled_stages": len(re.findall(r"^ROW_TILED ", text, re.M)),
              "spilled_tensors": len(re.findall(r"^TENSOR_SPILLED ", text, re.M)),
              "reused_add_stages": len(re.findall(r"^INPLACE_ADD ", text, re.M))}
    print(json.dumps(result, indent=2))
    (Path(args.candidate) / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
