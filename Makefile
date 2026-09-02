# FPGA market-data card — simulation entrypoint (M1–M9)
# Usage:
#   make sim          # run full cocotb suite (CI-friendly)
#   make sim WAVES=1  # also dump FST (per-target sim_build)
#   make sim-udp / make sim-dec / make sim-dec-sse / make sim-dec-fast / make sim-arb / make sim-cam / make sim-mcast / make sim-dma / make sim-top

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

SIM             ?= verilator
TOPLEVEL_LANG   ?= verilog
WAVES           ?= 0

export PYTHONPATH := $(ROOT)/tb:$(ROOT)/tb_x1100:$(ROOT)/tb_l1:$(PYTHONPATH)
export COCOTB_REDUCED_LOG_FMT := 1

EXTRA_ARGS += -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL
EXTRA_ARGS += -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-VARHIDDEN
EXTRA_ARGS += --timing

ifeq ($(WAVES),1)
  VERILATOR_TRACE := 1
  EXTRA_ARGS += --trace-fst --trace-structs
endif

.PHONY: venv
venv:
	@test -x $(PYTHON) || python3 -m venv $(VENV)
	@$(PYTHON) -m pip -q install -r $(ROOT)/requirements.txt

.PHONY: sim sim-udp sim-dec sim-dec-sse sim-dec-fast sim-arb sim-cam sim-mcast sim-dma sim-top sim-x1100 sim-book sim-x1100-book sim-l1
sim: sim-udp sim-dec sim-dec-sse sim-dec-fast sim-arb sim-cam sim-mcast sim-dma sim-top

sim-udp: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/udp_strip.sv" \
		TOPLEVEL=udp_strip \
		MODULE=test_udp_strip \
		COCOTB_TOPLEVEL=udp_strip \
		COCOTB_TEST_MODULES=test_udp_strip \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/udp_strip

sim-dec: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_szse_bin.sv" \
		TOPLEVEL=dec_szse_bin \
		MODULE=test_dec_szse_bin \
		COCOTB_TOPLEVEL=dec_szse_bin \
		COCOTB_TEST_MODULES=test_dec_szse_bin \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/dec_szse_bin

sim-dec-sse: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_sse_bin.sv" \
		TOPLEVEL=dec_sse_bin \
		MODULE=test_dec_sse_bin \
		COCOTB_TOPLEVEL=dec_sse_bin \
		COCOTB_TEST_MODULES=test_dec_sse_bin \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/dec_sse_bin

sim-dec-fast: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dec_sse_fast.sv" \
		TOPLEVEL=dec_sse_fast \
		MODULE=test_dec_sse_fast \
		COCOTB_TOPLEVEL=dec_sse_fast \
		COCOTB_TEST_MODULES=test_dec_sse_fast \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/dec_sse_fast

sim-arb: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/arb_nway.sv" \
		TOPLEVEL=arb_nway \
		MODULE=test_arb_nway \
		COCOTB_TOPLEVEL=arb_nway \
		COCOTB_TEST_MODULES=test_arb_nway \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/arb_nway

sim-cam: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/sym_cam.sv" \
		TOPLEVEL=sym_cam \
		MODULE=test_sym_cam \
		COCOTB_TOPLEVEL=sym_cam \
		COCOTB_TEST_MODULES=test_sym_cam \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/sym_cam

sim-mcast: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/mcast_eng.sv" \
		TOPLEVEL=mcast_eng \
		MODULE=test_mcast_eng \
		COCOTB_TOPLEVEL=mcast_eng \
		COCOTB_TEST_MODULES=test_mcast_eng \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/mcast_eng

sim-dma: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/dma_pack.sv" \
		TOPLEVEL=dma_pack \
		MODULE=test_dma_pack \
		COCOTB_TOPLEVEL=dma_pack \
		COCOTB_TEST_MODULES=test_dma_pack \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/dma_pack

sim-top: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/udp_strip.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_sse_bin.sv $(ROOT)/rtl/dec_sse_fast.sv $(ROOT)/rtl/dec_szse_bin.sv $(ROOT)/rtl/arb_nway.sv $(ROOT)/rtl/event_merge.sv $(ROOT)/rtl/sym_cam.sv $(ROOT)/rtl/mcast_eng.sv $(ROOT)/rtl/dma_pack.sv $(ROOT)/rtl/telem.sv $(ROOT)/rtl/tcp_pay_stub.sv $(ROOT)/rtl/swallow.sv $(ROOT)/rtl/md_rx_top.sv" \
		TOPLEVEL=md_rx_top \
		MODULE=test_md_rx_top \
		COCOTB_TOPLEVEL=md_rx_top \
		COCOTB_TEST_MODULES=test_md_rx_top \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/md_rx_top


# Book RTL shared by x1100 (ENABLE_BOOK) and unit TB
BOOK_RTL := $(ROOT)/rtl/book_pkg.sv $(ROOT)/rtl/hot_cam.sv $(ROOT)/rtl/order_cache.sv $(ROOT)/rtl/l1_cmd_stub.sv $(ROOT)/rtl/l1_ddr_engine.sv $(ROOT)/rtl/sim/axi_ddr_model.sv $(ROOT)/rtl/book_engine.sv

.PHONY: sim-x1100 sim-book
sim-x1100: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/x1100/ndpp_pkg.sv $(ROOT)/rtl/udp_strip.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_szse_bin.sv $(ROOT)/rtl/arb_nway.sv $(ROOT)/rtl/sym_cam.sv $(BOOK_RTL) $(ROOT)/rtl/mcast_eng.sv $(ROOT)/rtl/dma_pack.sv $(ROOT)/rtl/telem.sv $(ROOT)/rtl/x1100/md_rx_top_x1100.sv" \
		TOPLEVEL=md_rx_top_x1100 \
		MODULE=test_md_rx_top_x1100 \
		COCOTB_TOPLEVEL=md_rx_top_x1100 \
		COCOTB_TEST_MODULES=test_md_rx_top_x1100 \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/md_rx_top_x1100

# L0 book_engine unit tests (ENABLE_BOOK path exercised at unit level)
sim-book: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(BOOK_RTL)" \
		TOPLEVEL=book_engine \
		MODULE=test_book_engine \
		COCOTB_TOPLEVEL=book_engine \
		COCOTB_TEST_MODULES=test_book_engine \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/book_engine

# x1100 with ENABLE_BOOK=1 + book-focused TB
sim-x1100-book: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/x1100/ndpp_pkg.sv $(ROOT)/rtl/udp_strip.sv $(ROOT)/rtl/dec_bin_generic.sv $(ROOT)/rtl/dec_szse_bin.sv $(ROOT)/rtl/arb_nway.sv $(ROOT)/rtl/sym_cam.sv $(BOOK_RTL) $(ROOT)/rtl/mcast_eng.sv $(ROOT)/rtl/dma_pack.sv $(ROOT)/rtl/telem.sv $(ROOT)/rtl/x1100/md_rx_top_x1100.sv" \
		TOPLEVEL=md_rx_top_x1100 \
		MODULE=test_md_rx_top_x1100_book \
		COCOTB_TOPLEVEL=md_rx_top_x1100 \
		COCOTB_TEST_MODULES=test_md_rx_top_x1100_book \
		EXTRA_ARGS="$(EXTRA_ARGS) -GENABLE_BOOK=1" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/md_rx_top_x1100_book


# L1 DDR engine + axi_ddr_model (tb_l1)
L1_RTL := $(ROOT)/rtl/md_pkg.sv $(ROOT)/rtl/book_pkg.sv $(ROOT)/rtl/l1_ddr_engine.sv $(ROOT)/rtl/sim/axi_ddr_model.sv $(ROOT)/tb_l1/tb_l1_top.sv

.PHONY: sim-l1
sim-l1: venv
	$(MAKE) -f $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(L1_RTL)" \
		TOPLEVEL=tb_l1_top \
		MODULE=test_l1_add_cxl_trade,test_l1_bank_parallel,test_l1_drop_when_full \
		COCOTB_TOPLEVEL=tb_l1_top \
		COCOTB_TEST_MODULES=test_l1_add_cxl_trade,test_l1_bank_parallel,test_l1_drop_when_full \
		EXTRA_ARGS="$(EXTRA_ARGS)" \
		VERILATOR_TRACE=$(VERILATOR_TRACE) \
		VERILATOR_BIN_DIR=$(VERILATOR_BIN_DIR) \
		PYTHON_BIN=$(PYTHON) \
		SIM_BUILD=$(ROOT)/sim_build/l1_ddr

.PHONY: clean
clean:
	rm -rf sim_build results.xml dump.fst dump.vcd __pycache__ tb/__pycache__ tb_x1100/__pycache__ tb_l1/__pycache__

.PHONY: help
help:
	@echo "make sim          - run all unit + top integration tests"
	@echo "make sim-udp      - udp_strip only"
	@echo "make sim-dec      - dec_szse_bin only"
	@echo "make sim-dec-sse  - dec_sse_bin only"
	@echo "make sim-dec-fast - dec_sse_fast only"
	@echo "make sim-arb      - arb_nway only"
	@echo "make sim-cam      - sym_cam only"
	@echo "make sim-mcast    - mcast_eng only"
	@echo "make sim-dma      - dma_pack only"
	@echo "make sim-top      - md_rx_top integration"
	@echo "make sim-x1100    - md_rx_top_x1100 32b SZSE A/B (ENABLE_BOOK=0)"
	@echo "make sim-book     - book_engine L0 unit tests"
	@echo "make sim-x1100-book - x1100 with ENABLE_BOOK=1"
	@echo "make sim-l1        - L1 DDR engine (axi model) tests"
	@echo "make sim WAVES=1  - run with FST waveform dump"
	@echo "make clean        - remove build artefacts"
