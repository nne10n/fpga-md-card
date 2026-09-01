# FPGA market-data card — simulation entrypoint (M1–M9)
# Usage:
#   make sim          # run full cocotb suite (CI-friendly, default SIM=questa)
#   make sim WAVES=1  # also dump waveform (FST on verilator, WLF on questa)
#   make sim-udp / make sim-dec / make sim-dec-sse / make sim-dec-fast
#   make sim-arb / make sim-cam / make sim-mcast / make sim-dma / make sim-top

ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENV        := $(ROOT)/.venv
PYTHON      := $(VENV)/bin/python

# Prefer locally built Verilator (>=5.036 required by cocotb 2.x)
LOCAL_VDIR := $(ROOT)/.local
ifeq ($(wildcard $(LOCAL_VDIR)/bin/verilator),)
  VERILATOR_BIN_DIR ?=
  export PATH := $(VENV)/bin:$(PATH)
else
  VERILATOR_BIN_DIR := $(LOCAL_VDIR)/bin
  export PATH := $(LOCAL_VDIR)/bin:$(VENV)/bin:$(PATH)
  export VERILATOR_ROOT := $(LOCAL_VDIR)/share/verilator
endif

# Default: QuestaSim (this environment). Override with SIM=verilator if needed.
SIM             ?= questa
TOPLEVEL_LANG   ?= verilog
WAVES           ?= 0
EXTRA_ARGS      ?=
COMPILE_ARGS    ?=
SIM_ARGS        ?=

export PYTHONPATH := $(ROOT)/tb:$(PYTHONPATH)
export COCOTB_REDUCED_LOG_FMT := 1

ifeq ($(SIM),verilator)
  EXTRA_ARGS += -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL
  EXTRA_ARGS += -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE
  EXTRA_ARGS += --timing
  ifeq ($(WAVES),1)
    VERILATOR_TRACE := 1
    EXTRA_ARGS += --trace-fst --trace-structs
  endif
else ifneq ($(filter questa questa-qisqrun modelsim,$(SIM)),)
  # EXTRA_ARGS is forwarded to both vlog and vsim — keep it empty.
  # COMPILE_ARGS is vlog-only. 2583 = timescale in package.
  COMPILE_ARGS += -suppress 2583 -svinputport=net
  ifeq ($(WAVES),1)
    SIM_ARGS += -wlf $(ROOT)/dump.wlf
  endif
endif

COCOTB_MF := $(shell test -x $(VENV)/bin/cocotb-config && $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim

COCOTB_COMMON = \
	SIM=$(SIM) \
	TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
	EXTRA_ARGS="$(EXTRA_ARGS)" \
	COMPILE_ARGS="$(COMPILE_ARGS)" \
	SIM_ARGS="$(SIM_ARGS)" \
	WAVES=$(WAVES) \
	VERILATOR_TRACE=$(VERILATOR_TRACE) \
	VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
	PYTHON_BIN=$(PYTHON)

.PHONY: venv
venv:
	@test -x $(PYTHON) || python3 -m venv $(VENV)
	@$(PYTHON) -m pip -q install -r $(ROOT)/requirements.txt

.PHONY: sim sim-udp sim-dec sim-dec-sse sim-dec-fast sim-arb sim-cam sim-mcast sim-dma sim-top
sim: sim-udp sim-dec sim-dec-sse sim-dec-fast sim-arb sim-cam sim-mcast sim-dma sim-top

sim-udp: venv
	rm -f $(ROOT)/sim_build/udp_strip/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/udp_strip.sv" \
		TOPLEVEL=udp_strip \
		MODULE=test_udp_strip \
		COCOTB_TOPLEVEL=udp_strip \
		COCOTB_TEST_MODULES=test_udp_strip \
		SIM_BUILD=$(ROOT)/sim_build/udp_strip

sim-dec: venv
	rm -f $(ROOT)/sim_build/dec_szse_bin/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_szse_bin.sv" \
		TOPLEVEL=dec_szse_bin \
		MODULE=test_dec_szse_bin \
		COCOTB_TOPLEVEL=dec_szse_bin \
		COCOTB_TEST_MODULES=test_dec_szse_bin \
		SIM_BUILD=$(ROOT)/sim_build/dec_szse_bin

sim-dec-sse: venv
	rm -f $(ROOT)/sim_build/dec_sse_bin/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_sse_bin.sv" \
		TOPLEVEL=dec_sse_bin \
		MODULE=test_dec_sse_bin \
		COCOTB_TOPLEVEL=dec_sse_bin \
		COCOTB_TEST_MODULES=test_dec_sse_bin \
		SIM_BUILD=$(ROOT)/sim_build/dec_sse_bin

sim-dec-fast: venv
	rm -f $(ROOT)/sim_build/dec_sse_fast/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_sse_fast.sv" \
		TOPLEVEL=dec_sse_fast \
		MODULE=test_dec_sse_fast \
		COCOTB_TOPLEVEL=dec_sse_fast \
		COCOTB_TEST_MODULES=test_dec_sse_fast \
		SIM_BUILD=$(ROOT)/sim_build/dec_sse_fast

sim-arb: venv
	rm -f $(ROOT)/sim_build/arb_nway/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/arb_nway.sv" \
		TOPLEVEL=arb_nway \
		MODULE=test_arb_nway \
		COCOTB_TOPLEVEL=arb_nway \
		COCOTB_TEST_MODULES=test_arb_nway \
		SIM_BUILD=$(ROOT)/sim_build/arb_nway

sim-cam: venv
	rm -f $(ROOT)/sim_build/sym_cam/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/sym_cam.sv" \
		TOPLEVEL=sym_cam \
		MODULE=test_sym_cam \
		COCOTB_TOPLEVEL=sym_cam \
		COCOTB_TEST_MODULES=test_sym_cam \
		SIM_BUILD=$(ROOT)/sim_build/sym_cam

sim-mcast: venv
	rm -f $(ROOT)/sim_build/mcast_eng/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/mcast_eng.sv" \
		TOPLEVEL=mcast_eng \
		MODULE=test_mcast_eng \
		COCOTB_TOPLEVEL=mcast_eng \
		COCOTB_TEST_MODULES=test_mcast_eng \
		SIM_BUILD=$(ROOT)/sim_build/mcast_eng

sim-dma: venv
	rm -f $(ROOT)/sim_build/dma_pack/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dma_pack.sv" \
		TOPLEVEL=dma_pack \
		MODULE=test_dma_pack \
		COCOTB_TOPLEVEL=dma_pack \
		COCOTB_TEST_MODULES=test_dma_pack \
		SIM_BUILD=$(ROOT)/sim_build/dma_pack

sim-top: venv
	rm -f $(ROOT)/sim_build/md_rx_top/runsim.do
	$(MAKE) -f $(COCOTB_MF) $(COCOTB_COMMON) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/udp_strip.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_sse_bin.sv $(ROOT)/rtl/dec_sse_fast.sv $(ROOT)/rtl/dec_szse_bin.sv $(ROOT)/rtl/arb_nway.sv $(ROOT)/rtl/event_merge.sv $(ROOT)/rtl/sym_cam.sv $(ROOT)/rtl/mcast_eng.sv $(ROOT)/rtl/dma_pack.sv $(ROOT)/rtl/telem.sv $(ROOT)/rtl/tcp_pay_stub.sv $(ROOT)/rtl/swallow.sv $(ROOT)/rtl/md_rx_top.sv" \
		TOPLEVEL=md_rx_top \
		MODULE=test_md_rx_top \
		COCOTB_TOPLEVEL=md_rx_top \
		COCOTB_TEST_MODULES=test_md_rx_top \
		SIM_BUILD=$(ROOT)/sim_build/md_rx_top

.PHONY: clean
clean:
	rm -rf sim_build results.xml dump.fst dump.vcd dump.wlf __pycache__ tb/__pycache__
	rm -f modelsim.ini transcript vsim.wlf

.PHONY: help
help:
	@echo "make sim          - run all unit + top integration tests (default SIM=questa)"
	@echo "make sim-udp      - udp_strip only"
	@echo "make sim-dec      - dec_szse_bin only"
	@echo "make sim-dec-sse  - dec_sse_bin only"
	@echo "make sim-dec-fast - dec_sse_fast only"
	@echo "make sim-arb      - arb_nway only"
	@echo "make sim-cam      - sym_cam only"
	@echo "make sim-mcast    - mcast_eng only"
	@echo "make sim-dma      - dma_pack only"
	@echo "make sim-top      - md_rx_top integration"
	@echo "make sim WAVES=1  - run with waveform dump (FST on verilator, WLF on questa)"
	@echo "make SIM=verilator sim  - use Verilator instead of QuestaSim"
	@echo "make clean        - remove build artefacts"
