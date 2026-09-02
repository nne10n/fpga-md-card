// -----------------------------------------------------------------------------
// ndpp_pkg.sv — Yusur NDPP X1100 适配假设（2×10G, 32b @ 322MHz, 深市）
// event_t 仍来自 md_pkg，勿改字段布局
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package ndpp_pkg;
  import md_pkg::*;

  localparam int NDPP_AXIS_W      = 32;
  localparam int NDPP_AXIS_KEEP_W = NDPP_AXIS_W / 8;
  localparam int NDPP_N_PORT      = 2;
  localparam int NDPP_P_A         = 0;
  localparam int NDPP_P_B         = 1;

  localparam exch_e NDPP_EXCH     = EXCH_SZSE;

endpackage
