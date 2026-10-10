"""Shared simulator build and configuration for the simulation-only monitors."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources, verilator_command
from fakeram import with_ram_source
from toolchain import enter_appimage

MONITORS = [ROOT / "tb/monitor" / name for name in
            ("ipc_stats.sv", "branch_stats_monitor.sv", "branch_stats_bind.sv")]


def parameters(values, filelist):
    """Accept only public top parameters; elaboration checks their constraints."""
    sources = read_sources(filelist)
    top = next((p for p in sources if re.search(r"\bmodule\s+student_top\b", p.read_text())), None)
    if top is None:
        raise ValueError("filelist must contain student_top")
    public = set(re.findall(r"parameter\s+(?:integer|\[31:0\])\s+(\w+)\s*=",
                            top.read_text().split(") (", 1)[0]))
    result = {}
    for value in values:
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(0[xX][0-9a-fA-F]+|[0-9]+)", value)
        if not match or match[1] not in public:
            raise ValueError(f"invalid or removed top parameter: {value}")
        if match[1] in result:
            raise ValueError(f"duplicate top parameter: {match[1]}")
        result[match[1]] = int(match[2], 16 if match[2].lower().startswith("0x") else 10)
    return result


def build(filelist, output, overrides, jobs, appimage, verilator=None):
    if not verilator:
        enter_appimage(appimage)
    sources = with_ram_source(read_sources(filelist)) + MONITORS
    binary = output / "sim"
    binary.unlink(missing_ok=True)
    manifest = output / "sim.json"
    manifest.unlink(missing_ok=True)
    command = [verilator_command(verilator), "--cc", "--exe", "--build", "--trace", "--assert",
               "--language", "1800-2005", "-Wno-fatal", "--top-module", "student_top",
               "--Mdir", str(output / "obj"), "-o", str(binary), "-j", str(jobs),
               "-CFLAGS", "-std=c++17", *[f"-G{name}={value}" for name, value in overrides.items()],
               *map(str, sources), str(ROOT / "scripts/sim.cpp")]
    print(f"Building monitored simulator; log: {output / 'build.log'}", flush=True)
    with (output / "build.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    hashes = {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):
              hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [ROOT / "scripts/sim.cpp", filelist.resolve()]}
    manifest.write_text(json.dumps({"overrides": overrides, "source_sha256": hashes,
                                    "language": "1800-2005"}, indent=2) + "\n")
    return binary, hashes
