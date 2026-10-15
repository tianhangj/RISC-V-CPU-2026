#!/usr/bin/env python3
"""Optional cached development flow for Docker/Linux and native Windows."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

from fast_flow import ROOT, DEFAULT_JOBS, build_simulator, synthesize


def main():
    # Windows wrappers and this entry point use the same implementation and tools.
    if os.name == "nt":
        sys.path.insert(0, str(ROOT / "toolchain"))
        import windows
        return windows.main()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("build", "test", "perf", "synth"))
    target, remaining = parser.parse_known_args(sys.argv[1:2])
    remaining.extend(sys.argv[2:])
    if target.target == "synth":
        return synthesize(remaining)
    parser = argparse.ArgumentParser(description=f"Cached {target.target}")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--out", type=Path, default=ROOT / "build/fast")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--optimization", choices=("size", "speed"), default="speed")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--parameter", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--appimage", default=str(ROOT / "cpu2026-tools-x86_64.AppImage"))
    parser.add_argument("--verilator")
    parser.add_argument("--cxx", default="g++")
    parser.add_argument("--ar", default="ar")
    parser.add_argument("--make", default="make")
    parser.add_argument("--sim", type=Path)
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--case")
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--test-jobs", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--reuse-results", action="store_true")
    parser.add_argument("--result-cache", type=Path)
    args = parser.parse_args(remaining)
    from instrumentation import parameters
    overrides = parameters(args.parameter, args.filelist)
    if args.sim is not None and overrides:
        parser.error("--parameter cannot be combined with a prebuilt --sim")
    from toolchain import enter_appimage, executable, packaged_tool
    if not args.verilator:
        enter_appimage(args.appimage)
    simulator = args.sim
    if simulator is None or target.target == "build":
        verilator = executable(args.verilator) if args.verilator else (packaged_tool("verilator") or executable("verilator"))
        tools = {"verilator": verilator, "make": executable(args.make),
                 "cxx": executable(args.cxx), "ar": executable(args.ar)}
        # Locate runtime headers in system installations as well as AppImages.
        if not os.environ.get("VERILATOR_ROOT"):
            version = subprocess.check_output([verilator, "-V"], text=True)
            import re
            root = re.search(r"(?m)^\s*VERILATOR_ROOT\s*=\s*(\S+)", version)
            if root:
                os.environ["VERILATOR_ROOT"] = root[1]
        simulator, _ = build_simulator(args.filelist, args.out, args.jobs, tools,
                                      overrides=overrides,
                                      optimization="-O3" if args.optimization == "speed" else "-Os",
                                      force=args.force)
    if target.target == "build":
        print(simulator)
        return 0
    from parallel_cases import run_cases
    return run_cases("correctness" if target.target == "test" else "perf", simulator,
                     args.testcases, args.case, args.max_cycles, args.latency,
                     args.test_jobs, args.timeout, args.results or args.out / "results",
                     (args.result_cache or args.out / "case-cache") if args.reuse_results and not args.force else None)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Development flow failed: {error}", file=sys.stderr)
        raise SystemExit(getattr(error, "returncode", 1))
