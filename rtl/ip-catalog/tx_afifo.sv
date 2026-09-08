// -----------------------------------------------------------------------------
// tx_afifo.sv — Catalog wrapper for an async AXIS FIFO (CDC only).
//
// Same-clock engines (including mcast_eng on sys_clk) must not instantiate
// this module. Bind xpm_fifo_async / vendor equivalent at synthesis.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tx_afifo #(
  parameter int DATA_W = 64,
  parameter int KEEP_W = DATA_W / 8,
  parameter int DEPTH  = 16
) (
  input  logic              wr_clk,
  input  logic              wr_rst_n,
  input  logic [DATA_W-1:0] i_wr_tdata,
  input  logic [KEEP_W-1:0] i_wr_tkeep,
  input  logic              i_wr_tvalid,
  input  logic              i_wr_tlast,
  output logic              o_wr_tready,

  input  logic              rd_clk,
  input  logic              rd_rst_n,
  output logic [DATA_W-1:0] o_rd_tdata,
  output logic [KEEP_W-1:0] o_rd_tkeep,
  output logic              o_rd_tvalid,
  output logic              o_rd_tlast,
  input  logic              i_rd_tready
);

  // Stub: not used on the mcast_eng same-clock path.
  assign o_wr_tready = 1'b0;
  assign o_rd_tdata  = '0;
  assign o_rd_tkeep  = '0;
  assign o_rd_tvalid = 1'b0;
  assign o_rd_tlast  = 1'b0;

  logic unused_tie;
  assign unused_tie = wr_clk ^ wr_rst_n ^ rd_clk ^ rd_rst_n ^
                      i_wr_tvalid ^ i_wr_tlast ^ i_rd_tready ^
                      |i_wr_tdata ^ |i_wr_tkeep ^ (DEPTH == 0);

endmodule

`default_nettype wire
