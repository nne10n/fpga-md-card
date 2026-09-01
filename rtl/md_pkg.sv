// -----------------------------------------------------------------------------
// md_pkg.sv — 券商 FPGA 行情卡 v1 共享类型（架构契约）
//
// 线侧 AXIS：64-bit，首字节在 tdata[7:0]（与 fpga-order-tcp-tx 相同）
// 热路径时钟：322.265625 MHz 单域（仿真可用任意周期，按 3.103 ns/拍估延迟）
// event 总线：512-bit 单 beat / 消息，II=1
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package md_pkg;

  localparam int AXIS_W      = 64;
  localparam int AXIS_KEEP_W = AXIS_W / 8;
  localparam int EVENT_W     = 512;
  localparam int N_INGRESS   = 8;
  localparam int N_CLIENT    = 16;
  localparam int CAM_DEPTH   = 8192;
  localparam int CAM_AW      = 13;
  localparam int CLIENT_FILT = 1024;

  localparam int P_SSE_A    = 0;
  localparam int P_SSE_B    = 1;
  localparam int P_SZSE_A   = 2;
  localparam int P_SZSE_B   = 3;
  localparam int P_SSE_TCP  = 4;
  localparam int P_SZSE_TCP = 5;
  localparam int P_FUT_A    = 6;
  localparam int P_FUT_B    = 7;

  typedef enum logic [1:0] {
    EXCH_SSE  = 2'd0,
    EXCH_SZSE = 2'd1,
    EXCH_RSVD = 2'd3
  } exch_e;

  typedef enum logic [3:0] {
    CH_SNAP  = 4'd0,
    CH_ORDER = 4'd1,
    CH_TRADE = 4'd2,
    CH_INDEX = 4'd3,
    CH_QUEUE = 4'd4,
    CH_STATE = 4'd5,
    CH_OTHER = 4'd15
  } ch_e;

  localparam logic [7:0] F_WINNER_B = 8'h01;
  localparam logic [7:0] F_GAP      = 8'h02;
  localparam logic [7:0] F_FCS_LATE = 8'h04;
  localparam logic [7:0] F_CAM_MISS = 8'h08;
  localparam logic [7:0] F_FROM_TCP = 8'h10;

  // packed struct 高位在前：pad 在 [511:328]
  typedef struct packed {
    logic [183:0] pad;
    logic [15:0]  raw_ptr;
    logic [7:0]   queue_pos;
    logic [7:0]   level;
    logic [63:0]  order_id;
    logic [1:0]   side;
    logic [31:0]  qty;
    logic [63:0]  px;
    logic [7:0]   flags;
    logic [7:0]   msg_type;
    logic [3:0]   ch;
    logic [1:0]   exch;
    logic [15:0]  symbol_id;
    logic [31:0]  seq;
    logic [63:0]  ts_ns;
  } event_t;

  typedef struct packed {
    logic [2:0]  port_id;
    logic [63:0] sop_ts;
  } eth_tuser_t;

  typedef struct packed {
    logic [2:0]  port_id;
    logic [63:0] sop_ts;
    logic [15:0] udp_dport;
    logic [7:0]  l4_prot;
    logic        from_tcp;
  } pay_tuser_t;

endpackage
