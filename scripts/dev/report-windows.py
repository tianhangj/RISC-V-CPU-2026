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
    if target == "test":
        commands = [runner + ["build", *common, "--out", str(build_dir), "--jobs", str(args.jobs)],
                    runner + ["test", "--sim", str(build_dir / "sim.exe"),
                              "--max-cycles", str(args.test_max_cycles),
                              "--testcases", str(args.testcases.resolve())]]
    elif target == "perf":
        # If correctness compilation failed, rebuild instead of reusing stale artifacts.
        commands = [runner + ["perf", *common, "--out", str(build_dir), "--jobs", str(args.jobs),
                              "--max-cycles", str(args.perf_max_cycles),
                              "--testcases", str(args.testcases.resolve())]]
        if (build_dir / "sim.exe").is_file():
            commands[0].extend(["--sim", str(build_dir / "sim.exe")])
    elif target == "ipc-profile":
        commands = [runner + [target, *common, "--out", str(build_dir / target), "--jobs", str(args.jobs),
                              "--max-cycles", str(args.test_max_cycles),
                              "--testcases", str(args.testcases.resolve())]]
    else:
        commands = [runner + [target, *common, "--out", str(build_dir / "synth"),
                              "--clock-period", str(args.clock_period)]]
    report.write(f"\n===== {target} (Windows) =====\n")
    log_path = build_dir / (target + ".log")
    report.write(f"Full log: {log_path}\n")
    report.flush()
    print(f"Running {target} on Windows...", file=sys.stderr, flush=True)
    status = 0
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
    if status == 0:
        status = summarize(target, log_path, report)
    if status:
        with log_path.open(encoding="utf-8", errors="replace") as log:
            shutil.copyfileobj(log, report)
        nested = build_dir / ("ipc-profile/build.log" if target == "ipc-profile" else "build.log")
        if target in ("test", "perf", "ipc-profile") and nested.is_file():
            report.write(f"\nBuild log: {nested}\n")
            with nested.open(encoding="utf-8", errors="replace") as log:
                shutil.copyfileobj(log, report)
    report.write(f"\nExit status: {status}\n")
    report.flush()
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/reports")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--test-max-cycles", type=int, default=100_000_000)
    parser.add_argument("--perf-max-cycles", type=int, default=10_000_000)
    parser.add_argument("--clock-period", type=float, default=1000.0 / 500.0,
                        help="target clock period in ns (default: 1000/500, 500 MHz)")
    args = parser.parse_args()
    if args.jobs < 1 or any(not 1 <= v < 2**63 for v in (args.test_max_cycles, args.perf_max_cycles)):
        parser.error("jobs and cycle limits must be positive; cycle limits must be below 2^63")
    if not math.isfinite(args.clock_period) or args.clock_period <= 0:
        parser.error("clock period must be finite and positive")
    try:
        windows.activate()
        versions = windows.versions()
        commit, subject = git("rev-parse", "HEAD"), git("log", "-1", "--format=%s")
        dirty = git("status", "--short")
        from build import read_sources
        from fakeram import RAM_SOURCE
        inputs = set(read_sources(args.filelist)) | set((ROOT / "tb/monitor").glob("*.sv"))
        inputs.update([RAM_SOURCE, ROOT / "scripts/sim.cpp", args.filelist.resolve()])
        inputs.update((ROOT / "scripts").rglob("*.py"))
        inputs.update([ROOT / "scripts/timing.tcl", ROOT / "toolchain/windows.py"])
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
            report.write("Working tree: " + ("\n" + dirty if dirty else "clean") + "\n")
            report.write("Tools: " + json.dumps(versions, ensure_ascii=False, sort_keys=True) + "\n")
            report.write("Source SHA-256: " + json.dumps(hashes, sort_keys=True) + "\n")
            libraries = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted((ROOT / "toolchain/asap7/lib").glob("*.lib"))}
            report.write("Library SHA-256: " + json.dumps(libraries, sort_keys=True) + "\n")
            statuses = {t: run_target(t, report, build_dir, args)
                        for t in ("test", "perf", "ipc-profile", "synth")}
            report.write("\n===== Summary =====\n")
            for target, status in statuses.items():
                report.write(f"{target}: {'PASS' if status == 0 else f'FAIL (exit {status})'}\n")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    print(path)
    return 0 if all(status == 0 for status in statuses.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
