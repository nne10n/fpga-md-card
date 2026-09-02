// -----------------------------------------------------------------------------
// book_pkg.sv — L0 hot Top-10 book types (SZSE / X1100)
// Does NOT alter md_pkg::event_t layout.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package book_pkg;
  import md_pkg::*;

  localparam int N_HOT      = 64;
  localparam int N_ORDER    = 4096;
  localparam int ORDER_AW   = 12;   // log2(N_ORDER)
  localparam int N_PROBE    = 4;
  localparam int TOP_N      = 10;
  localparam int HOT_AW     = 6;    // log2(N_HOT)

  // Side encoding (matches SZSE synth / module-design): 1=bid, 2=ask
  localparam logic [1:0] SIDE_BID = 2'd1;
  localparam logic [1:0] SIDE_ASK = 2'd2;

  // Op decode from event (L0 v1 convention for synth + book_engine):
  //   CH_ORDER + msg_type==2 → ADD
  //   CH_ORDER + msg_type==4 → CXL
  //   CH_TRADE               → TRADE
  typedef enum logic [2:0] {
    OP_ADD   = 3'd0,
    OP_CXL   = 3'd1,
    OP_TRADE = 3'd2,
    OP_NOP   = 3'd7
  } book_op_e;

  localparam logic [7:0] MSG_ADD = 8'd2;
  localparam logic [7:0] MSG_CXL = 8'd4;

  typedef struct packed {
    logic        valid;
    logic [63:0] order_id;
    logic [HOT_AW:0] hot_id; // 1..N_HOT (0 = none)
    logic [1:0]  side;
    logic [63:0] px;
    logic [31:0] qty;
  } order_slot_t;

  typedef struct packed {
    logic        valid;
    logic [63:0] px;
    logic [31:0] qty;
  } level_t;

  typedef struct packed {
    book_op_e          op;
    logic [63:0]       order_id;
    logic [HOT_AW:0]   hot_id;     // 0 if non-hot
    logic [47:0]       code;
    logic [1:0]        side;
    logic [63:0]       px;
    logic [31:0]       qty;
    logic [31:0]       seq;
    logic [63:0]       ts_ns;
  } l1_cmd_t;

  // One level change notification (L0 delta)
  typedef struct packed {
    logic              valid;       // payload valid
    logic [HOT_AW:0]   hot_id;
    logic [1:0]        side;
    logic [3:0]        level;       // 0..9
    logic              level_valid; // 0 → slot cleared / empty
    logic [63:0]       px;
    logic [31:0]       qty;
    logic [31:0]       seq;
    logic [63:0]       ts_ns;
    book_op_e          op;
  } book_delta_t;

  function automatic book_op_e decode_book_op(input event_t e);
    if (e.ch == CH_TRADE)
      return OP_TRADE;
    if (e.ch == CH_ORDER) begin
      if (e.msg_type == MSG_CXL)
        return OP_CXL;
      // default ORDER (msg_type==2 or other) → ADD
      return OP_ADD;
    end
    return OP_NOP;
  endfunction

  function automatic logic [ORDER_AW-1:0] hash_oid(input logic [63:0] oid);
    return oid[11:0] ^ oid[23:12] ^ oid[35:24] ^ oid[47:36];
  endfunction

  // Bid: higher px is better; Ask: lower px is better
  function automatic logic px_better(
      input logic [1:0]  side,
      input logic [63:0] a,
      input logic [63:0] b
  );
    if (side == SIDE_BID)
      return a > b;
    else
      return a < b;
  endfunction

  function automatic logic px_worse(
      input logic [1:0]  side,
      input logic [63:0] a,
      input logic [63:0] b
  );
    return px_better(side, b, a);
  endfunction

endpackage
