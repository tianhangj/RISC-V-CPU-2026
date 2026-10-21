"""SV-2005 regressions for dispatch, operands, WB, LSU and multicycle execution."""
import os
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    cases = (("rename_dual_tb", ("backend/rename_dual.sv",)),
             ("rob_dual_tb", ("backend/rob.sv",)),
             ("issue_dual_tb", ("backend/issue.sv",)),
             ("writeback_stage_tb", ("backend/wb_arb.sv", "backend/rob.sv", "backend/prf.sv")),
             ("lsu_stage_tb", ("memory/lsu.sv", "common/word_adder.sv")),
             ("dcache_refill_tb", ("memory/dcache.sv",)),
             ("dcache_lru_tb", ("memory/dcache.sv",)),
             ("mul_div_tb", ("execute/mul_div.sv",)))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", choices=[name for name, _ in cases])
    args = parser.parse_args()
    selected = args.case or ("rob_dual_tb", "writeback_stage_tb", "lsu_stage_tb", "mul_div_tb")
    if os.name == "nt":
        sys.path.insert(0, str(ROOT / "toolchain"))
        import windows
        windows.activate()
        verilator = windows.tool("oss-cad-suite/bin/verilator_bin.exe")
        make = windows.tool("msys64/usr/bin/make.exe")
        cxx = windows.tool("msys64/mingw64/bin/g++.exe")
        archiver = windows.tool("msys64/mingw64/bin/ar.exe")
    else:
        verilator, make, cxx, archiver = (
            shutil.which(name) for name in ("verilator", "make", "g++", "ar"))
    output = ROOT / "build/multi-unit"
    output.mkdir(parents=True, exist_ok=True)
    for name, sources in cases:
        if name not in selected:
            continue
        objects = output / name
        model = objects / ("sim.exe" if os.name == "nt" else "sim")
        command = [verilator, "--cc", "--main", "--exe", "--timing", "--assert",
                   "--language", "1800-2005", "-Wno-fatal", "--top-module", name,
                   "--Mdir", objects.as_posix(), "-o", model.as_posix(),
                   "-CFLAGS", "-std=c++17",
                   str(ROOT / "tb/unit" / (name + ".sv")),
                   *[str(ROOT / "verilog" / source) for source in sources],
                   str(ROOT / "verilog/common/signal_fanout.sv"),
                   str(ROOT / "verilog/common/payload_ram.sv"),
                   str(ROOT / "scripts/ram/sram_fakeram.sv")]
        with (output / (name + ".log")).open("w") as log:
            subprocess.run(command, check=True, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            subprocess.run([make, "-C", objects.as_posix(), "-f", "V" + name + ".mk", "-j4",
                            "CXX=" + cxx, "LINK=" + cxx, "AR=" + archiver],
                           check=True, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run([str(model)], check=True, cwd=ROOT, timeout=30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
