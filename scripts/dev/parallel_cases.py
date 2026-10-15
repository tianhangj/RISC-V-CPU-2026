"""Run every selected official testcase with bounded independent simulators."""
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import subprocess
import sys
import time
from flow_cache import digest, identities, locked, read_json, valid_record, write_json

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from oj_io import prepare_case, compare_output
from testcase import CYCLES, cases_of


def run_cases(kind, simulator, testcases, case=None, max_cycles=100_000_000,
              latency=10, workers=4, timeout=3600, output=None, result_cache=None):
    cases = cases_of(testcases, kind, case)
    if case and (Path(case).name != case or case in (".", "..")):
        raise ValueError("case must be a testcase directory name")
    if not cases or any(not p.is_dir() for p in cases):
        raise ValueError("no matching testcases")
    if workers < 1 or timeout <= 0:
        raise ValueError("test jobs and timeout must be positive")
    if output:
        output = Path(output).resolve()
        output.mkdir(parents=True, exist_ok=True)
        (output / f"{kind}.json").unlink(missing_ok=True)
    simulator = str(Path(simulator).resolve())
    simulator_hash = digest(simulator)
    cache_inputs = identities([Path(__file__), ROOT / "scripts/oj_io.py", ROOT / "scripts/testcase.py"])
    if result_cache:
        result_cache = Path(result_cache).resolve()
        result_cache.mkdir(parents=True, exist_ok=True)
        # Create the common parents before worker threads touch Windows paths.
        for program in cases:
            (result_cache / program.name).mkdir(exist_ok=True)

    def simulate(program):
        start = time.perf_counter()
        row = {"case": program.name, "status": "failed"}
        try:
            data, answer = prepare_case(program, max_cycles, latency)
            run = subprocess.run([simulator], input=data, text=True, capture_output=True,
                                 timeout=timeout)
            if output:
                (output / f"{program.name}.stdout").write_text(run.stdout, encoding="utf-8")
                (output / f"{program.name}.stderr").write_text(run.stderr, encoding="utf-8")
            if run.returncode:
                raise ValueError(f"simulator exited {run.returncode}: {run.stderr.strip()}")
            error = compare_output(run.stdout, answer)
            if error:
                raise ValueError(error)
            match = CYCLES.search(run.stderr)
            if not match or int(match[1]) <= 0:
                raise ValueError("missing/invalid cycle report")
            row.update(status="passed", cycles=int(match[1]))
            if kind == "perf":
                instructions = json.loads((program / "metrics.json").read_text())["dynamic_instructions"]
                if not isinstance(instructions, int) or instructions <= 0:
                    raise ValueError("invalid dynamic instruction count")
                row.update(instructions=instructions, ipc=instructions / row["cycles"])
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            row.update(status="failed", error=str(error))
        row["seconds"] = time.perf_counter() - start
        row["reused"] = False
        return row

    def execute(program):
        if not result_cache:
            return simulate(program)
        cache = result_cache / program.name
        workload = [program / "program.data", program / "expected.txt"]
        if kind == "perf":
            workload.append(program / "metrics.json")
        try:
            identity = {"simulator": simulator_hash, "inputs": identities(workload),
                        "runner": cache_inputs, "kind": kind, "max_cycles": max_cycles,
                        "latency": latency, "timeout": timeout}
            with locked(cache):
                record = cache / "result.json"
                if valid_record(record, identity):
                    row = read_json(record)["result"]
                    row.update(reused=True, seconds=0.0)
                    if output:
                        for suffix in ("stdout", "stderr"):
                            (output / f"{program.name}.{suffix}").write_bytes((cache / suffix).read_bytes())
                    return row
                row = simulate(program)
                if row["status"] == "passed" and output:
                    # Only publish a successful result from stable inputs.
                    if identities(workload) != identity["inputs"] or digest(simulator) != simulator_hash:
                        return {"case": program.name, "status": "failed", "seconds": row["seconds"],
                                "reused": False, "error": "simulator or workload changed while running; rerun"}
                    artifacts = []
                    for suffix in ("stdout", "stderr"):
                        artifact = cache / suffix
                        artifact.write_bytes((output / f"{program.name}.{suffix}").read_bytes())
                        artifacts.append(artifact)
                    write_json(record, {"identity": identity, "artifacts": identities(artifacts), "result": row})
                return row
        except (OSError, ValueError, KeyError) as error:
            return {"case": program.name, "status": "failed", "seconds": 0.0,
                    "reused": False, "error": str(error)}

    start = time.perf_counter()
    print(f"Running {len(cases)} {kind} cases with {min(workers, len(cases))} workers", flush=True)
    # map preserves the official sorted output order; processes share no DUT state.
    rows = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for row in pool.map(execute, cases):
            rows.append(row)
            if kind == "correctness":
                print(f"\n[{row['case']}]", flush=True)
                print(f"PASS cycles={row['cycles']}" if row["status"] == "passed" else
                      f"FAIL: {row['error']}", flush=True)
    failed = sum(row["status"] != "passed" for row in rows)
    if digest(simulator) != simulator_hash:
        raise ValueError("simulator changed while running the suite; rerun")
    reused = sum(row.get("reused", False) for row in rows)
    if reused:
        print(f"Reused {reused}/{len(rows)} verified testcase results (identical simulator and inputs)", flush=True)
    geomean = None
    if kind == "perf":
        print(f"{'benchmark':<24} {'instructions':>14} {'cycles':>12} {'IPC':>10}", flush=True)
        for row in rows:
            if row["status"] == "passed":
                print(f"{row['case']:<24} {row['instructions']:>14} {row['cycles']:>12} {row['ipc']:>10.4f}")
            else:
                print(f"{row['case']}: FAIL: {row['error']}", file=sys.stderr)
        # A failed case must never produce a partial GEOMEAN resembling a full score.
        if not failed:
            geomean = math.exp(sum(math.log(row["ipc"]) for row in rows) / len(rows))
            print(f"{'GEOMEAN':<24} {'':>14} {'':>12} {geomean:>10.4f}", flush=True)
    else:
        print(f"\nResults: {len(rows) - failed} passed, {failed} failed", flush=True)
    if output:
        write_json(output / f"{kind}.json", {"cases": rows, "failed": failed,
                   "ipc_geomean": geomean, "seconds": time.perf_counter() - start,
                   "latency": latency, "max_cycles": max_cycles, "workers": workers, "reused": reused})
    return int(bool(failed))
