#!/usr/bin/env python3
"""Build a simulation-only IPC/branch profiler and compare unchanged workloads."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources, verilator_command
from fakeram import with_ram_source
from oj_io import compare_output, prepare_case
from toolchain import DEFAULT_APPIMAGE, enter_appimage
from branch_accuracy import parse_statistics, summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", action="append")
    parser.add_argument("--parameter", action="append", default=[], help="top-level NAME=integer override")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--sim", type=Path, help="reuse an instrumented simulator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    if any(not re.fullmatch(r"[A-Z][A-Z0-9_]*=\d+", value) for value in args.parameter):
        parser.error("parameters must be NAME=nonnegative_integer")
    if args.case and any(Path(name).name != name or name in (".", "..") for name in args.case):
        parser.error("case must be a testcase directory name")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = ([ROOT / "testcases" / name for name in args.case] if args.case else
             sorted((ROOT / "testcases").glob("perf_*")))
    if not cases or any(not case.is_dir() for case in cases):
        parser.error("no matching cases")
    sources = with_ram_source(read_sources(ROOT / "verilog/filelist.f")) + [
        ROOT / "tb/ipc_stats.sv", ROOT / "tb/branch_stats_monitor.sv", ROOT / "tb/branch_stats_bind.sv"]
    simulator = args.sim.resolve() if args.sim else output / "sim"
    if not args.sim:
        enter_appimage(args.appimage)
        command = [verilator_command(), "--cc", "--exe", "--build", "--trace", "--assert",
                   "--language", "1800-2005", "-Wno-fatal", "--top-module", "student_top",
                   "--Mdir", str(output / "obj"), "-o", str(simulator), "-j", str(args.jobs),
                   "-CFLAGS", "-std=c++17", *["-G"+value for value in args.parameter],
                   *map(str, sources), str(ROOT / "scripts/sim.cpp")]
        print(f"Building IPC profiler; log: {output / 'build.log'}", flush=True)
        with (output / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    report = {"configuration": {"overrides": args.parameter, "latency": args.latency,
                                "max_cycles": args.max_cycles}, "cases": [],
              "source_sha256": ({str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in sources + [ROOT / "scripts/sim.cpp"]} if not args.sim else {})}
    print(f"{'case':<20} {'cycles':>9} {'IPC':>8} {'no cand':>8} {'store head':>10} {'load head':>10} {'branch err':>10}", flush=True)
    for case in cases:
        data, answer = prepare_case(case, args.max_cycles, args.latency)
        run = subprocess.run([str(simulator)], input=data, text=True, capture_output=True, timeout=600)
        (output / (case.name+".stderr")).write_text(run.stderr)
        error = compare_output(run.stdout, answer)
        if run.returncode or error:
            raise RuntimeError(f"{case.name}: {error or run.stderr}")
        cycles = int(re.search(r"^CPU2026 cycles=(\d+)$", run.stderr, re.M).group(1))
        instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
        profile = dict((name, int(value)) for name, value in re.findall(
            r"(\w+)=(\d+)", re.search(r"^CPU2026 ipc_profile (.+)$", run.stderr, re.M).group(1)))
        branches = parse_statistics(run.stderr)
        summary = summarize(branches)
        row = {"case": case.name, "status": "passed", "instructions": instructions,
               "cycles": cycles, "ipc": instructions/cycles, "profile": profile,
               "branch_summary": summary, "branches": branches}
        report["cases"].append(row)
        print(f"{case.name:<20} {cycles:>9} {row['ipc']:>8.4f} {profile['no_candidate']:>8} "
              f"{profile['store_head']:>10} {profile['load_head']:>10} {summary['all']['incorrect']:>10}", flush=True)
        report["ipc_geomean"] = math.exp(sum(math.log(row["ipc"]) for row in report["cases"])/len(report["cases"]))
        (output / "profile.json").write_text(json.dumps(report, indent=2)+"\n")
    print(f"GEOMEAN {report['ipc_geomean']:.4f}; reports: {output}", flush=True)


if __name__ == "__main__":
    main()
