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
CLOCK_PERIOD_NS ?= 5.0
FILELIST ?= verilog/filelist.f
PROGRAM ?= program.bin
EXPECTED ?=
Case ?=
JOBS ?= 1
MAX_CYCLES ?= 1000000
BP_MAX_CYCLES ?= 100000000
BP_WB_WIDTH ?= 2
BP_COMMIT_WIDTH ?= 2
BP_ENABLE ?= 1
BP_STATS_OUT ?= $(BUILD)/branch-accuracy
IPC_STATS_OUT ?= $(BUILD)/ipc-profile
PARAMETERS ?=
IMAGE ?= cpu2026:latest
REPORT_OUT ?= $(BUILD)/reports
LATENCY ?= 10
FAST_BUILD ?= $(BUILD)/fast
TEST_JOBS ?= 4
REUSE_RESULTS ?= 0
FORCE ?= 0
WAVE ?=
LOG ?=
ifneq ($(strip $(BLACKBOXES)),)
$(error BLACKBOXES has been removed; instantiate sram_fakeram instead)
endif

.PHONY: code help build run test branch-accuracy ipc-profile report perf synth clean fast-build fast-test fast-perf fast-synth

# OJ always builds RTL and collects ./code. SIM affects local run/test/perf only.
code:
	rm -f -- code
	$(MAKE) --no-print-directory -f "$(FRAMEWORK_DIR)/Makefile" build CONFIG="$(CONFIG)"
	cp -- "$(BUILD)/sim" code

help:
	@echo 'Host prerequisites: Python 3.10+, GNU Make, G++ (C++17), and binutils. No Docker required.'
	@echo 'Configure APPIMAGE or native VERILATOR/YOSYS/ABC/STA/ASAP7_LIB in config.mk.'
	@echo 'make build [FILELIST=verilog/filelist.f BUILD=build JOBS=1]'
	@echo 'make run PROGRAM=program.bin EXPECTED=186 [WAVE=trace.vcd] [LOG=run.log]'
	@echo 'make test [Case=correctness_add_to_100] [SIM=/path/to/prebuilt/sim]'
	@echo 'make ipc-profile [Case=perf_qsort PARAMETERS="WB_WIDTH=1 COMMIT_WIDTH=2"]'
	@echo '  JSON and workload logs: IPC_STATS_OUT (default BUILD/ipc-profile)'
	@echo 'make branch-accuracy [Case=perf_qsort BP_WB_WIDTH=2 BP_COMMIT_WIDTH=2 BP_ENABLE=1]'
	@echo '  JSON/CSV and per-PC statistics: BP_STATS_OUT (default BUILD/branch-accuracy)'
	@echo 'make report [IMAGE=cpu2026:latest REPORT_OUT=build/reports JOBS=1]'
	@echo '  Runs correctness, perf, IPC profiling and synth sequentially in Docker.'
	@echo 'make perf [Case=perf_median] [SIM=/path/to/prebuilt/sim]'
	@echo 'make synth [MODE=opt|diagnose CLOCK_PERIOD_NS=5.0 FILELIST=verilog/filelist.f]'
	@echo '  Outputs: SYNTH_OUT/MODE/ (SYNTH_OUT defaults to build/synth)'
	@echo 'make clean  (removes BUILD, SYNTH_OUT and code)'
	@echo 'make fast-test / fast-perf [JOBS=8 TEST_JOBS=4 REUSE_RESULTS=1 FORCE=1]'
	@echo 'make fast-synth: reuse verified synthesis results; FORCE=1 reruns all phases'
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

branch-accuracy:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/dev/branch_accuracy.py" --out "$(BP_STATS_OUT)" --filelist "$(FILELIST)" \
		--testcases "$(TESTCASES)" --wb-width $(BP_WB_WIDTH) --commit-width $(BP_COMMIT_WIDTH) --bp-enable $(BP_ENABLE) \
		--max-cycles $(BP_MAX_CYCLES) --latency $(LATENCY) --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",) $(if $(Case),--case "$(Case)",)

ipc-profile:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/dev/ipc_profile.py" --out "$(IPC_STATS_OUT)" --filelist "$(FILELIST)" \
		--testcases "$(TESTCASES)" --max-cycles $(BP_MAX_CYCLES) --latency $(LATENCY) --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" $(if $(VERILATOR),--verilator "$(VERILATOR)",) \
		$(foreach value,$(PARAMETERS),--parameter "$(value)") $(if $(Case),--case "$(Case)",)

report:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/dev/report.py" --image "$(IMAGE)" --output-dir "$(REPORT_OUT)" --jobs $(JOBS)

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

fast-build fast-test fast-perf:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/dev/fast.py" $(patsubst fast-%,%,$@) \
		--filelist "$(FILELIST)" --out "$(FAST_BUILD)" --jobs $(JOBS) \
		--appimage "$(APPIMAGE)" --cxx "$(CXX)" --ar "$(AR)" --make "$(BUILD_MAKE)" \
		$(if $(VERILATOR),--verilator "$(VERILATOR)",) \
		--testcases "$(TESTCASES)" --max-cycles $(MAX_CYCLES) --latency $(LATENCY) --test-jobs $(TEST_JOBS) \
		$(if $(SIM),--sim "$(SIM)",) $(if $(Case),--case "$(Case)",) \
		$(if $(filter 1,$(REUSE_RESULTS)),--reuse-results,) $(if $(filter 1,$(FORCE)),--force,)

fast-synth:
	"$(PYTHON)" "$(FRAMEWORK_DIR)/scripts/dev/fast.py" synth --filelist "$(FILELIST)" --out "$(SYNTH_OUT)" \
		--mode "$(MODE)" --clock-period "$(CLOCK_PERIOD_NS)" --appimage "$(APPIMAGE)" \
		$(if $(YOSYS),--yosys "$(YOSYS)",) $(if $(ABC),--abc "$(ABC)",) \
		$(if $(STA),--sta "$(STA)",) $(if $(ASAP7_LIB),--asap7-lib "$(ASAP7_LIB)",) \
		$(if $(filter 1,$(FORCE)),--force,)

clean:
	rm -rf -- "$(BUILD)" "$(SYNTH_OUT)"
	rm -f -- code
