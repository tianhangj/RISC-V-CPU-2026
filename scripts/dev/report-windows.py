#!/usr/bin/env python3
"""Run correctness, performance, IPC profiling and synthesis on native Windows."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "toolchain"))
import windows

TEST_CASE = re.compile(r"^\[([^\]]+)\]$")
TEST_PASS = re.compile(r"^PASS cycles=(\d+)$")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True,
                                   encoding="utf-8", errors="replace").strip()


def filename(commit, subject):
    slug = "".join(c if c.isalnum() or c in "._-" else "-" for c in subject)
    slug = slug.strip("._-")[:40].rstrip("._-") or "commit"
    # Microseconds avoid concurrent-name collisions; the report@ prefix also
    # prevents reserved Windows device names such as CON and NUL.
    return f"report-windows@{datetime.now():%Y%m%d-%H%M%S-%f}-{commit[:6]}_{slug}.txt"


def summarize(target, log, report):
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    if target == "test":
        cases, passed, current = [], [], None
        for line in lines:
            match = TEST_CASE.fullmatch(line.strip())
            if match:
                current = match[1]
                cases.append(current)
            match = TEST_PASS.fullmatch(line.strip())
            if current and match:
                passed.append((current, match[1]))
                current = None
        if not cases or [name for name, _ in passed] != cases:
            report.write("Could not extract every passing testcase and cycle count.\n")
            return 1
        for name, cycles in passed:
            report.write(f"{name}: cycles={cycles} PASS\n")
    elif target == "perf":
        start = next((i for i, line in enumerate(lines)
                      if line.lstrip().startswith("benchmark ") and "instructions" in line), None)
        if start is None or not any(line.startswith("GEOMEAN") for line in lines[start:]):
            report.write("Benchmark table missing from successful performance output.\n")
            return 1
        report.write("\n".join(lines[start:]) + "\n")
    else:
        report.write("\n".join(lines) + "\n")
    return 0


def run_target(target, report, build_dir, args):
    runner = [sys.executable, str(ROOT / "toolchain/windows.py")]
    common = ["--filelist", str(args.filelist.resolve())]
    cached_build = args.cache_dir.resolve() / "sim"
    build_command = runner + ["build", *common, "--out", str(cached_build), "--jobs", str(args.jobs)]
    if args.force and not (target == "perf" and "test" in args.targets and
                           args.targets.index("test") < args.targets.index("perf")):
        build_command.append("--force")
    if target == "test":
        commands = [build_command,
                    runner + ["test", "--sim", str(build_dir / "sim.exe"),
                              "--max-cycles", str(args.test_max_cycles),
                              "--test-jobs", str(args.test_jobs), "--results", str(build_dir / "results"),
                              "--testcases", str(args.testcases.resolve())]]
    elif target == "perf":
        # Always validate the shared binary, including after a failed correctness build.
        commands = [build_command,
                    runner + ["perf", "--sim", str(build_dir / "sim.exe"),
                              "--max-cycles", str(args.perf_max_cycles),
                              "--test-jobs", str(args.test_jobs), "--results", str(build_dir / "results"),
                              "--testcases", str(args.testcases.resolve())]]
    elif target == "ipc-profile":
        commands = [runner + [target, *common, "--out", str(build_dir / target), "--jobs", str(args.jobs),
                              "--build-out", str(args.cache_dir.resolve() / "monitored"),
                              "--max-cycles", str(args.test_max_cycles),
                              "--testcases", str(args.testcases.resolve())]]
        if args.force:
            commands[0].append("--force")
    else:
        commands = [runner + [target, *common, "--out", str(args.cache_dir.resolve() / "synth"),
                              "--clock-period", str(args.clock_period)]]
        if args.force:
            commands[0].append("--force")
    if target in ("test", "perf") and args.reuse_results and not args.force:
        commands[-1].extend(["--reuse-results", "--result-cache", str(args.cache_dir.resolve() / "cases")])
    report.write(f"\n===== {target} (Windows) =====\n")
    log_path = build_dir / (target + ".log")
    report.write(f"Full log: {log_path}\n")
    report.flush()
    print(f"Running {target} on Windows...", file=sys.stderr, flush=True)
    status = 0
    start = time.perf_counter()
    with log_path.open("w", encoding="utf-8") as log:
        for command in commands:
            report.write("Command: " + subprocess.list2cmdline(command) + "\n")
            report.flush()
            try:
                status = subprocess.run(command, cwd=ROOT, stdout=log,
                                        stderr=subprocess.STDOUT, check=False).returncode
            except OSError as error:
                log.write(f"Invocation failed: {error}\n")
                status = 127
            if status:
                break
            if command == build_command:
                for name in ("sim.exe", "sim.json", "build.log"):
                    shutil.copy2(cached_build / name, build_dir / name)
    if status == 0:
        status = summarize(target, log_path, report)
        if target in ("test", "perf"):
            result = json.loads((build_dir / "results" / ("correctness.json" if target == "test" else "perf.json")).read_text())
            report.write(f"Reused testcase results: {result['reused']}/{len(result['cases'])}\n")
    # Snapshot the concrete products in each report; caches can change on the next run.
    if status == 0 and target == "ipc-profile":
        for name in ("sim.exe", "sim.json", "build.log"):
            shutil.copy2(args.cache_dir.resolve() / "monitored" / name, build_dir / target / name)
    elif status == 0 and target == "synth":
        shutil.copytree(args.cache_dir.resolve() / "synth", build_dir / "synth",
                        ignore=shutil.ignore_patterns(".flow*"))
    if status:
        with log_path.open(encoding="utf-8", errors="replace") as log:
            shutil.copyfileobj(log, report)
        nested = (args.cache_dir.resolve() / "monitored" / "build.log" if target == "ipc-profile"
                  else cached_build / "build.log")
        if target in ("test", "perf", "ipc-profile") and nested.is_file():
            report.write(f"\nBuild log: {nested}\n")
            with nested.open(encoding="utf-8", errors="replace") as log:
                shutil.copyfileobj(log, report)
    report.write(f"\nExit status: {status}\n")
    elapsed = time.perf_counter() - start
    report.write(f"Elapsed seconds: {elapsed:.3f}\n")
    print(f"{target}: exit={status}, {elapsed:.2f}s", file=sys.stderr, flush=True)
    report.flush()
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/reports")
    from fast_flow import DEFAULT_JOBS
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--test-jobs", type=int, default=4)
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "build/windows-report-cache")
    parser.add_argument("--force", action="store_true", help="clean rebuild and rerun synthesis")
    parser.add_argument("--reuse-results", action="store_true", help="reuse verified identical correctness/perf results")
    parser.add_argument("--targets", nargs="+", choices=("test", "perf", "ipc-profile", "synth"),
                        default=("test", "perf", "ipc-profile", "synth"))
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--test-max-cycles", type=int, default=100_000_000)
    parser.add_argument("--perf-max-cycles", type=int, default=10_000_000)
    parser.add_argument("--clock-period", type=float, default=1000.0 / 500.0,
                        help="target clock period in ns (default: 1000/500, 500 MHz)")
    args = parser.parse_args()
    if args.jobs < 1 or args.test_jobs < 1 or len(set(args.targets)) != len(args.targets) or any(not 1 <= v < 2**63 for v in (args.test_max_cycles, args.perf_max_cycles)):
        parser.error("jobs and cycle limits must be positive; cycle limits must be below 2^63")
    if not math.isfinite(args.clock_period) or args.clock_period <= 0:
        parser.error("clock period must be finite and positive")
    try:
        windows.activate()
        versions = windows.versions()
        commit, subject = git("rev-parse", "HEAD"), git("log", "-1", "--format=%s")
        dirty = git("status", "--short", "--ignore-submodules=all")
        from build import read_sources
        from fakeram import RAM_SOURCE
        inputs = set(read_sources(args.filelist)) | set((ROOT / "tb/monitor").glob("*.sv"))
        inputs.update([RAM_SOURCE, ROOT / "scripts/sim.cpp", args.filelist.resolve()])
        inputs.update((ROOT / "scripts").rglob("*.py"))
        inputs.update([ROOT / "scripts/timing.tcl", ROOT / "toolchain/windows.py"])
        if (ROOT / "abc.constr").is_file():
            inputs.add(ROOT / "abc.constr")
        hashes = {p.relative_to(ROOT).as_posix() if p.is_relative_to(ROOT) else p.as_posix():
                  hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(inputs)}
        output = args.output_dir.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
        path = output / filename(commit, subject)
        build_dir = output / (path.stem + ".build")
        build_dir.mkdir()
        with path.open("x", encoding="utf-8") as report:
            report.write(f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}\n")
            report.write(f"Commit: {commit}\nSubject: {subject}\nPlatform: native Windows\n")
            report.write(f"Build directory: {build_dir}\n")
            report.write(f"Shared cache directory: {args.cache_dir.resolve()}\n")
            report.write("Working tree: " + ("\n" + dirty if dirty else "clean") + "\n")
            report.write("Tools: " + json.dumps(versions, ensure_ascii=False, sort_keys=True) + "\n")
            report.write("Source SHA-256: " + json.dumps(hashes, sort_keys=True) + "\n")
            libraries = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted((ROOT / "toolchain/asap7/lib").glob("*.lib"))}
            report.write("Library SHA-256: " + json.dumps(libraries, sort_keys=True) + "\n")
            statuses = {t: run_target(t, report, build_dir, args)
                        for t in args.targets}
            report.write("\n===== Summary =====\n")
            for target, status in statuses.items():
                report.write(f"{target}: {'PASS' if status == 0 else f'FAIL (exit {status})'}\n")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    print(path)
    return 0 if all(status == 0 for status in statuses.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
