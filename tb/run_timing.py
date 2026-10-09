#!/usr/bin/env python3
"""Run timing-sensitive IQ, scheduler, PRF and arithmetic regressions."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import verilator_command
from toolchain import DEFAULT_APPIMAGE, enter_appimage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build/timing-tests")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--verilator")
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    parser.add_argument("--case", action="append", help="run only the named test top (repeatable)")
    parser.add_argument("--all", action="store_true", help="run the complete directed regression instead of the short single-issue suite")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    try:
        if not args.verilator:
            enter_appimage(args.appimage)
        verilator = verilator_command(args.verilator)
        tests = [
            ("branch_predictor_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/pc_increment.sv", "verilog/branch_predictor.sv", "tb/branch_predictor.sv"], ["-GRAM=1"]),
            ("ordered_iq_test", ["verilog/signal_fanout.sv", "verilog/iq_alu.sv", "tb/ordered_iq.sv"], []),
            ("single_issue_test", ["verilog/signal_fanout.sv", "verilog/single_issue.sv", "tb/single_issue.sv"], []),
            ("single_issue_test", ["verilog/signal_fanout.sv", "verilog/single_issue.sv", "tb/single_issue.sv"], ["-GDELAYED=1"]),
            ("single_issue_test", ["verilog/signal_fanout.sv", "verilog/single_issue.sv", "tb/single_issue.sv"], ["-GSNAPSHOT=1"]),
            ("direct_rename_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/single_rename.sv", "tb/direct_rename.sv"], []),
            ("direct_rename_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/single_rename.sv", "tb/direct_rename.sv"], ["-GEAGER=1"]),
            ("alu_shared_test", ["verilog/word_adder.sv", "verilog/word_compare.sv", "verilog/alu.sv", "tb/alu_shared.sv"], []),
            ("alu_shared_test", ["verilog/word_adder.sv", "verilog/word_compare.sv", "verilog/alu.sv", "tb/alu_shared.sv"], ["-GISOLATE=1"]),
            ("store_buffer_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/store_buffer.sv"], []),
            ("store_buffer_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/store_buffer.sv"], ["-GFAST=1"]),
            ("store_buffer_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/store_buffer.sv"], ["-GFAST=2"]),
            ("store_forward_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/store_forward.sv"], []),
            ("store_forward_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/store_forward.sv"], ["-GBUFFERED=1"]),
            ("data_prefetch_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/data_prefetch.sv", "tb/data_prefetch.sv"], []),
            ("data_prefetch_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/data_prefetch.sv", "tb/data_prefetch.sv"], ["-GTARGETED=1"]),
            ("wb_pipeline_test", ["verilog/wb_arb.sv", "tb/wb_pipeline.sv"], []),
            ("wb_late_filter_test", ["verilog/wb_arb.sv", "tb/wb_late_filter.sv"], []),
            ("rename_checkpoint_test", ["verilog/signal_fanout.sv", "verilog/single_rename.sv", "verilog/rename.sv", "tb/rename_checkpoint.sv"], []),
            ("rename_stream_test", ["verilog/signal_fanout.sv", "verilog/single_rename.sv", "verilog/rename.sv", "tb/rename_stream.sv"], []),
            ("alu_forwarding_test", ["verilog/word_adder.sv", "verilog/word_compare.sv", "verilog/alu.sv", "tb/alu_forwarding.sv"], []),
            ("iq_alu_candidate_test", ["verilog/signal_fanout.sv", "verilog/iq_alu.sv", "tb/iq_alu_candidate.sv"], []),
            ("iq_mem_candidate_test", ["verilog/signal_fanout.sv", "verilog/iq_alu.sv", "verilog/iq_mem.sv", "tb/iq_mem_candidate.sv"], []),
            ("selection_tree_test", ["verilog/signal_fanout.sv", "verilog/iq_alu.sv", "verilog/issue_sched.sv", "tb/selection_tree.sv"], []),
            ("prf_hierarchical_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/prf.sv", "tb/prf_hierarchical.sv"], []),
            ("prf_hierarchical_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/prf.sv", "tb/prf_hierarchical.sv"], ["-GRAM=1"]),
            ("mul_div_test", ["verilog/mul_div.sv", "tb/mul_div.sv"], []),
            ("dcache_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/dcache.sv",
                             "verilog/axi_bridge.sv", "tb/dcache.sv"], []),
            ("dcache_stage2_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/dcache.sv",
                             "verilog/axi_bridge.sv", "tb/dcache.sv"], []),
            ("dcache_hum_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/dcache.sv",
                             "verilog/axi_bridge.sv", "tb/dcache.sv"], []),
            ("dcache_hum_test", ["scripts/ram/sram_fakeram.sv", "verilog/signal_fanout.sv", "verilog/dcache.sv",
                             "verilog/axi_bridge.sv", "tb/dcache.sv"], ["-GLINE=128"]),
            ("lsu_spec_read_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_spec_read.sv"], []),
            ("lsu_generation", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_generation.sv"], []),
            ("lsu_generation", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_generation.sv"], ["-GP=0"]),
            ("lsu_pipeline_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_pipeline.sv"], []),
            ("lsu_pipeline_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_pipeline.sv"], ["-GP=0"]),
            ("store_pipeline_test", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "verilog/rob.sv", "tb/store_pipeline.sv"], []),
            ("lsu_disambiguation", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_disambiguation.sv"], []),
            ("lsu_disambiguation", ["verilog/word_adder.sv", "verilog/signal_fanout.sv", "verilog/lsu.sv", "tb/lsu_disambiguation.sv"], ["-GP=0"]),
        ]
        from build import read_sources
        tests.append(("pipeline_stages_test", [str(path) for path in read_sources(ROOT / "verilog/filelist.f")] +
                      ["scripts/ram/sram_fakeram.sv", "tb/pipeline_stages.sv"], []))
        if args.case:
            unknown = set(args.case) - {top for top, _, _ in tests}
            if unknown:
                parser.error("unknown test: " + ", ".join(sorted(unknown)))
            tests = [test for test in tests if test[0] in args.case]
        elif not args.all:
            short_suite = {"alu_shared_test", "single_issue_test", "direct_rename_test", "store_buffer_test",
                           "data_prefetch_test", "dcache_stage2_test"}
            tests = [test for test in tests if test[0] in short_suite]
        output = args.build.resolve()
        output.mkdir(parents=True, exist_ok=True)
        for top, sources, parameters in tests:
            name = top + ("_" + parameters[0][2:].replace("=", "_") if parameters else "")
            directory = output / name
            log_path = output / (name + ".log")
            command = [verilator, "--binary", "--timing", "--assert",
                       "--language", "1800-2005", "-Wno-fatal", "-j", str(args.jobs),
                       "--top-module", top, "--Mdir", str(directory), *parameters, *sources]
            print(f"Building {name}; compiler log: {log_path}", flush=True)
            with log_path.open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([str(directory / ("V" + top))], cwd=ROOT, check=True, timeout=60)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Timing regression failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
