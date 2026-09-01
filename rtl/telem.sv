// -----------------------------------------------------------------------------
// telem.sv — Thin telemetry aggregator (M8 minimal)
// Saturating OR of key submodule counters exposed as readable outputs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module telem
  import md_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Strip aggregates (sum of ports)
  input  logic [31:0] strip_frames_ok,
  input  logic [31:0] strip_drop,

  // Decode
  input  logic [31:0] dec_msg_ok,
  input  logic [31:0] dec_msg_bad,

  // Arb
  input  logic [31:0] arb_fwd,
  input  logic [31:0] arb_drop_dup,

  // CAM
  input  logic [31:0] cam_hit,
  input  logic [31:0] cam_miss,

  // Egress
  input  logic [31:0] mcast_tx,
  input  logic [31:0] dma_tx,

  output logic [31:0] frames_ok,
  output logic [31:0] frames_drop,
  output logic [31:0] msg_ok,
  output logic [31:0] msg_bad,
  output logic [31:0] arb_fwd_c,
  output logic [31:0] arb_dup_c,
  output logic [31:0] cam_hit_c,
  output logic [31:0] cam_miss_c,
  output logic [31:0] mcast_tx_c,
  output logic [31:0] dma_tx_c
);

  // Wire-through (already saturated upstream); register for clean CSR read
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      frames_ok   <= '0;
      frames_drop <= '0;
      msg_ok      <= '0;
      msg_bad     <= '0;
      arb_fwd_c   <= '0;
      arb_dup_c   <= '0;
      cam_hit_c   <= '0;
      cam_miss_c  <= '0;
      mcast_tx_c  <= '0;
      dma_tx_c    <= '0;
    end else begin
      frames_ok   <= strip_frames_ok;
      frames_drop <= strip_drop;
      msg_ok      <= dec_msg_ok;
      msg_bad     <= dec_msg_bad;
      arb_fwd_c   <= arb_fwd;
      arb_dup_c   <= arb_drop_dup;
      cam_hit_c   <= cam_hit;
      cam_miss_c  <= cam_miss;
      mcast_tx_c  <= mcast_tx;
      dma_tx_c    <= dma_tx;
    end
  end

endmodule
