#!/usr/bin/env python3
"""Run timing-sensitive IQ, scheduler, PRF and arithmetic regressions."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import verilator_command
from toolchain import DEFAULT_APPIMAGE, enter_appimage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build/timing-tests")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--verilator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    try:
        if not args.verilator:
            enter_appimage(args.appimage)
        verilator = verilator_command(args.verilator)
        tests = [
            ("wb_pipeline_test", ["verilog/wb_arb.sv", "tb/wb_pipeline.sv"], []),
            ("rename_checkpoint_test", ["verilog/rename.sv", "tb/rename_checkpoint.sv"], []),
            ("rename_stream_test", ["verilog/rename.sv", "tb/rename_stream.sv"], []),
            ("iq_alu_candidate_test", ["verilog/iq_alu.sv", "tb/iq_alu_candidate.sv"], []),
            ("iq_mem_candidate_test", ["verilog/iq_alu.sv", "verilog/iq_mem.sv", "tb/iq_mem_candidate.sv"], []),
            ("selection_tree_test", ["verilog/iq_alu.sv", "verilog/issue_sched.sv", "tb/selection_tree.sv"], []),
            ("prf_hierarchical_test", ["verilog/prf.sv", "tb/prf_hierarchical.sv"], []),
            ("mul_div_test", ["verilog/mul_div.sv", "tb/mul_div.sv"], []),
        ]
        output = args.build.resolve()
        output.mkdir(parents=True, exist_ok=True)
        for top, sources, parameters in tests:
            name = top + ("_" + parameters[0].split("=")[1] if parameters else "")
            directory = output / name
            log_path = output / (name + ".log")
            command = [verilator, "--binary", "--timing", "--assert",
                       "--language", "1800-2005", "-Wno-fatal", "-j", str(args.jobs),
                       "--top-module", top, "--Mdir", str(directory), *parameters, *sources]
            print(f"Building {name}; compiler log: {log_path}", flush=True)
            with log_path.open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([str(directory / ("V" + top))], cwd=ROOT, check=True, timeout=60)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Timing regression failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
