"""Directed SV-2005 regressions for dual rename, banked ROB and operand capture."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
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
    for name, source in (("rename_dual_tb", "backend/rename_dual.sv"),
                         ("rob_dual_tb", "backend/rob.sv"),
                         ("issue_dual_tb", "backend/issue.sv")):
        objects = output / name
        model = objects / ("sim.exe" if os.name == "nt" else "sim")
        command = [verilator, "--cc", "--main", "--exe", "--timing", "--assert",
                   "--language", "1800-2005", "-Wno-fatal", "--top-module", name,
                   "--Mdir", objects.as_posix(), "-o", model.as_posix(),
                   "-CFLAGS", "-std=c++17",
                   str(ROOT / "tb/unit" / (name + ".sv")),
                   str(ROOT / "verilog" / source),
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
