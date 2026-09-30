#!/usr/bin/env python3
"""Validate statistics parsing, multi-lane accounting and recovery filtering."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from branch_accuracy import (COUNT_FIELDS, END, HEADER, ROOT, aggregate_cases,
                             build_instrumented, parse_statistics, run_case, summarize, write_reports)
from build import verilator_command
from toolchain import DEFAULT_APPIMAGE, enter_appimage


def sample(pc=16, conditional=1, n=3, c=1, t=2, tc=1):
    return (f"CPU2026 branch pc=0x{pc:08x} conditional={conditional} "
            f"predictions={n} correct={c} taken={t} taken_correct={tc}")


class StatisticsTests(unittest.TestCase):
    def test_empty_and_rates(self):
        rows = parse_statistics(f"{HEADER}\n{END}\nCPU2026 cycles=25\n")
        self.assertEqual(rows, [])
        self.assertIsNone(summarize(rows)["all"]["accuracy_pct"])
        row = parse_statistics(f"{HEADER}\n{sample()}\n{END}")[0]
        self.assertAlmostEqual(row["accuracy_pct"], 100/3)
        self.assertEqual(row["taken_accuracy_pct"], 50)
        self.assertEqual(row["not_taken_accuracy_pct"], 0)

    def test_reject_bad_counts_and_incomplete_output(self):
        for text in ("", HEADER, END, f"{HEADER}\n{sample(n=0)}\n{END}",
                     f"{HEADER}\n{sample(c=4)}\n{END}", f"{HEADER}\n{sample(tc=3)}\n{END}",
                     f"{HEADER}\n{sample(c=3, tc=1)}\n{END}",
                     f"{HEADER}\n{sample()}\n{sample()}\n{END}",
                     f"{HEADER}\n{HEADER}\n{END}"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_statistics(text)

    def test_weighted_aggregate_and_failed_case(self):
        few = parse_statistics(f"{HEADER}\n{sample(n=1,c=1,t=1,tc=1)}\n{END}")
        many = parse_statistics(f"{HEADER}\n{sample(n=9,c=0,t=0,tc=0)}\n{END}")
        result = aggregate_cases([{"status": "passed", "branches": few},
                                  {"status": "passed", "branches": many},
                                  {"status": "failed", "branches": few}])
        self.assertEqual(result["all"]["accuracy_pct"], 10)
        self.assertIsNone(result["jump"]["accuracy_pct"])

    def test_reports(self):
        branches = parse_statistics(f"{HEADER}\n{sample()}\n{END}")
        case = {"case": "fixture", "status": "passed", "cycles": 5,
                "branches": branches, "summary": summarize(branches)}
        report = {"cases": [case], "summary": aggregate_cases([case])}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            write_reports(output, report)
            self.assertEqual(json.loads((output / "accuracy.json").read_text()), report)
            with (output / "accuracy.csv").open() as file:
                rows = list(csv.DictReader(file))
            self.assertEqual(rows[0]["all_predictions"], "3")
            self.assertEqual(rows[-1]["case"], "TOTAL")
            with (output / "by_pc.csv").open() as file:
                self.assertEqual(list(csv.DictReader(file))[0]["pc"], "0x00000010")

    def test_failed_execution_never_reports_accuracy(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Path(directory)
            (case / "program.data").write_text("@00000000\n13 00 00 00\n")
            (case / "expected.txt").write_text("42\n")
            args = SimpleNamespace(max_cycles=1000, latency=10, timeout=5)
            statistics = f"{HEADER}\n{sample()}\n{END}\nCPU2026 cycles=10\n"
            for returned in (subprocess.CompletedProcess([], 1, "42\n", statistics),
                             subprocess.CompletedProcess([], 0, "99\n", statistics),
                             subprocess.CompletedProcess([], 0, "42\n", "CPU2026 cycles=10\n")):
                with patch("branch_accuracy.subprocess.run", return_value=returned):
                    result = run_case(case, case / "sim", args, case)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["branches"], [])
                self.assertIsNone(result["summary"]["all"]["accuracy_pct"])


def run_sv(top, sources, output, args):
    directory = output / top
    command = [verilator_command(args.verilator), "--binary", "--timing", "--assert",
               "--language", "1800-2005", "-Wno-fatal", "-j", str(args.jobs),
               "--top-module", top, "--Mdir", str(directory), *sources]
    with (output / (top + ".build.log")).open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    run = subprocess.run([str(directory / ("V" + top))], capture_output=True, text=True,
                         check=True, timeout=60)
    (output / (top + ".stderr")).write_text(run.stderr)
    return parse_statistics(run.stderr)


def test_cpu_fixture(output, args):
    # Eight dependent loop branches: seven taken then one not taken.
    # Includes a JAL to PC+4 and cold JAL/JALR with nonsequential targets.
    def branch(imm, rs1, rs2, funct3):
        imm &= 0x1fff
        return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 63) << 25 | rs2 << 20 |
                rs1 << 15 | funct3 << 12 | ((imm >> 1) & 15) << 8 |
                ((imm >> 11) & 1) << 7 | 0x63)

    words = [0x00800093, 0xfff08093, branch(-4, 1, 0, 1),
             0x0040006f, 0x0080006f, 0x00000013,
             0x02400113, 0x00010067, 0x06300513,
             0x800001b7, 0x02a00513, 0x00a1a023, 0x0000006f]
    case = output / "counted_loop"
    case.mkdir(exist_ok=True)
    (case / "program.data").write_text("@00000000\n" + "\n".join(
        " ".join(f"{byte:02x}" for byte in word.to_bytes(4, "little")) for word in words) + "\n")
    (case / "expected.txt").write_text("42\n")
    config = SimpleNamespace(filelist=ROOT / "verilog/filelist.f", width=1, bp_enable=1,
                             btb_entries=64, bht_entries=256, verilator=args.verilator,
                             jobs=args.jobs, max_cycles=10000, latency=10, timeout=60)
    for enabled, loop_correct in ((1, 6), (0, 1)):
        config.bp_enable = enabled
        directory = output / f"cpu_bp{enabled}"
        directory.mkdir(exist_ok=True)
        simulator, _ = build_instrumented(config, directory)
        result = run_case(case, simulator, config, directory)
        (directory / "fixture.json").write_text(json.dumps(result, indent=2) + "\n")
        if result["status"] != "passed":
            raise ValueError(f"CPU statistics fixture failed: {result.get('error')}")
        by_pc = {row["pc"]: row for row in result["branches"]}
        for pc, n, correct, taken in ((8, 8, loop_correct, 7), (12, 1, 1, 1),
                                     (16, 1, 0, 1), (28, 1, 0, 1)):
            row = by_pc.get(f"0x{pc:08x}", {})
            actual = tuple(row.get(field) for field in ("predictions", "correct", "taken"))
            if actual != (n, correct, taken):
                raise ValueError(f"CPU BP={enabled} PC={pc:#x}: expected {(n, correct, taken)}, got {actual}")
    print("PASS CPU counted-loop oracle: 8 loop branches, BP on 6/8 correct, BP off 1/8 correct, JAL/JALR targets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/branch-accuracy-tests")
    parser.add_argument("--verilator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if not args.verilator:
        enter_appimage(args.appimage)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(StatisticsTests)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        return 1
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    rows = run_sv("branch_stats_test", ["tb/branch_stats_monitor.sv", "tb/branch_stats.sv"], output, args)
    expected = [("0x00000010", "conditional", 3, 1, 2, 1),
                ("0x00000020", "jump", 2, 1, 2, 1),
                ("0x00000030", "conditional", 1, 1, 0, 0)]
    actual = [(row["pc"], row["kind"], *(row[field] for field in COUNT_FIELDS)) for row in rows]
    if actual != expected:
        raise ValueError(f"multi-lane/reset accounting mismatch: {actual}")
    rows = run_sv("branch_ctrl_test", ["verilog/branch_ctrl.sv", "tb/branch_ctrl.sv",
                                      "tb/branch_stats_monitor.sv", "tb/branch_stats_bind.sv"], output, args)
    expected = [("0x00000000", 2, 2), ("0x00000010", 2, 2),
                ("0x00000020", 2, 1), ("0x00000030", 1, 1)]
    actual = [(row["pc"], row["predictions"], row["correct"]) for row in rows]
    if actual != expected:
        raise ValueError(f"stale/squashed resolution accounting mismatch: {actual}")
    print("PASS statistics: reset, multi-lane same-PC, taken-to-fallthrough, changed jump target, "
          "checkpoint reuse, stale resolution, squash and ROB wraparound")
    test_cpu_fixture(output, args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
