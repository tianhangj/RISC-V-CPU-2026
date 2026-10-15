"""Cached development builds and synthesis, using the official simulation driver."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
from build import read_sources
from fakeram import with_ram_source, RAM_SOURCE
from flow_cache import identities, locked, read_json, rtl_dependencies, save_record, valid_record, write_json

DEFAULT_JOBS = min(8, os.cpu_count() or 1)


def build_simulator(filelist, output, jobs, tools, overrides=None, monitored=False,
                    optimization="-O3", force=False, extra_inputs=()):
    """Reuse exact binaries; regenerate changed RTL and let Make reuse C++ objects."""
    from instrumentation import MONITORS
    if jobs < 1 or optimization not in ("-Os", "-O3"):
        raise ValueError("invalid jobs or optimization")
    output = Path(output).resolve()
    sources = with_ram_source(read_sources(filelist)) + (MONITORS if monitored else [])
    overrides = overrides or {}
    # Verilator embeds absolute paths; never share an object directory across roots.
    paths = str(ROOT) + str(output)
    if any(c.isspace() or c in "()&;|<>$`'\"#" for c in paths):
        raise ValueError("Verilator/Make require paths without spaces or shell metacharacters")
    tool_paths = {name: Path(value).resolve().as_posix() for name, value in tools.items()}
    tool_inputs = list(tool_paths.values())
    for suffix in ("verilator_bin", "verilator_bin.exe"):
        native = Path(tool_paths["verilator"]).with_name(suffix)
        if native.is_file():
            tool_inputs.append(native)
    runtime = Path(os.environ.get("VERILATOR_ROOT", "")) / "include"
    runtime_inputs = sorted(p for p in runtime.rglob("*") if p.is_file() and p.suffix in (".h", ".cpp", ".mk"))
    configuration = {"schema": 1, "root": ROOT.as_posix(), "output": output.as_posix(),
                     "tools": identities(tool_inputs), "tool_paths": tool_paths,
                     "runtime": identities(runtime_inputs), "python": sys.version,
                     "overrides": overrides, "monitored": monitored,
                     "optimization": optimization, "language": "1800-2005", "trace": True, "assert": True}
    inputs = rtl_dependencies(sources) + [SCRIPTS / "sim.cpp", Path(filelist).resolve(),
              SCRIPTS / "build.py", SCRIPTS / "fakeram.py", Path(__file__),
              Path(__file__).with_name("flow_cache.py"), *extra_inputs]
    hashes = identities(inputs)
    identity = {"configuration": configuration, "inputs": hashes}
    binary = output / ("sim.exe" if os.name == "nt" else "sim")
    manifest = output / "sim.json"
    record = output / ".flow-build.json"
    with locked(output):
        if not force and valid_record(record, identity):
            print(f"Reusing simulator: {binary}", flush=True)
            return binary, read_json(manifest)["source_sha256"]
        old = read_json(record)
        objects = output / "obj"
        compatible = not force and old.get("identity", {}).get("configuration") == configuration
        if objects.is_symlink():
            objects.unlink()
        elif objects.exists() and not compatible:
            if objects.resolve().parent != output:
                raise ValueError(f"object directory outside build output: {objects}")
            shutil.rmtree(objects)
        binary.unlink(missing_ok=True)
        manifest.unlink(missing_ok=True)
        record.unlink(missing_ok=True)
        command = [tool_paths["verilator"], "--cc", "--exe", "--trace", "--assert",
                   "--language", "1800-2005", "-Wno-fatal", "--top-module", "student_top",
                   "--Mdir", objects.as_posix(), "-o", binary.as_posix(),
                   "-CFLAGS", "-std=c++17 -DVL_TIME_CONTEXT",
                   *[f"-G{k}={v}" for k, v in sorted(overrides.items())],
                   *[p.as_posix() for p in sources], (SCRIPTS / "sim.cpp").as_posix()]
        make = [tool_paths["make"], "-C", objects.as_posix(), "-f", "Vstudent_top.mk", f"-j{jobs}",
                f"CXX={tool_paths['cxx']}", f"LINK={tool_paths['cxx']}", f"AR={tool_paths['ar']}",
                f"PYTHON3={Path(sys.executable).as_posix()}",
                f"OPT_FAST={optimization}", f"OPT_GLOBAL={optimization}"]
        start = time.perf_counter()
        print(f"Building {'monitored ' if monitored else ''}simulator ({optimization}); log: {output / 'build.log'}", flush=True)
        with (output / "build.log").open("w", encoding="utf-8") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run(make, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        if not binary.is_file():
            raise ValueError(f"simulator missing after build: {output / 'build.log'}")
        # Reject publication if an editor changed an input while compilation ran.
        if identities(inputs) != hashes:
            binary.unlink()
            raise ValueError("source changed during build; rerun with the current source")
        relative_hashes = {Path(p).relative_to(ROOT).as_posix() if Path(p).is_relative_to(ROOT) else p: h
                           for p, h in hashes.items()}
        write_json(manifest, {"overrides": overrides, "source_sha256": relative_hashes,
                             "language": "1800-2005", "monitored": monitored,
                             "optimization": optimization, "build_seconds": time.perf_counter() - start})
        save_record(record, identity, [binary, manifest])
    return binary, relative_hashes


def synthesize(arguments, extra_inputs=()):
    """Cache successful official results and Yosys phases without changing mapping."""
    import synth
    from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable, packaged_tool
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filelist", type=Path, default=Path("verilog/filelist.f"))
    parser.add_argument("--out", type=Path, default=Path("build/synth"))
    parser.add_argument("--mode", choices=("opt", "diagnose"), default="opt")
    parser.add_argument("--clock-period", type=float, default=2.0)
    parser.add_argument("--clock-port", default="clock")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    parser.add_argument("--yosys")
    parser.add_argument("--abc")
    parser.add_argument("--sta")
    parser.add_argument("--asap7-lib", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(arguments)
    import math
    if not math.isfinite(args.clock_period) or args.clock_period <= 0:
        parser.error("clock period must be finite and positive")
    legacy = args.filelist.resolve().parent / "blackboxes.txt"
    if legacy.is_file() and any(line.split("#", 1)[0].strip() for line in legacy.read_text().splitlines()):
        parser.error("zero-area blackbox exclusions are not supported")
    if not (args.yosys and args.asap7_lib and args.sta):
        enter_appimage(args.appimage)
    yosys = executable(args.yosys) if args.yosys else (packaged_tool("yosys") or executable("yosys"))
    sta = executable(args.sta) if args.sta else (packaged_tool("sta") or executable("sta"))
    abc = (executable(args.abc) if args.abc else
           packaged_tool("yosys-abc") or executable(os.environ.get("CPU2026_ABC", "yosys-abc")))
    libraries = sorted((args.asap7_lib or Path(os.environ.get("CPU2026_ASAP7_LIB", "/opt/asap7/lib"))).resolve().glob("*.lib"))
    if len(libraries) != 5:
        parser.error("five ASAP7 RVT TT libraries required")
    out = args.out.resolve() / args.mode
    sources = rtl_dependencies(with_ram_source(read_sources(args.filelist)))
    common = [*sources, args.filelist.resolve(), SCRIPTS / "synth.py", SCRIPTS / "build.py",
              SCRIPTS / "fakeram.py", SCRIPTS / "synth_report.py", Path(__file__),
              Path(__file__).with_name("flow_cache.py"), *extra_inputs]
    # Respect any local constraints already used by the course script.
    constraint = ROOT / "abc.constr"
    inputs = [*common, SCRIPTS / "timing.py", SCRIPTS / "timing.tcl", *libraries, yosys, abc, sta]
    if constraint.is_file():
        inputs.append(constraint)
    hashes = identities(inputs)
    identity = {"schema": 1, "inputs": hashes, "mode": args.mode,
                "period": args.clock_period, "clock_port": args.clock_port,
                "out": out.as_posix(), "abc_constraint": constraint.is_file(),
                "yosys_version": synth.subprocess.check_output([yosys, "-V"], text=True).strip(),
                "sta_version": synth.subprocess.check_output([sta, "-version"], text=True).strip()}
    record = out / ".flow-synth.json"
    original_run = synth.run_yosys
    original_argv = sys.argv

    def cached_yosys(exe, directory, name, commands):
        stage_inputs = [*common, exe]
        artifacts = [directory / "elaborated.json"]
        if name == "synth":
            stage_inputs.extend([abc, *libraries, directory / "ram/prepared.json"])
            stage_inputs.extend(sorted(p for p in (directory / "ram").rglob("*") if p.is_file()))
            if constraint.is_file():
                stage_inputs.append(constraint)
            artifacts = [directory / n for n in ("design.json", "stat.json", "mapped.v")]
        phase = {"commands": commands, "inputs": identities(stage_inputs)}
        stage_record = directory / (".flow-synth-stage.json" if name == "synth" else f".flow-{name}.json")
        if not args.force and valid_record(stage_record, phase):
            print(f"Reusing Yosys {name}: {directory}", flush=True)
            return
        stage_record.unlink(missing_ok=True)
        start = time.perf_counter()
        original_run(exe, directory, name, commands)
        if identities(stage_inputs) != phase["inputs"]:
            raise ValueError("source changed during synthesis; rerun")
        save_record(stage_record, phase, artifacts)
        print(f"Yosys {name}: {time.perf_counter() - start:.2f}s", flush=True)

    with locked(out):
        if not args.force and valid_record(record, identity):
            print(f"Reusing synthesis and timing: {out}", flush=True)
            from synth_report import format_report
            print(format_report(read_json(out / "report.json")), end="")
            return 0
        record.unlink(missing_ok=True)
        synth.run_yosys = cached_yosys
        sys.argv = [str(SCRIPTS / "synth.py"), "--filelist", str(args.filelist.resolve()),
                    "--out", str(args.out.resolve()), "--mode", args.mode,
                    "--clock-period", str(args.clock_period), "--clock-port", args.clock_port,
                    "--appimage", "", "--yosys", yosys, "--abc", abc, "--sta", sta,
                    "--asap7-lib", str(libraries[0].parent)]
        start = time.perf_counter()
        try:
            synth.main()
        finally:
            synth.run_yosys, sys.argv = original_run, original_argv
        if identities(inputs) != hashes or constraint.is_file() != identity["abc_constraint"]:
            raise ValueError("source or constraints changed during synthesis; rerun")
        artifacts = [out / n for n in ("report.json", "report.txt", "area.json", "timing.json",
                     "design.json", "stat.json", "mapped.v", "timing_values.json", "critical_paths.json",
                     "constraints.sdc", "timing.rpt", "timing_checks.rpt", "clock_checks.rpt")]
        artifacts.extend(sorted(p for p in (out / "ram").rglob("*") if p.is_file()))
        save_record(record, identity, artifacts)
        print(f"Synthesis and timing: {time.perf_counter() - start:.2f}s", flush=True)
    return 0
