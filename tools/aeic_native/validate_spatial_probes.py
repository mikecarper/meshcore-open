#!/usr/bin/env python3
"""Run isolated matrix-stage diagnostics on a connected phone, never full decode."""
import argparse
import array
import json
import math
from pathlib import Path
import re
import shlex
import subprocess
import sys


def run(arguments, timeout=120):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Command failed: " + result.stderr.strip())
    return result.stdout


def compare(actual_path, expected_path, expected_count):
    actual = array.array("f")
    actual.frombytes(actual_path.read_bytes())
    expected = array.array("f")
    expected.frombytes(expected_path.read_bytes())
    if sys.byteorder != "little":
        actual.byteswap()
        expected.byteswap()
    if len(actual) != expected_count or len(expected) != expected_count:
        raise RuntimeError("Probe output float count mismatch")
    maximum = 0.0
    square = 0.0
    for observed, reference in zip(actual, expected):
        if not math.isfinite(observed):
            raise RuntimeError("Probe output is nonfinite")
        difference = abs(observed - reference)
        maximum = max(maximum, difference)
        square += difference * difference
    return {"max_abs": maximum, "rmse": math.sqrt(square / expected_count)}


def input_path(directory, probe, index):
    numbered = directory / (probe["name"] + ".input%d.f32" % index)
    return numbered if numbered.exists() else directory / (probe["name"] + ".input.f32")


def fnv(data):
    value = 14695981039346656037
    for byte in data:
        value = ((value ^ byte) * 1099511628211) & 0xffffffffffffffff
    return "%016x" % value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--probes", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--phone-model-dir", required=True)
    parser.add_argument("--phone-probe-dir", required=True)
    parser.add_argument("--phone-executable", required=True)
    parser.add_argument("--compare-existing", action="store_true")
    parser.add_argument("--names", help="Comma-separated probe names; omit for all")
    args = parser.parse_args()
    probes = json.loads((args.probes / "probes.json").read_text())
    if args.names:
        selected = set(args.names.split(","))
        probes = [probe for probe in probes if probe["name"] in selected]
    adb = [args.adb, "-s", args.serial]
    args.results.mkdir(parents=True, exist_ok=True)
    if not args.compare_existing:
        run(adb + ["shell", "mkdir", "-p", args.phone_probe_dir, args.phone_probe_dir + "/dump"])
        inputs = [str(input_path(args.probes, probe, index)) for probe in probes
                  for index in range(len(probe["inputs"]))]
        run(adb + ["push", *inputs, args.phone_probe_dir], timeout=120)
    records = []
    for probe in probes:
        name = probe["name"]
        if not re.fullmatch(r"[A-Za-z0-9_]+", name) or not probe["inputs"] or len(probe["outputs"]) != 1:
            raise RuntimeError("Unsupported probe interface")
        output_spec = probe["outputs"][0]
        output_slot = "s%05d" % output_spec["slot"]
        command = [args.phone_executable, "--model-dir", args.phone_model_dir, "--stage-only", name]
        for index, input_spec in enumerate(probe["inputs"]):
            channels, height, width = input_spec["shape"][1:]
            source = input_path(args.probes, probe, index)
            remote = args.phone_probe_dir + "/" + source.name
            if not args.compare_existing:
                observed = run(adb + ["shell", args.phone_executable, "--hash-file", remote])
                hash_match = re.search(r"HASH_FILE bytes=(\d+) fnv1a64=([0-9a-f]+)", observed)
                data = source.read_bytes()
                if not hash_match or int(hash_match[1]) != len(data) or hash_match[2] != fnv(data):
                    raise RuntimeError("Phone input integrity mismatch: " + source.name)
            input_slot = "s%05d" % input_spec["slot"]
            command += ["--tensor", "%s=%d,%d,%d:%s" % (input_slot, channels, height, width, remote)]
        command += ["--dump-dir", args.phone_probe_dir + "/dump", "--threads", "2"]
        script = " ".join(shlex.quote(word) for word in command)
        script += "; phone_status=$?; echo PHONE_EXIT:$phone_status"
        if args.compare_existing:
            text = (args.results / (name + ".log")).read_text()
        else:
            text = run(adb + ["shell", script])
            (args.results / (name + ".log")).write_text(text)
        record = {"name": name, "status": "failed"}
        exit_code = re.search(r"PHONE_EXIT:(\d+)", text)
        completed = "STAGE_TEST_COMPLETE" in text and "AEIC_ERROR" not in text
        if completed and ((exit_code and exit_code[1] == "0") or args.compare_existing):
            observed = args.results / (name + ".phone.f32")
            run(adb + ["pull", args.phone_probe_dir + "/dump/" + name + "." + output_slot + ".f32", str(observed)])
            count = math.prod(output_spec["shape"])
            record.update(compare(observed, args.probes / (name + ".output.f32"), count))
            record["status"] = "complete"
        records.append(record)
        print(json.dumps(record), flush=True)
    (args.results / "summary.json").write_text(json.dumps(records, indent=2) + "\n")
    return 0 if all(record["status"] == "complete" for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
