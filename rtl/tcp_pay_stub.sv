// -----------------------------------------------------------------------------
// tcp_pay_stub.sv — Pass-through AXIS; stamp pay_tuser from_tcp=1, l4_prot=6
// Used for Q0.4/Q0.5 TB injection (optional if top does not wire TCP yet).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tcp_pay_stub
  import md_pkg::*;
#(
  parameter logic [2:0] PORT_ID = 3'd4
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,
  input  logic [63:0] s_sop_ts,       // SOP timestamp from TB/top
  input  logic [15:0] s_udp_dport,    // channel hint (reuse field)

  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,
  output pay_tuser_t  m_axis_tuser
);

  // Cut-through: ready when downstream ready (or always-1 for hot path style)
  assign s_axis_tready = m_axis_tready;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tkeep  = s_axis_tkeep;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tlast  = s_axis_tlast;

  pay_tuser_t tu;
  always_comb begin
    tu           = '0;
    tu.port_id   = PORT_ID;
    tu.sop_ts    = s_sop_ts;
    tu.udp_dport = s_udp_dport;
    tu.l4_prot   = 8'd6;
    tu.from_tcp  = 1'b1;
  end
  assign m_axis_tuser = tu;

  logic unused;
  assign unused = clk ^ rst_n; // keep ports; combo path needs no flops

endmodule
