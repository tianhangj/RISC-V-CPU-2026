#!/usr/bin/env python3
"""Run predictor, resolution, predicted-fetch and CPU integration tests."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources, verilator_command
from fakeram import with_ram_source
from toolchain import DEFAULT_APPIMAGE, enter_appimage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build/branch-tests")
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
            ("pc_increment_test", ["verilog/pc_increment.sv", "tb/pc_increment.sv"], []),
            ("branch_predictor_test", ["verilog/pc_increment.sv", "verilog/branch_predictor.sv", "tb/branch_predictor.sv"], []),
            ("branch_ctrl_test", ["verilog/branch_ctrl.sv", "tb/branch_ctrl.sv"], []),
            ("branch_alu_test", ["verilog/alu.sv", "tb/branch_alu.sv"], []),
            ("wb_arb_test", ["verilog/wb_arb.sv", "tb/wb_arb.sv"], []),
            ("fetch_prediction_test", ["verilog/signal_fanout.sv", "verilog/pc_increment.sv", "verilog/branch_predictor.sv", "verilog/fetch.sv",
                                       "tb/fetch_prediction.sv"], []),
        ]
        cpu_sources = [str(path) for path in with_ram_source(read_sources(ROOT / "verilog/filelist.f"))]
        for width in (1, 2, 4):
            tests.append(("smoke", [*cpu_sources, "tb/smoke.sv"], [f"-GWIDTH={width}"]))
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
        print(f"Branch tests failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
