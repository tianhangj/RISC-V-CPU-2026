FRAMEWORK_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
.DEFAULT_GOAL := code
CONFIG ?= config.mk
-include $(CONFIG)

# Defaults also work when a student omits the optional config.mk.
PYTHON ?= python3
APPIMAGE ?= $(FRAMEWORK_DIR)/cpu2026-tools-x86_64.AppImage
VERILATOR ?=
YOSYS ?=
ABC ?=
STA ?=
ASAP7_LIB ?=
BUILD_MAKE ?= make
CXX ?= g++
AR ?= ar
SIM ?=
TESTCASES ?= $(FRAMEWORK_DIR)/testcases
BUILD ?= build
SYNTH_OUT ?= $(BUILD)/synth
MODE ?= opt
CLOCK_PERIOD_NS ?= 2.0
FILELIST ?= verilog/filelist.f
PROGRAM ?= program.bin
EXPECTED ?=
Case ?=
JOBS ?= 4
MAX_CYCLES ?= 1000000
BP_MAX_CYCLES ?= 100000000
BP_WIDTH ?= 1
BP_ENABLE ?= 1
BP_STATS_OUT ?= $(BUILD)/branch-accuracy
LATENCY ?= 10
WAVE ?=
LOG ?=
ifneq ($(strip $(BLACKBOXES)),)
$(error BLACKBOXES has been removed; instantiate sram_fakeram instead)
endif

.PHONY: code help build run test test-icache test-branch test-timing test-branch-accuracy branch-accuracy perf synth clean

# OJ always builds RTL and collects ./code. SIM affects local run/test/perf only.
code:
	rm -f -- code
	$(MAKE) --no-print-directory -f "$(FRAMEWORK_DIR)/Makefile" build CONFIG="$(CONFIG)"
	cp -- "$(BUILD)/sim" code

help:
	@echo 'Host prerequisites: Python 3.10+, GNU Make, G++ (C++17), and binutils. No Docker required.'
	@echo 'Configure APPIMAGE or native VERILATOR/YOSYS/ABC/STA/ASAP7_LIB in config.mk.'
	@echo 'make build [FILELIST=verilog/filelist.f BUILD=build JOBS=4]'
	@echo 'make run PROGRAM=program.bin EXPECTED=186 [WAVE=trace.vcd] [LOG=run.log]'
	@echo 'make test [Case=correctness_add_to_100] [SIM=/path/to/prebuilt/sim]'
	@echo 'make test-icache [BUILD=build JOBS=4]'
	@echo 'make test-branch [BUILD=build JOBS=4]'
	@echo 'make test-timing [BUILD=build JOBS=4]'
	@echo 'make test-branch-accuracy [BUILD=build JOBS=4]'
	@echo 'make branch-accuracy [Case=perf_qsort BP_WIDTH=1 BP_ENABLE=1 BP_MAX_CYCLES=100000000]'
	@echo '  CSV/JSON and per-PC statistics: BP_STATS_OUT (default BUILD/branch-accuracy)'
	@echo 'make perf [Case=perf_median] [SIM=/path/to/prebuilt/sim]'
	@echo 'make synth [MODE=opt|diagnose CLOCK_PERIOD_NS=2.0 FILELIST=verilog/filelist.f]'
	@echo '  Outputs: SYNTH_OUT/MODE/ (SYNTH_OUT defaults to build/synth)'
	@echo 'make clean  (removes BUILD, SYNTH_OUT and code)'
	@echo 'make / make code: compile RTL and produce ./code for OJ'

build:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/build.py" --filelist "$(FILELIST)" --out "$(BUILD)" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" --cxx "$(CXX)" --ar "$(AR)" --make "$(BUILD_MAKE)" \
		$(if $(VERILATOR),--verilator "$(VERILATOR)",)

ifeq ($(strip $(SIM)),)
run test perf: build
endif

run:
	@test -n "$(EXPECTED)" || (echo 'EXPECTED=... is required for make run' >&2; exit 2)
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/run.py" "$(PROGRAM)" --build "$(BUILD)" \
		--expected $(EXPECTED) --max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		$(if $(SIM),--sim "$(SIM)",) $(if $(WAVE),--wave "$(WAVE)",) \
		$(if $(LOG),--log "$(LOG)",)

test:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/testcase.py" --kind correctness --build "$(BUILD)" \
		--testcases "$(TESTCASES)" --max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		$(if $(SIM),--sim "$(SIM)",) $(if $(Case),--case "$(Case)",)

test-icache:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/tb/run_icache.py" --build "$(BUILD)/icache-tests" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",)

test-branch:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/tb/run_branch.py" --build "$(BUILD)/branch-tests" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",)

test-timing:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/tb/run_timing.py" --build "$(BUILD)/timing-tests" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",)

test-branch-accuracy:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/tb/test_branch_accuracy.py" --out "$(BUILD)/branch-accuracy-tests" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",)

branch-accuracy:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/tb/branch_accuracy.py" --out "$(BP_STATS_OUT)" --filelist "$(FILELIST)" \
		--testcases "$(TESTCASES)" --width $(BP_WIDTH) --bp-enable $(BP_ENABLE) \
		--max-cycles $(BP_MAX_CYCLES) --latency $(LATENCY) --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",) $(if $(Case),--case "$(Case)",)

perf:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/testcase.py" --kind perf --build "$(BUILD)" \
		--testcases "$(TESTCASES)" --max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		$(if $(SIM),--sim "$(SIM)",) $(if $(Case),--case "$(Case)",)

synth:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/synth.py" --filelist "$(FILELIST)" --out "$(SYNTH_OUT)" \
		--mode "$(MODE)" --clock-period "$(CLOCK_PERIOD_NS)" \
		--appimage "$(APPIMAGE)" $(if $(YOSYS),--yosys "$(YOSYS)",) \
		$(if $(ABC),--abc "$(ABC)",) $(if $(STA),--sta "$(STA)",) \
		$(if $(ASAP7_LIB),--asap7-lib "$(ASAP7_LIB)",)

clean:
	rm -rf -- "$(BUILD)" "$(SYNTH_OUT)"
	rm -f -- code
