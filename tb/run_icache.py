#!/usr/bin/env python3
"""Run cache and frontend protocol/throughput tests with the course toolchain."""

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
    parser.add_argument("--build", type=Path, default=ROOT / "build/icache-tests")
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
            ("fetch_generation", ["verilog/fetch.sv", "tb/fetch_generation.sv"]),
            ("icache_test", ["verilog/icache.sv", "verilog/axi_bridge.sv",
                             "scripts/ram/sram_fakeram.sv", "tb/icache.sv"]),
            ("fetch_icache_test", ["verilog/fetch.sv", "verilog/icache.sv",
                                   "scripts/ram/sram_fakeram.sv", "tb/fetch_icache.sv"]),
        ]
        output = args.build.resolve()
        output.mkdir(parents=True, exist_ok=True)
        for top, sources in tests:
            directory = output / top
            log_path = output / (top + ".log")
            command = [verilator, "--binary", "--timing", "--assert",
                       "--language", "1800-2005", "-Wno-fatal", "-j", str(args.jobs),
                       "--top-module", top, "--Mdir", str(directory), *sources]
            print(f"Building {top}; compiler log: {log_path}", flush=True)
            with log_path.open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([str(directory / ("V" + top))], cwd=ROOT, check=True, timeout=60)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Cache tests failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
