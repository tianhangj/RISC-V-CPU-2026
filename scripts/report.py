#!/usr/bin/env python3
"""Run perf and synth in Docker and save their results in one report."""

import argparse
from datetime import datetime
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def filename():
    now = datetime.now()
    commit = git("rev-parse", "HEAD")
    subject = git("log", "-1", "--format=%s")
    slug = "".join(char if char.isalnum() or char in "._-" else "-" for char in subject)
    slug = slug.strip("._-")[:80].rstrip("._-") or "commit"
    return f"report@{int(now.timestamp())}({commit[:6]})_{slug}.txt", commit, subject


def run_target(image, target, report):
    make_args = [target, "MAX_CYCLES=10000000"] if target == "perf" else [target]
    command = [
        "docker", "run", "--rm", "--network", "none",
        "--user", f"{os.getuid()}:{os.getgid()}",
        "--mount", f"type=bind,source={ROOT},target=/work",
        "--workdir", "/work", image,
        "make", *make_args, "APPIMAGE=",
    ]
    report.write(f"\n===== make {' '.join(make_args)} =====\n")
    report.write("Docker command: " + shlex.join(command) + "\n\n")
    report.flush()
    print(f"Running make {target} in Docker...", file=sys.stderr, flush=True)
    try:
        if target == "perf":
            with tempfile.TemporaryFile(mode="w+t", encoding="utf-8", errors="replace") as log:
                status = subprocess.run(command, cwd=ROOT, stdout=log,
                                        stderr=subprocess.STDOUT, check=False).returncode
                log.seek(0)
                if status == 0:
                    for line in log:
                        if line.lstrip().startswith("benchmark ") and "instructions" in line:
                            report.write(line)
                            shutil.copyfileobj(log, report)
                            break
                    else:
                        report.write("Benchmark table missing from successful make perf output.\n")
                        status = 1
                else:
                    shutil.copyfileobj(log, report)
        else:
            status = subprocess.run(command, cwd=ROOT, stdout=report,
                                    stderr=subprocess.STDOUT, check=False).returncode
    except OSError as error:
        report.write(f"Docker invocation failed: {error}\n")
        status = 127
    report.write(f"\nExit status: {status}\n")
    report.flush()
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="cpu2026:latest", help="local Docker image")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "report",
                        help="report directory (default: report/)")
    args = parser.parse_args()

    try:
        name, commit, subject = filename()
        dirty = git("status", "--short")
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"cannot read Git metadata: {error}")

    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / name
    try:
        with path.open("x", encoding="utf-8") as report:
            report.write(f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}\n")
            report.write(f"Commit: {commit}\nSubject: {subject}\n")
            report.write(f"Docker image: {args.image}\n")
            report.write("Working tree: " + ("\n" + dirty if dirty else "clean") + "\n")
            statuses = {target: run_target(args.image, target, report)
                        for target in ("perf", "synth")}
            report.write("\n===== Summary =====\n")
            for target, status in statuses.items():
                report.write(f"make {target}: {'PASS' if status == 0 else f'FAIL (exit {status})'}\n")
    except FileExistsError:
        parser.error(f"report already exists: {path}; rerun after the next second")
    except OSError as error:
        parser.error(f"cannot write report: {error}")
    print(path)
    return 0 if all(status == 0 for status in statuses.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
