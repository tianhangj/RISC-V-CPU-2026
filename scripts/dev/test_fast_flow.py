"""Regression checks for stale-cache rejection and complete benchmark scoring."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fast_flow
from flow_cache import identities, rtl_dependencies, save_record, valid_record
from parallel_cases import run_cases


class CacheSafety(unittest.TestCase):
    def setUp(self):
        workspace = fast_flow.ROOT / "build/fast-flow-tests"
        workspace.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=workspace)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_same_mtime_source_change_and_missing_artifact(self):
        source, binary, record = [self.root / name for name in ("source.sv", "sim", "cache.json")]
        source.write_text("module a; endmodule")
        binary.write_bytes(b"binary")
        identity = {"source": identities([source]), "period": 2.0}
        save_record(record, identity, [binary])
        self.assertTrue(valid_record(record, identity))
        import os
        stamp = source.stat().st_mtime_ns
        source.write_text("module b; endmodule")
        os.utime(source, ns=(stamp, stamp))
        self.assertFalse(valid_record(record, {**identity, "source": identities([source])}))
        self.assertFalse(valid_record(record, {**identity, "period": 3.0}))
        binary.unlink()
        self.assertFalse(valid_record(record, identity))

    def test_includes_are_dependencies_and_macro_includes_rejected(self):
        source, include = self.root / "top.sv", self.root / "values.svh"
        include.write_text("localparam X = 1;")
        source.write_text('`include "values.svh"\nmodule top; endmodule')
        self.assertEqual(set(rtl_dependencies([source])), {source, include})
        source.write_text('`include HEADER\nmodule top; endmodule')
        with self.assertRaises(ValueError):
            rtl_dependencies([source])

    def test_build_reuse_source_change_and_failed_rebuild(self):
        source, filelist = self.root / "top.sv", self.root / "filelist.f"
        source.write_text("module student_top; endmodule")
        filelist.write_text("top.sv\n")
        tools = {}
        for name in ("verilator", "make", "cxx", "ar"):
            path = self.root / name
            path.write_bytes(name.encode())
            tools[name] = str(path)
        output = self.root / "build"
        invocations = []

        def run(command, **kwargs):
            invocations.append(command)
            if Path(command[0]) == Path(tools["make"]):
                (output / ("sim.exe" if fast_flow.os.name == "nt" else "sim")).write_bytes(b"new binary")
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(fast_flow.os.environ, {"VERILATOR_ROOT": str(self.root / "runtime")}):
            with patch.object(fast_flow.subprocess, "run", side_effect=run), redirect_stdout(io.StringIO()):
                first, _ = fast_flow.build_simulator(filelist, output, 1, tools)
                fast_flow.build_simulator(filelist, output, 2, tools)
                self.assertEqual(len(invocations), 2)
                source.write_text("module student_top; wire a; endmodule")
                fast_flow.build_simulator(filelist, output, 1, tools)
                self.assertEqual(len(invocations), 4)
            source.write_text("invalid RTL")
            with patch.object(fast_flow.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "verilator")), redirect_stdout(io.StringIO()):
                with self.assertRaises(subprocess.CalledProcessError):
                    fast_flow.build_simulator(filelist, output, 1, tools)
            self.assertFalse(first.exists())
            self.assertFalse((output / "sim.json").exists())

    def workload(self, name):
        case = self.root / "cases" / name
        case.mkdir(parents=True)
        (case / "program.data").write_text("00\n")
        (case / "expected.txt").write_text("0\n")
        (case / "metrics.json").write_text('{"dynamic_instructions": 10}')
        return case

    def test_testcase_cache_invalidates_answer_and_latency(self):
        case = self.workload("perf_a")
        simulator = self.root / "sim"
        simulator.write_bytes(b"simulator")
        settings = dict(kind="perf", simulator=simulator, testcases=case.parent,
                        output=self.root / "results", result_cache=self.root / "cache", workers=1)
        with patch("parallel_cases.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "0\n", "CPU2026 cycles=5\n")) as run, redirect_stdout(io.StringIO()):
            self.assertEqual(run_cases(**settings), 0)
            self.assertEqual(run_cases(**settings), 0)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run_cases(**settings, latency=11), 0)
            self.assertEqual(run.call_count, 2)
            (case / "expected.txt").write_text("1\n")
            self.assertEqual(run_cases(**settings), 1)
            self.assertEqual(run.call_count, 3)

    def test_parallel_failure_never_outputs_partial_geomean(self):
        self.workload("perf_a")
        self.workload("perf_b")
        (self.root / "sim").write_bytes(b"simulator")
        results = [subprocess.CompletedProcess([], 0, "0\n", "CPU2026 cycles=5\n"),
                   subprocess.CompletedProcess([], 1, "", "failed")]
        output = io.StringIO()
        with patch("parallel_cases.subprocess.run", side_effect=results), redirect_stdout(output):
            status = run_cases("perf", self.root / "sim", self.root / "cases", workers=2,
                               output=self.root / "results")
        self.assertEqual(status, 1)
        self.assertNotIn("GEOMEAN", output.getvalue())
        report = json.loads((self.root / "results/perf.json").read_text())
        self.assertEqual(report["failed"], 1)
        self.assertIsNone(report["ipc_geomean"])


if __name__ == "__main__":
    unittest.main()
