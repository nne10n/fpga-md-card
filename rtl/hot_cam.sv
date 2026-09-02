// -----------------------------------------------------------------------------
// hot_cam.sv — L0 hot-symbol CAM (N_HOT entries, host-writable)
//
// Lookup key = security code[47:0] (ASCII). Hit → hot_id in 1..N_HOT.
// Combinational scan is fine for N_HOT≤64 at sim / modest clock.
// Upstream never blocked (lookup is sideband / pure function + registered CSR).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module hot_cam
  import md_pkg::*;
  import book_pkg::*;
#(
  parameter int N = N_HOT
) (
  input  logic              clk,
  input  logic              rst_n,

  // Host write: address 0..N-1 → hot_id = addr+1 when valid
  input  logic              hot_we,
  input  logic [HOT_AW-1:0] hot_addr,
  input  logic [47:0]       hot_code,
  input  logic              hot_entry_valid,

  input  logic              clear,   // clear all entries

  // Lookup (combinational)
  input  logic [47:0]       s_code,
  output logic              hit,
  output logic [HOT_AW:0]   hot_id   // 0 = miss; 1..N = hit
);

  logic        mem_v [0:N-1];
  logic [47:0] mem_k [0:N-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N; i++) begin
        mem_v[i] <= 1'b0;
        mem_k[i] <= '0;
      end
    end else if (clear) begin
      for (int i = 0; i < N; i++) begin
        mem_v[i] <= 1'b0;
        mem_k[i] <= '0;
      end
    end else if (hot_we) begin
      mem_v[hot_addr] <= hot_entry_valid;
      mem_k[hot_addr] <= hot_code;
    end
  end

  always_comb begin
    hit    = 1'b0;
    hot_id = '0;
    for (int i = 0; i < N; i++) begin
      if (mem_v[i] && (mem_k[i] == s_code)) begin
        hit    = 1'b1;
        hot_id = HOT_AW'(i) + (HOT_AW+1)'(1);
      end
    end
  end

endmodule
