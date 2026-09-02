// -----------------------------------------------------------------------------
// dec_szse_bin.sv — Thin wrapper: dec_bin_generic with CFG_EXCH=EXCH_SZSE (M2)
// DATA_W = 32|64 (default 64).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module dec_szse_bin
  import md_pkg::*;
#(
  parameter int DATA_W = 64,
  parameter int KEEP_W = DATA_W / 8
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [7:0]   cfg_off_type,
  input  logic [7:0]   cfg_off_seq,
  input  logic [7:0]   cfg_off_code,
  input  logic [7:0]   cfg_off_px,
  input  logic [7:0]   cfg_off_qty,
  input  logic [7:0]   cfg_off_side,
  input  logic [7:0]   cfg_off_oid,
  input  logic [7:0]   cfg_len_hdr,
  input  logic [63:0]  cfg_type_lut,
  input  logic [7:0]   cfg_off_ch_hint,

  input  logic [DATA_W-1:0] s_axis_tdata,
  input  logic [KEEP_W-1:0] s_axis_tkeep,
  input  logic              s_axis_tvalid,
  input  logic              s_axis_tlast,
  output logic              s_axis_tready,
  input  pay_tuser_t        s_axis_tuser,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  logic         m_event_tready,
  output logic [47:0]  m_code,

  output logic [31:0]  msg_ok,
  output logic [31:0]  msg_bad
);

  dec_bin_generic #(
    .CFG_EXCH  (EXCH_SZSE),
    .BUF_BYTES (256),
    .DATA_W    (DATA_W)
  ) u_dec (
    .clk             (clk),
    .rst_n           (rst_n),
    .cfg_off_type    (cfg_off_type),
    .cfg_off_seq     (cfg_off_seq),
    .cfg_off_code    (cfg_off_code),
    .cfg_off_px      (cfg_off_px),
    .cfg_off_qty     (cfg_off_qty),
    .cfg_off_side    (cfg_off_side),
    .cfg_off_oid     (cfg_off_oid),
    .cfg_len_hdr     (cfg_len_hdr),
    .cfg_type_lut    (cfg_type_lut),
    .cfg_off_ch_hint (cfg_off_ch_hint),
    .s_axis_tdata    (s_axis_tdata),
    .s_axis_tkeep    (s_axis_tkeep),
    .s_axis_tvalid   (s_axis_tvalid),
    .s_axis_tlast    (s_axis_tlast),
    .s_axis_tready   (s_axis_tready),
    .s_axis_tuser    (s_axis_tuser),
    .m_event_tdata   (m_event_tdata),
    .m_event_tvalid  (m_event_tvalid),
    .m_event_tlast   (m_event_tlast),
    .m_event_tready  (m_event_tready),
    .m_code          (m_code),
    .msg_ok          (msg_ok),
    .msg_bad         (msg_bad)
  );

endmodule
