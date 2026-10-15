#!/usr/bin/env python3
"""Run existing CPU workloads with IPC, stall and branch monitors."""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from oj_io import compare_output, prepare_case
from testcase import CYCLES
from toolchain import DEFAULT_APPIMAGE
from branch_accuracy import parse_statistics, summarize
from instrumentation import build, parameters


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/ipc-profile")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--kind", choices=("perf", "correctness", "all"), default="perf")
    parser.add_argument("--case", action="append")
    parser.add_argument("--parameter", action="append", default=[], help="public top NAME=integer override")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--sim", type=Path, help="reuse a monitored simulator; configuration comes from sim.json")
    parser.add_argument("--verilator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1 or not 1 <= args.max_cycles < 2**63 or not 1 <= args.latency <= 1_000_000:
        parser.error("invalid jobs, timeout, cycle limit or latency")
    if args.sim and args.parameter:
        parser.error("--parameter cannot change a prebuilt --sim")
    if args.case and (len(set(args.case)) != len(args.case) or any(
            Path(n).name != n or n in (".", "..") for n in args.case)):
        parser.error("case must contain unique testcase directory names")
    kinds = ("correctness", "perf") if args.kind == "all" else (args.kind,)
    cases = ([args.testcases / n for n in args.case] if args.case else
             sorted(p for k in kinds for p in args.testcases.glob(k + "_*") if p.is_dir()))
    if not cases or any(not p.is_dir() for p in cases):
        parser.error("no matching testcases")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    try:
        if args.sim:
            simulator = args.sim.resolve()
            identity = json.loads(simulator.with_name("sim.json").read_text())
            overrides, hashes = identity["overrides"], identity["source_sha256"]
        else:
            overrides = parameters(args.parameter, args.filelist)
            simulator, hashes = build(args.filelist, output, overrides, args.jobs, args.appimage, args.verilator)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.error(f"cannot prepare monitored simulator: {error}; see {output / 'build.log'}")
    report = {"configuration": {"overrides": [f"{k}={v}" for k, v in overrides.items()],
                                "latency": args.latency, "max_cycles": args.max_cycles},
              "source_sha256": hashes, "cases": []}
    print(f"{'case':<32} {'cycles':>9} {'IPC':>8} {'no cand':>8} {'store head':>10} {'load head':>10} {'branch err':>10}", flush=True)
    for case in cases:
        try:
            data, answer = prepare_case(case, args.max_cycles, args.latency)
            run = subprocess.run([str(simulator)], input=data, text=True, capture_output=True, timeout=args.timeout)
            (output / (case.name + ".stdout")).write_text(run.stdout)
            (output / (case.name + ".stderr")).write_text(run.stderr)
            error = compare_output(run.stdout, answer)
            if run.returncode or error:
                raise ValueError(error or f"simulator exited {run.returncode}; see {case.name}.stderr")
            cycle_match = CYCLES.search(run.stderr)
            counters = re.search(r"^CPU2026 ipc_profile (.+)$", run.stderr, re.M)
            if not cycle_match or not counters or int(cycle_match[1]) <= 0:
                raise ValueError("missing/invalid cycles or IPC counters")
            cycles = int(cycle_match[1])
            instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
            profile = {n: int(v) for n, v in re.findall(r"(\w+)=(\d+)", counters[1])}
            multi = re.search(r"^CPU2026 multi_width (.+)$", run.stderr, re.M)
            if multi:
                profile.update({n: int(v) for n, v in re.findall(r"(\w+)=(\d+)", multi[1])})
            branches = parse_statistics(run.stderr)
            summary = summarize(branches)
            row = {"case": case.name, "status": "passed", "instructions": instructions,
                   "cycles": cycles, "ipc": instructions / cycles, "profile": profile,
                   "branch_summary": summary, "branches": branches}
            print(f"{case.name:<32} {cycles:>9} {row['ipc']:>8.4f} {profile['no_candidate']:>8} "
                  f"{profile['store_head']:>10} {profile['load_head']:>10} {summary['all']['incorrect']:>10}", flush=True)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            row = {"case": case.name, "status": "failed", "error": str(error)}
            print(f"{case.name}: FAIL: {error}", file=sys.stderr, flush=True)
        report["cases"].append(row)
        scores = [r["ipc"] for r in report["cases"] if r["status"] == "passed"]
        report["ipc_geomean"] = math.exp(sum(map(math.log, scores)) / len(scores)) if scores else None
        report["complete"] = len(report["cases"]) == len(cases)
        report["passed"] = len(scores)
        report["failed"] = len(report["cases"]) - len(scores)
        (output / "profile.json").write_text(json.dumps(report, indent=2) + "\n")
    if report["ipc_geomean"] is not None:
        print(f"GEOMEAN {report['ipc_geomean']:.4f}; reports: {output}")
    return 1 if report["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
