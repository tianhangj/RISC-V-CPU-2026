#!/usr/bin/env python3
"""Run CPU testcases and record resolved next-PC prediction accuracy per case/PC."""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources, verilator_command
from fakeram import with_ram_source
from oj_io import compare_output, prepare_case
from testcase import CYCLES
from toolchain import DEFAULT_APPIMAGE, enter_appimage

HEADER = "CPU2026 branch_stats version=1 scope=resolved_next_pc"
END = "CPU2026 branch_stats end=1"
ROW = re.compile(r"CPU2026 branch pc=0x([0-9a-fA-F]{8}) conditional=([01]) "
                 r"predictions=(\d+) correct=(\d+) taken=(\d+) taken_correct=(\d+)")
COUNT_FIELDS = ("predictions", "correct", "taken", "taken_correct")


def rates(counts):
    result = dict(counts)
    result["incorrect"] = counts["predictions"] - counts["correct"]
    result["not_taken"] = counts["predictions"] - counts["taken"]
    result["not_taken_correct"] = counts["correct"] - counts["taken_correct"]
    for label, numerator, denominator in (
        ("accuracy_pct", result["correct"], result["predictions"]),
        ("taken_accuracy_pct", result["taken_correct"], result["taken"]),
        ("not_taken_accuracy_pct", result["not_taken_correct"], result["not_taken"]),
    ):
        result[label] = 100.0 * numerator / denominator if denominator else None
    return result


def summarize(rows):
    buckets = {kind: dict.fromkeys(COUNT_FIELDS, 0) for kind in ("all", "conditional", "jump")}
    for row in rows:
        for kind in ("all", row["kind"]):
            for field in COUNT_FIELDS:
                buckets[kind][field] += row[field]
    return {kind: rates(counts) for kind, counts in buckets.items()}


def parse_statistics(stderr):
    lines = [line.strip() for line in stderr.splitlines() if line.startswith("CPU2026 branch")]
    if not lines or lines[0] != HEADER or lines[-1] != END:
        raise ValueError("missing/incomplete branch statistics; use an instrumented simulator")
    rows, seen = [], set()
    for line in lines[1:-1]:
        match = ROW.fullmatch(line)
        if not match:
            raise ValueError(f"invalid branch statistics: {line}")
        pc, conditional, predictions, correct, taken, taken_correct = match.groups()
        counts = dict(zip(COUNT_FIELDS, map(int, (predictions, correct, taken, taken_correct))))
        n, c, t, tc = (counts[field] for field in COUNT_FIELDS)
        if not (0 < n and 0 <= c <= n and 0 <= t <= n and 0 <= tc <= min(t, c)
                and c - tc <= n - t):
            raise ValueError(f"inconsistent branch counts: {line}")
        key = (int(pc, 16), int(conditional))
        if key in seen:
            raise ValueError(f"duplicate branch statistics: {line}")
        seen.add(key)
        rows.append({"pc": f"0x{key[0]:08x}", "kind": "conditional" if key[1] else "jump",
                     **rates(counts)})
    return sorted(rows, key=lambda row: (row["pc"], row["kind"]))


def build_instrumented(args, output):
    sources = with_ram_source(read_sources(args.filelist))
    sources += [ROOT / "tb/branch_stats_monitor.sv", ROOT / "tb/branch_stats_bind.sv"]
    binary = output / "sim"
    binary.unlink(missing_ok=True)  # Failed compilation cannot leave a stale simulator.
    parameters = {name: args.width for name in
                  ("ISSUE_WIDTH", "DISPATCH_WIDTH", "WB_WIDTH", "COMMIT_WIDTH")}
    parameters.update(BP_ENABLE=args.bp_enable, BTB_ENTRIES=args.btb_entries,
                      BHT_ENTRIES=args.bht_entries)
    command = [verilator_command(args.verilator), "--cc", "--exe", "--build", "--trace", "--assert",
               "--language", "1800-2005", "-Wall", "-Wno-fatal", "--top-module", "student_top",
               "--Mdir", str(output / "obj"), "-o", str(binary), "-j", str(args.jobs),
               "-CFLAGS", "-std=c++17", *[f"-G{name}={value}" for name, value in parameters.items()],
               *map(str, sources), str(ROOT / "scripts/sim.cpp")]
    print(f"Building statistics simulator; log: {output / 'build.log'}", flush=True)
    with (output / "build.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    return binary, {str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path):
                    hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in [*sources, ROOT / "scripts/sim.cpp"]}


def run_case(case, simulator, args, logs):
    result = {"case": case.name, "status": "failed", "cycles": None, "branches": []}
    try:
        data, answer = prepare_case(case, args.max_cycles, args.latency)
        result["program_sha256"] = hashlib.sha256((case / "program.data").read_bytes()).hexdigest()
        result["expected"] = int(answer)
        run = subprocess.run([str(simulator)], input=data, text=True, capture_output=True,
                             timeout=args.timeout)
        (logs / f"{case.name}.stdout").write_text(run.stdout)
        (logs / f"{case.name}.stderr").write_text(run.stderr)
        if run.returncode:
            raise ValueError(f"simulator exited with status {run.returncode}; see {logs / (case.name + '.stderr')}")
        error = compare_output(run.stdout, answer)
        if error:
            raise ValueError(error)
        cycles = CYCLES.search(run.stderr)
        if not cycles or int(cycles.group(1)) <= 0:
            raise ValueError("missing/invalid simulator cycle report")
        result.update(cycles=int(cycles.group(1)), branches=parse_statistics(run.stderr), status="passed")
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        result["error"] = str(error)
    result["summary"] = summarize(result["branches"])
    return result


def aggregate_cases(cases):
    # Failed/partial cases never contribute to reported accuracy.
    return summarize(row for case in cases if case["status"] == "passed" for row in case["branches"])


def write_reports(output, report):
    (output / "accuracy.json").write_text(json.dumps(report, indent=2) + "\n")
    stat_fields = list(rates(dict.fromkeys(COUNT_FIELDS, 0)))
    with (output / "accuracy.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["case", "status", "cycles", "error"] +
                                [f"{kind}_{field}" for kind in ("all", "conditional", "jump")
                                 for field in stat_fields])
        writer.writeheader()
        for case in report["cases"] + [{"case": "TOTAL", "status": "aggregate_passed_cases",
                                        "summary": report["summary"]}]:
            writer.writerow({**{key: case.get(key, "") for key in ("case", "status", "cycles", "error")},
                             **{f"{kind}_{field}": stats[field] for kind, stats in case["summary"].items()
                                for field in stat_fields}})
    with (output / "by_pc.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["case", "pc", "kind", *stat_fields])
        writer.writeheader()
        for case in report["cases"]:
            for row in case["branches"]:
                writer.writerow({"case": case["case"], **row})


def percentage(value):
    return "N/A" if value is None else f"{value:.2f}%"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/branch-accuracy")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--kind", choices=("all", "correctness", "perf"), default="all")
    parser.add_argument("--case", action="append", help="testcase directory name; repeat to select several")
    parser.add_argument("--width", type=int, choices=(1, 2, 4), default=1)
    parser.add_argument("--bp-enable", type=int, choices=(0, 1), default=1)
    parser.add_argument("--btb-entries", type=int, default=64)
    parser.add_argument("--bht-entries", type=int, default=256)
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=600, help="wall-clock seconds per testcase")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--verilator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1 or not 1 <= args.max_cycles < 2**63 or not 1 <= args.latency <= 1_000_000:
        parser.error("invalid jobs, timeout, cycle limit or latency")
    for name, value, limit in (("BTB", args.btb_entries, 2**29), ("BHT", args.bht_entries, 2**30)):
        if value < 2 or value & (value-1) or value > limit:
            parser.error(f"{name} entries must be a power of two in [2, {limit}]")
    if args.case:
        # Reject duplicate names and paths escaping the testcase root.
        if len(set(args.case)) != len(args.case) or any(Path(name).name != name or name in (".", "..") for name in args.case):
            parser.error("--case must contain unique testcase directory names")
        cases = [args.testcases / name for name in args.case]
    else:
        kinds = ("correctness", "perf") if args.kind == "all" else (args.kind,)
        cases = sorted(path for kind in kinds for path in args.testcases.glob(f"{kind}_*") if path.is_dir())
    if not cases or any(not case.is_dir() for case in cases):
        parser.error("no matching testcases, or a selected testcase does not exist")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"
    logs.mkdir(exist_ok=True)
    try:
        if not args.verilator:
            enter_appimage(args.appimage)
        simulator, hashes = build_instrumented(args, output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Statistics simulator build failed: {error}; see {output / 'build.log'}", file=sys.stderr)
        return 1
    report = {"schema_version": 1, "created_at": datetime.now(timezone.utc).isoformat(),
              "metric": "resolved_next_pc", "scope": "checkpoint_matched_surviving_resolutions",
              "configuration": {key: getattr(args, key) for key in
                                ("width", "bp_enable", "btb_entries", "bht_entries", "max_cycles", "latency")},
              "source_sha256": hashes, "cases": []}
    print(f"{'testcase':<32} {'branches':>12} {'correct':>12} {'all':>9} {'cond':>9} {'jump':>9}", flush=True)
    for case in cases:
        result = run_case(case, simulator, args, logs)
        report["cases"].append(result)
        if result["status"] == "failed":
            print(f"{case.name}: FAIL: {result['error']}", flush=True)
        else:
            stats = result["summary"]
            print(f"{case.name:<32} {stats['all']['predictions']:>12} {stats['all']['correct']:>12} "
                  + " ".join(f"{percentage(stats[kind]['accuracy_pct']):>9}" for kind in ("all", "conditional", "jump")),
                  flush=True)
        report["summary"] = aggregate_cases(report["cases"])
        report["complete"] = len(report["cases"]) == len(cases)
        report["passed"] = sum(row["status"] == "passed" for row in report["cases"])
        report["failed"] = len(report["cases"]) - report["passed"]
        write_reports(output, report)
    total = report["summary"]["all"]
    print(f"TOTAL: {total['correct']}/{total['predictions']} = {percentage(total['accuracy_pct'])}; "
          f"{report['passed']} passed, {report['failed']} failed\nReports: {output}")
    return 1 if report["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
