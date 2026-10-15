"""Windows-native adapters for the unchanged course scripts (Python 3.10+)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

HOME = Path(__file__).resolve().parent
ROOT = HOME.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / "dev"))


def activate():
    if sys.platform != "win32":
        raise ValueError("This entry point requires native Windows Python")
    directories = [HOME / "msys64/mingw64/bin", HOME / "oss-cad-suite/bin",
                   HOME / "oss-cad-suite/lib", HOME / "msys64/usr/bin",
                   HOME / "opensta/bin"]
    os.environ["PATH"] = os.pathsep.join(map(str, directories)) + os.pathsep + os.environ["PATH"]
    os.environ["VERILATOR_ROOT"] = (HOME / "oss-cad-suite/share/verilator").as_posix()
    os.environ["CPU2026_ASAP7_LIB"] = (HOME / "asap7/lib").as_posix()
    os.environ["TCL_LIBRARY"] = (HOME / "msys64/mingw64/lib/tcl8.6").as_posix()
    os.environ["PYTHONUTF8"] = "1"
    os.environ["PYTHONUNBUFFERED"] = "1"
    os.environ["MSYS2_ARG_CONV_EXCL"] = "*"
    os.environ.pop("CPU2026_APPDIR", None)
    temporary = HOME / "tmp"
    temporary.mkdir(exist_ok=True)
    for name in ("TMP", "TEMP", "TMPDIR"):
        os.environ[name] = temporary.as_posix()


def tool(relative):
    path = HOME / relative
    if not path.is_file():
        raise ValueError(f"Missing {path}; run powershell -ExecutionPolicy Bypass -File toolchain/setup.ps1")
    return path.as_posix()


def tool_environment(command):
    environment = os.environ.copy()
    if Path(command[0]).name.lower() in ("yosys.exe", "yosys-abc.exe"):
        # OSS CAD Suite links against its own Tcl/readline DLLs. MinGW's DLLs
        # have overlapping names but incompatible exported symbols.
        environment["PATH"] = os.pathsep.join(map(str, (
            HOME / "oss-cad-suite/bin", HOME / "oss-cad-suite/lib"))) + os.pathsep + environment["PATH"]
        environment["TCL_LIBRARY"] = (HOME / "oss-cad-suite/lib/tcl8.6").as_posix()
    return environment


def native_run(command, **kwargs):
    kwargs.setdefault("env", tool_environment(command))
    return subprocess.run(command, **kwargs)


def native_output(command, **kwargs):
    kwargs.setdefault("env", tool_environment(command))
    return subprocess.check_output(command, **kwargs)


def build_simulator(filelist, output, jobs, overrides=None, monitored=False,
                    optimization="-O3", force=False):
    from fast_flow import build_simulator as cached_build
    tools = {"verilator": tool("oss-cad-suite/bin/verilator_bin.exe"),
             "make": tool("msys64/usr/bin/make.exe"),
             "cxx": tool("msys64/mingw64/bin/g++.exe"),
             "ar": tool("msys64/mingw64/bin/ar.exe")}
    return cached_build(filelist, output, jobs, tools, overrides, monitored,
                        optimization, force, extra_inputs=[Path(__file__)])


def synthesize(arguments):
    import synth
    import timing
    # Limit the environment override to synthesis's external tool invocations.
    synth.subprocess = SimpleNamespace(run=native_run, check_output=native_output)
    # Yosys/ABC/Tcl accept forward-slash Windows paths. Keep course files intact.
    original_quote = synth.quote
    original_tcl_word = timing.tcl_word
    def windows_quote(value):
        path = value.as_posix() if isinstance(value, Path) else str(value).replace("\\", "/")
        # Yosys's Windows ABC launcher adds its own executable quotes. The
        # installation path is constrained to contain no shell metacharacters.
        return path if path.lower().endswith("/yosys-abc.exe") else original_quote(path)
    synth.quote = windows_quote
    timing.tcl_word = lambda value: original_tcl_word(value.as_posix() if isinstance(value, Path) else value)
    from fast_flow import synthesize as cached_synthesis
    return cached_synthesis(["--appimage", "",
                "--yosys", tool("oss-cad-suite/bin/yosys.exe"),
                "--abc", tool("oss-cad-suite/bin/yosys-abc.exe"),
                "--sta", tool("opensta/bin/sta.exe"),
                "--asap7-lib", (HOME / "asap7/lib").as_posix(), *arguments], extra_inputs=[Path(__file__)])


def profile(target, arguments):
    import instrumentation
    from fast_flow import DEFAULT_JOBS
    adapter = argparse.ArgumentParser(add_help=False)
    adapter.add_argument("--build-out", type=Path)
    adapter.add_argument("--force", action="store_true")
    adapter.add_argument("--optimization", choices=("size", "speed"), default="speed")
    options, arguments = adapter.parse_known_args(arguments)
    instrumentation.build = lambda filelist, output, overrides, jobs, appimage, verilator=None: \
        build_simulator(filelist, options.build_out or output, jobs, overrides, monitored=True,
                        optimization="-O3" if options.optimization == "speed" else "-Os",
                        force=options.force)
    if target == "ipc-profile":
        import ipc_profile as module
    else:
        import branch_accuracy as module
    sys.argv = [str(SCRIPTS / "dev" / (target.replace("-", "_") + ".py")),
                "--appimage", "", "--jobs", str(DEFAULT_JOBS), *arguments]
    return module.main()


def versions():
    commands = {"python": [sys.executable, "--version"],
                "verilator": [tool("oss-cad-suite/bin/verilator_bin.exe"), "--version"],
                "yosys": [tool("oss-cad-suite/bin/yosys.exe"), "-V"],
                "opensta": [tool("opensta/bin/sta.exe"), "-version"],
                "g++": [tool("msys64/mingw64/bin/g++.exe"), "--version"],
                "make": [tool("msys64/usr/bin/make.exe"), "--version"]}
    result = {}
    for name, command in commands.items():
        output = native_output(command, text=True, encoding="utf-8", errors="replace")
        result[name] = output.splitlines()[0]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("build", "test", "perf", "ipc-profile", "branch-accuracy",
                                           "synth", "run", "doctor"))
    args, remaining = parser.parse_known_args(sys.argv[1:2])
    remaining.extend(sys.argv[2:])
    activate()
    os.chdir(ROOT)
    if args.target == "doctor":
        print(json.dumps(versions(), indent=2))
        libraries = sorted((HOME / "asap7/lib").glob("*.lib"))
        if len(libraries) != 5:
            raise ValueError("Five ASAP7 libraries required; rerun toolchain/setup.ps1")
        return 0
    if args.target == "synth":
        return synthesize(remaining)
    if args.target in ("ipc-profile", "branch-accuracy"):
        return profile(args.target, remaining)
    if args.target == "run":
        return subprocess.call([sys.executable, str(SCRIPTS / "run.py"), *remaining], cwd=ROOT)
    build_parser = argparse.ArgumentParser(description=f"Windows {args.target}")
    build_parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    build_parser.add_argument("--out", type=Path, default=ROOT / "build/windows")
    from fast_flow import DEFAULT_JOBS
    build_parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    build_parser.add_argument("--optimization", choices=("size", "speed"), default="speed")
    build_parser.add_argument("--force", action="store_true", help="force a clean simulator rebuild")
    build_parser.add_argument("--parameter", action="append", default=[], metavar="NAME=VALUE")
    if args.target != "build":
        build_parser.add_argument("--sim", type=Path)
        build_parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
        build_parser.add_argument("--case")
        build_parser.add_argument("--max-cycles", type=int, default=100_000_000)
        build_parser.add_argument("--latency", type=int, default=10)
        build_parser.add_argument("--test-jobs", type=int, default=4)
        build_parser.add_argument("--timeout", type=float, default=3600)
        build_parser.add_argument("--results", type=Path)
        build_parser.add_argument("--reuse-results", action="store_true", help="reuse successful cases with identical simulator and inputs")
        build_parser.add_argument("--result-cache", type=Path)
    options = build_parser.parse_args(remaining)
    if options.jobs < 1:
        build_parser.error("jobs must be positive")
    simulator = getattr(options, "sim", None)
    from instrumentation import parameters
    overrides = parameters(options.parameter, options.filelist)
    if simulator is not None and overrides:
        build_parser.error("--parameter cannot be combined with a prebuilt --sim")
    if simulator is None:
        simulator, _ = build_simulator(options.filelist, options.out, options.jobs,
                                      overrides=overrides,
                                      optimization="-O3" if options.optimization == "speed" else "-Os",
                                      force=options.force)
    if args.target == "build":
        print(simulator)
        return 0
    from parallel_cases import run_cases
    return run_cases("correctness" if args.target == "test" else "perf", simulator,
                     options.testcases, options.case, options.max_cycles, options.latency,
                     options.test_jobs, options.timeout, options.results or options.out / "results",
                     (options.result_cache or options.out / "case-cache") if options.reuse_results and not options.force else None)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Windows toolchain failed: {error}", file=sys.stderr)
        raise SystemExit(getattr(error, "returncode", 1))
