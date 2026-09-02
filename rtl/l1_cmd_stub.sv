// -----------------------------------------------------------------------------
// l1_cmd_stub.sv — L1 command sink (no AXI / no DDR)
// Always ready; counts pushes. Optional shallow FIFO for observability.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module l1_cmd_stub
  import md_pkg::*;
  import book_pkg::*;
#(
  parameter int FIFO_DEPTH = 16
) (
  input  logic     clk,
  input  logic     rst_n,

  input  logic     clear,

  input  l1_cmd_t  s_cmd,
  input  logic     s_valid,
  output logic     s_ready,   // always 1

  output logic [31:0] push_cnt,
  output logic [31:0] drop_cnt, // reserved (stub never drops while ready=1)

  // Peek last accepted command
  output l1_cmd_t  last_cmd,
  output logic     last_valid
);

  assign s_ready = 1'b1;

  logic [31:0] push_q, drop_q;
  l1_cmd_t     last_q;
  logic        last_v_q;

  assign push_cnt  = push_q;
  assign drop_cnt  = drop_q;
  assign last_cmd  = last_q;
  assign last_valid = last_v_q;

  // Tiny FIFO (optional observability; not required by handoff)
  localparam int AW = $clog2(FIFO_DEPTH);
  l1_cmd_t mem [0:FIFO_DEPTH-1];
  logic [AW:0] wr_ptr, rd_ptr; // extra bit for full/empty
  // unused beyond count — keep for future L1 hookup

  integer i;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      push_q   <= '0;
      drop_q   <= '0;
      last_q   <= '0;
      last_v_q <= 1'b0;
      wr_ptr   <= '0;
      rd_ptr   <= '0;
      for (i = 0; i < FIFO_DEPTH; i++)
        mem[i] <= '0;
    end else if (clear) begin
      push_q   <= '0;
      drop_q   <= '0;
      last_v_q <= 1'b0;
      wr_ptr   <= '0;
      rd_ptr   <= '0;
    end else if (s_valid) begin
      push_q   <= sat_inc(push_q);
      last_q   <= s_cmd;
      last_v_q <= 1'b1;
      mem[wr_ptr[AW-1:0]] <= s_cmd;
      wr_ptr <= wr_ptr + (AW+1)'(1);
    end
  end

  logic unused_rd;
  assign unused_rd = |rd_ptr;

endmodule
