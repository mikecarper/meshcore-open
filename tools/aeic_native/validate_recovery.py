"""Host-only native frontend regression; does not run phone inference."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--references", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    model = args.fixtures / "model256"
    common = [str(args.binary), "--model-dir", str(model), "--threads", "1"]
    prefix = ["--stop-after", "y_hat", "--verify-integers-only"]
    records = []

    def run(name, extra, success, required):
        result = subprocess.run(common + extra, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=60)
        (args.output_dir / (name + ".log")).write_text(result.stdout)
        if (result.returncode == 0) != success:
            raise RuntimeError(f"{name}: unexpected exit {result.returncode}")
        for text in required:
            if text not in result.stdout:
                raise RuntimeError(f"{name}: missing diagnostic {text!r}")
        records.append({"name": name, "exit": result.returncode,
                        "degraded_events": result.stdout.count("DEGRADED category=")})

    valid = ["--bitstream", str(args.references / "sample.aeic")]
    truncated = ["--bitstream", str(args.fixtures / "real256-truncated.aeic")]
    corrupt = ["--bitstream", str(args.fixtures / "real256-corrupt.aeic")]
    clean_refs = ["--verify-dir", str(args.references)]
    wrong_refs = ["--verify-dir", str(args.fixtures / "wrongrefs")]
    run("strict-truncated", truncated + prefix, False, ["AEIC payload length mismatch"])
    run("strict-wrong-reference", valid + prefix + wrong_refs, False,
        ["VERIFY_INDEXES y0_indices mismatches=1", "AEIC_ERROR"])
    run("best-truncated", truncated + prefix + clean_refs + ["--best-effort"], True,
        ["DEGRADED category=bitstream", "DEGRADED category=entropy",
         "ENTROPY_DEGRADED terminal_verified=false", "RESULT_STATUS degraded=true"])
    run("best-corrupt", corrupt + prefix + clean_refs + ["--best-effort"], True,
        ["DEGRADED category=entropy", "ENTROPY_DEGRADED terminal_verified=false",
         "RESULT_STATUS degraded=true"])
    run("best-wrong-reference", valid + prefix + wrong_refs + ["--best-effort"], True,
        ["VERIFY_INDEXES y0_indices mismatches=1", "DEGRADED category=reference",
         "ENTROPY_COMPLETE", "RESULT_STATUS degraded=true recovery_events=1"])
    injected = ["--stage-only", "0000_unet_conv_in", "--tensor",
                "l_T=320,32,32:" + str(args.references / "l_T.f32")]
    run("strict-missing-model", injected, False, ["AEIC_ERROR cannot open"])
    run("best-missing-model", injected + ["--best-effort"], True,
        ["DEGRADED category=model", "fallback=preserve", "STAGE_TEST_COMPLETE",
         "RESULT_STATUS degraded=true recovery_events=1"])
    timeout_input = ["--stage-only", "ctx0", "--tensor",
                     "base=256,8,8:" + str(args.references / "h_s.base.f32")]
    run("best-timeout", timeout_input + ["--best-effort", "--stage-timeout-ms", "1"], True,
        ["status=timeout", "fallback=zeros", "RESULT_STATUS degraded=true"])
    # The same CPU runtime and inputs must be bit-identical with isolation enabled.
    for mode in ("strict", "best"):
        dump = args.output_dir / (mode + "-dump")
        dump.mkdir(exist_ok=True)
        extra = valid + prefix + clean_refs + ["--dump-dir", str(dump)]
        if mode == "best":
            extra += ["--best-effort"]
        run("intact-" + mode, extra, True,
            ["ENTROPY_COMPLETE", "RESULT_STATUS degraded=false recovery_events=0"])
    strict = (args.output_dir / "strict-dump/y_hat.f32").read_bytes()
    best = (args.output_dir / "best-dump/y_hat.f32").read_bytes()
    if strict != best:
        raise RuntimeError("Intact best-effort changed the normal latent tensor")
    report = {"host_only": True, "full_phone_decode": False,
              "intact_latent_identical": True, "cases": records}
    (args.output_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
