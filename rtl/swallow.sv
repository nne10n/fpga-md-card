// -----------------------------------------------------------------------------
// swallow.sv — Count and drop ingress frames (futures ports Q0.6/Q0.7)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module swallow
  import md_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,
  input  eth_tuser_t  s_axis_tuser,

  output logic [31:0] frames_seen
);

  assign s_axis_tready = 1'b1;

  logic unused;
  assign unused = ^{s_axis_tdata, s_axis_tkeep, s_axis_tuser};

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  logic [31:0] c_q;
  assign frames_seen = c_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      c_q <= '0;
    else if (s_axis_tvalid && s_axis_tlast)
      c_q <= sat_inc(c_q);
  end

endmodule
