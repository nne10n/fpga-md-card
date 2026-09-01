// -----------------------------------------------------------------------------
// md_rx_top.sv — Full hot-path top (M8/M9)
//
// Ports 0/1 → SSE Binary or FAST (A/B) via cfg_sse_is_fast (default 0=Binary);
// ports 2/3 → SZSE Binary (A/B).
// Hierarchy: strip → dec → arb (per exch) → event_merge → sym_cam →
//            mcast_eng(N=1) + dma_pack. TCP/futures optional stubs.
// Code sideband [47:0] travels with events through arb/merge into CAM.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module md_rx_top
  import md_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,

  // ---- shared strip filter (all 4 UDP ports) ----
  input  logic [47:0]  cfg_dst_mac,
  input  logic [31:0]  cfg_dst_ip,
  input  logic [15:0]  cfg_udp_dport,

  // ---- SZSE decoder field offsets ----
  input  logic [7:0]   cfg_szse_off_type,
  input  logic [7:0]   cfg_szse_off_seq,
  input  logic [7:0]   cfg_szse_off_code,
  input  logic [7:0]   cfg_szse_off_px,
  input  logic [7:0]   cfg_szse_off_qty,
  input  logic [7:0]   cfg_szse_off_side,
  input  logic [7:0]   cfg_szse_off_oid,
  input  logic [7:0]   cfg_szse_len_hdr,
  input  logic [63:0]  cfg_szse_type_lut,
  input  logic [7:0]   cfg_szse_off_ch_hint,

  // ---- SSE decoder field offsets ----
  input  logic [7:0]   cfg_sse_off_type,
  input  logic [7:0]   cfg_sse_off_seq,
  input  logic [7:0]   cfg_sse_off_code,
  input  logic [7:0]   cfg_sse_off_px,
  input  logic [7:0]   cfg_sse_off_qty,
  input  logic [7:0]   cfg_sse_off_side,
  input  logic [7:0]   cfg_sse_off_oid,
  input  logic [7:0]   cfg_sse_len_hdr,
  input  logic [63:0]  cfg_sse_type_lut,
  input  logic [7:0]   cfg_sse_off_ch_hint,
  input  logic         cfg_sse_is_fast,   // 1 → ports 0/1 use dec_sse_fast; 0 → Binary

  // ---- CAM ----
  input  logic         cfg_pass_miss,
  input  logic         cam_we,
  input  logic [12:0]  cam_addr,
  input  logic [55:0]  cam_key,
  input  logic [15:0]  cam_id,
  input  logic         cam_entry_valid,
  input  logic         cam_swap,
  output logic         cam_bank_sel,

  // ---- mcast_eng ----
  input  logic [47:0]  cfg_mcast_src_mac,
  input  logic [47:0]  cfg_mcast_dst_mac,
  input  logic [31:0]  cfg_mcast_src_ip,
  input  logic [31:0]  cfg_mcast_dst_ip,
  input  logic [15:0]  cfg_mcast_udp_sport,
  input  logic [15:0]  cfg_mcast_udp_dport,
  input  logic [7:0]   cfg_ch_mask,
  input  logic [15:0]  cfg_mcast_period,
  input  logic [15:0]  cfg_mcast_refill,
  input  logic         filt_we,
  input  logic [12:0]  filt_addr,
  input  logic         filt_bit,

  // ---- 4 eth ingress (SSE_A, SSE_B, SZSE_A, SZSE_B) ----
  input  logic [63:0]  s0_tdata,
  input  logic [7:0]   s0_tkeep,
  input  logic         s0_tvalid,
  input  logic         s0_tlast,
  output logic         s0_tready,
  input  eth_tuser_t   s0_tuser,

  input  logic [63:0]  s1_tdata,
  input  logic [7:0]   s1_tkeep,
  input  logic         s1_tvalid,
  input  logic         s1_tlast,
  output logic         s1_tready,
  input  eth_tuser_t   s1_tuser,

  input  logic [63:0]  s2_tdata,
  input  logic [7:0]   s2_tkeep,
  input  logic         s2_tvalid,
  input  logic         s2_tlast,
  output logic         s2_tready,
  input  eth_tuser_t   s2_tuser,

  input  logic [63:0]  s3_tdata,
  input  logic [7:0]   s3_tkeep,
  input  logic         s3_tvalid,
  input  logic         s3_tlast,
  output logic         s3_tready,
  input  eth_tuser_t   s3_tuser,

  // ---- egress ----
  output logic [63:0]  m_mcast_tdata,
  output logic [7:0]   m_mcast_tkeep,
  output logic         m_mcast_tvalid,
  output logic         m_mcast_tlast,
  input  logic         m_mcast_tready,

  output logic [63:0]  m_dma_tdata,
  output logic [7:0]   m_dma_tkeep,
  output logic         m_dma_tvalid,
  output logic         m_dma_tlast,
  input  logic         m_dma_tready,

  // ---- telem ----
  output logic [31:0]  telem_frames_ok,
  output logic [31:0]  telem_frames_drop,
  output logic [31:0]  telem_msg_ok,
  output logic [31:0]  telem_msg_bad,
  output logic [31:0]  telem_arb_fwd,
  output logic [31:0]  telem_arb_dup,
  output logic [31:0]  telem_cam_hit,
  output logic [31:0]  telem_cam_miss,
  output logic [31:0]  telem_mcast_tx,
  output logic [31:0]  telem_dma_tx
);

  // =========================================================================
  // Strip ×4
  // =========================================================================
  logic [63:0] pay_tdata  [0:3];
  logic [7:0]  pay_tkeep  [0:3];
  logic        pay_tvalid [0:3];
  logic        pay_tlast  [0:3];
  logic        pay_tready [0:3];
  pay_tuser_t  pay_tuser  [0:3];

  logic [31:0] st_ok   [0:3];
  logic [31:0] st_nudp [0:3];
  logic [31:0] st_opt  [0:3];
  logic [31:0] st_filt [0:3];

  // Force port_id in tuser at strip input (TB may set any; top overrides)
  eth_tuser_t s0_tu_fix, s1_tu_fix, s2_tu_fix, s3_tu_fix;
  always_comb begin
    s0_tu_fix = s0_tuser; s0_tu_fix.port_id = 3'(P_SSE_A);
    s1_tu_fix = s1_tuser; s1_tu_fix.port_id = 3'(P_SSE_B);
    s2_tu_fix = s2_tuser; s2_tu_fix.port_id = 3'(P_SZSE_A);
    s3_tu_fix = s3_tuser; s3_tu_fix.port_id = 3'(P_SZSE_B);
  end

  udp_strip u_strip0 (
    .clk(clk), .rst_n(rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_dst_ip(cfg_dst_ip), .cfg_udp_dport(cfg_udp_dport),
    .s_axis_tdata(s0_tdata), .s_axis_tkeep(s0_tkeep), .s_axis_tvalid(s0_tvalid),
    .s_axis_tlast(s0_tlast), .s_axis_tready(s0_tready), .s_axis_tuser(s0_tu_fix),
    .m_axis_tdata(pay_tdata[0]), .m_axis_tkeep(pay_tkeep[0]), .m_axis_tvalid(pay_tvalid[0]),
    .m_axis_tlast(pay_tlast[0]), .m_axis_tready(pay_tready[0]), .m_axis_tuser(pay_tuser[0]),
    .drop_not_udp(st_nudp[0]), .drop_opt(st_opt[0]), .drop_filter(st_filt[0]), .frames_ok(st_ok[0])
  );
  udp_strip u_strip1 (
    .clk(clk), .rst_n(rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_dst_ip(cfg_dst_ip), .cfg_udp_dport(cfg_udp_dport),
    .s_axis_tdata(s1_tdata), .s_axis_tkeep(s1_tkeep), .s_axis_tvalid(s1_tvalid),
    .s_axis_tlast(s1_tlast), .s_axis_tready(s1_tready), .s_axis_tuser(s1_tu_fix),
    .m_axis_tdata(pay_tdata[1]), .m_axis_tkeep(pay_tkeep[1]), .m_axis_tvalid(pay_tvalid[1]),
    .m_axis_tlast(pay_tlast[1]), .m_axis_tready(pay_tready[1]), .m_axis_tuser(pay_tuser[1]),
    .drop_not_udp(st_nudp[1]), .drop_opt(st_opt[1]), .drop_filter(st_filt[1]), .frames_ok(st_ok[1])
  );
  udp_strip u_strip2 (
    .clk(clk), .rst_n(rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_dst_ip(cfg_dst_ip), .cfg_udp_dport(cfg_udp_dport),
    .s_axis_tdata(s2_tdata), .s_axis_tkeep(s2_tkeep), .s_axis_tvalid(s2_tvalid),
    .s_axis_tlast(s2_tlast), .s_axis_tready(s2_tready), .s_axis_tuser(s2_tu_fix),
    .m_axis_tdata(pay_tdata[2]), .m_axis_tkeep(pay_tkeep[2]), .m_axis_tvalid(pay_tvalid[2]),
    .m_axis_tlast(pay_tlast[2]), .m_axis_tready(pay_tready[2]), .m_axis_tuser(pay_tuser[2]),
    .drop_not_udp(st_nudp[2]), .drop_opt(st_opt[2]), .drop_filter(st_filt[2]), .frames_ok(st_ok[2])
  );
  udp_strip u_strip3 (
    .clk(clk), .rst_n(rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_dst_ip(cfg_dst_ip), .cfg_udp_dport(cfg_udp_dport),
    .s_axis_tdata(s3_tdata), .s_axis_tkeep(s3_tkeep), .s_axis_tvalid(s3_tvalid),
    .s_axis_tlast(s3_tlast), .s_axis_tready(s3_tready), .s_axis_tuser(s3_tu_fix),
    .m_axis_tdata(pay_tdata[3]), .m_axis_tkeep(pay_tkeep[3]), .m_axis_tvalid(pay_tvalid[3]),
    .m_axis_tlast(pay_tlast[3]), .m_axis_tready(pay_tready[3]), .m_axis_tuser(pay_tuser[3]),
    .drop_not_udp(st_nudp[3]), .drop_opt(st_opt[3]), .drop_filter(st_filt[3]), .frames_ok(st_ok[3])
  );

  // =========================================================================
  // Decoders: 0/1 SSE, 2/3 SZSE
  // =========================================================================
  logic [511:0] dec_tdata  [0:3];
  logic         dec_tvalid [0:3];
  logic         dec_tlast  [0:3];
  logic         dec_tready [0:3];
  logic [47:0]  dec_code   [0:3];
  logic [31:0]  dec_ok     [0:3];
  logic [31:0]  dec_bad    [0:3];

  // SSE A/B: Binary + FAST (mux by cfg_sse_is_fast; default Binary)
  logic [511:0] bin_tdata  [0:1], fast_tdata  [0:1];
  logic         bin_tvalid [0:1], fast_tvalid [0:1];
  logic         bin_tlast  [0:1], fast_tlast  [0:1];
  logic         bin_tready [0:1], fast_tready [0:1];
  logic [47:0]  bin_code   [0:1], fast_code   [0:1];
  logic [31:0]  bin_ok     [0:1], fast_ok     [0:1];
  logic [31:0]  bin_bad    [0:1], fast_bad    [0:1];
  logic         bin_s_rdy  [0:1], fast_s_rdy  [0:1];

  logic pay_v_bin  [0:1];
  logic pay_v_fast [0:1];
  assign pay_v_bin[0]  = pay_tvalid[0] & ~cfg_sse_is_fast;
  assign pay_v_bin[1]  = pay_tvalid[1] & ~cfg_sse_is_fast;
  assign pay_v_fast[0] = pay_tvalid[0] &  cfg_sse_is_fast;
  assign pay_v_fast[1] = pay_tvalid[1] &  cfg_sse_is_fast;
  assign pay_tready[0] = cfg_sse_is_fast ? fast_s_rdy[0] : bin_s_rdy[0];
  assign pay_tready[1] = cfg_sse_is_fast ? fast_s_rdy[1] : bin_s_rdy[1];

  dec_sse_bin u_dec_sse_a (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_sse_off_type), .cfg_off_seq(cfg_sse_off_seq),
    .cfg_off_code(cfg_sse_off_code), .cfg_off_px(cfg_sse_off_px),
    .cfg_off_qty(cfg_sse_off_qty), .cfg_off_side(cfg_sse_off_side),
    .cfg_off_oid(cfg_sse_off_oid), .cfg_len_hdr(cfg_sse_len_hdr),
    .cfg_type_lut(cfg_sse_type_lut), .cfg_off_ch_hint(cfg_sse_off_ch_hint),
    .s_axis_tdata(pay_tdata[0]), .s_axis_tkeep(pay_tkeep[0]),
    .s_axis_tvalid(pay_v_bin[0]), .s_axis_tlast(pay_tlast[0]),
    .s_axis_tready(bin_s_rdy[0]), .s_axis_tuser(pay_tuser[0]),
    .m_event_tdata(bin_tdata[0]), .m_event_tvalid(bin_tvalid[0]),
    .m_event_tlast(bin_tlast[0]), .m_event_tready(bin_tready[0]),
    .m_code(bin_code[0]), .msg_ok(bin_ok[0]), .msg_bad(bin_bad[0])
  );
  dec_sse_bin u_dec_sse_b (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_sse_off_type), .cfg_off_seq(cfg_sse_off_seq),
    .cfg_off_code(cfg_sse_off_code), .cfg_off_px(cfg_sse_off_px),
    .cfg_off_qty(cfg_sse_off_qty), .cfg_off_side(cfg_sse_off_side),
    .cfg_off_oid(cfg_sse_off_oid), .cfg_len_hdr(cfg_sse_len_hdr),
    .cfg_type_lut(cfg_sse_type_lut), .cfg_off_ch_hint(cfg_sse_off_ch_hint),
    .s_axis_tdata(pay_tdata[1]), .s_axis_tkeep(pay_tkeep[1]),
    .s_axis_tvalid(pay_v_bin[1]), .s_axis_tlast(pay_tlast[1]),
    .s_axis_tready(bin_s_rdy[1]), .s_axis_tuser(pay_tuser[1]),
    .m_event_tdata(bin_tdata[1]), .m_event_tvalid(bin_tvalid[1]),
    .m_event_tlast(bin_tlast[1]), .m_event_tready(bin_tready[1]),
    .m_code(bin_code[1]), .msg_ok(bin_ok[1]), .msg_bad(bin_bad[1])
  );
  dec_sse_fast u_dec_sse_fast_a (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(pay_tdata[0]), .s_axis_tkeep(pay_tkeep[0]),
    .s_axis_tvalid(pay_v_fast[0]), .s_axis_tlast(pay_tlast[0]),
    .s_axis_tready(fast_s_rdy[0]), .s_axis_tuser(pay_tuser[0]),
    .m_event_tdata(fast_tdata[0]), .m_event_tvalid(fast_tvalid[0]),
    .m_event_tlast(fast_tlast[0]), .m_event_tready(fast_tready[0]),
    .m_code(fast_code[0]), .msg_ok(fast_ok[0]), .msg_bad(fast_bad[0])
  );
  dec_sse_fast u_dec_sse_fast_b (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(pay_tdata[1]), .s_axis_tkeep(pay_tkeep[1]),
    .s_axis_tvalid(pay_v_fast[1]), .s_axis_tlast(pay_tlast[1]),
    .s_axis_tready(fast_s_rdy[1]), .s_axis_tuser(pay_tuser[1]),
    .m_event_tdata(fast_tdata[1]), .m_event_tvalid(fast_tvalid[1]),
    .m_event_tlast(fast_tlast[1]), .m_event_tready(fast_tready[1]),
    .m_code(fast_code[1]), .msg_ok(fast_ok[1]), .msg_bad(fast_bad[1])
  );

  // Output mux + ready fanout
  assign dec_tdata[0]  = cfg_sse_is_fast ? fast_tdata[0]  : bin_tdata[0];
  assign dec_tdata[1]  = cfg_sse_is_fast ? fast_tdata[1]  : bin_tdata[1];
  assign dec_tvalid[0] = cfg_sse_is_fast ? fast_tvalid[0] : bin_tvalid[0];
  assign dec_tvalid[1] = cfg_sse_is_fast ? fast_tvalid[1] : bin_tvalid[1];
  assign dec_tlast[0]  = cfg_sse_is_fast ? fast_tlast[0]  : bin_tlast[0];
  assign dec_tlast[1]  = cfg_sse_is_fast ? fast_tlast[1]  : bin_tlast[1];
  assign dec_code[0]   = cfg_sse_is_fast ? fast_code[0]   : bin_code[0];
  assign dec_code[1]   = cfg_sse_is_fast ? fast_code[1]   : bin_code[1];
  assign dec_ok[0]     = cfg_sse_is_fast ? fast_ok[0]     : bin_ok[0];
  assign dec_ok[1]     = cfg_sse_is_fast ? fast_ok[1]     : bin_ok[1];
  assign dec_bad[0]    = cfg_sse_is_fast ? fast_bad[0]    : bin_bad[0];
  assign dec_bad[1]    = cfg_sse_is_fast ? fast_bad[1]    : bin_bad[1];
  assign bin_tready[0]  = dec_tready[0] & ~cfg_sse_is_fast;
  assign bin_tready[1]  = dec_tready[1] & ~cfg_sse_is_fast;
  assign fast_tready[0] = dec_tready[0] &  cfg_sse_is_fast;
  assign fast_tready[1] = dec_tready[1] &  cfg_sse_is_fast;
  dec_szse_bin u_dec_szse_a (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_szse_off_type), .cfg_off_seq(cfg_szse_off_seq),
    .cfg_off_code(cfg_szse_off_code), .cfg_off_px(cfg_szse_off_px),
    .cfg_off_qty(cfg_szse_off_qty), .cfg_off_side(cfg_szse_off_side),
    .cfg_off_oid(cfg_szse_off_oid), .cfg_len_hdr(cfg_szse_len_hdr),
    .cfg_type_lut(cfg_szse_type_lut), .cfg_off_ch_hint(cfg_szse_off_ch_hint),
    .s_axis_tdata(pay_tdata[2]), .s_axis_tkeep(pay_tkeep[2]),
    .s_axis_tvalid(pay_tvalid[2]), .s_axis_tlast(pay_tlast[2]),
    .s_axis_tready(pay_tready[2]), .s_axis_tuser(pay_tuser[2]),
    .m_event_tdata(dec_tdata[2]), .m_event_tvalid(dec_tvalid[2]),
    .m_event_tlast(dec_tlast[2]), .m_event_tready(dec_tready[2]),
    .m_code(dec_code[2]), .msg_ok(dec_ok[2]), .msg_bad(dec_bad[2])
  );
  dec_szse_bin u_dec_szse_b (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_szse_off_type), .cfg_off_seq(cfg_szse_off_seq),
    .cfg_off_code(cfg_szse_off_code), .cfg_off_px(cfg_szse_off_px),
    .cfg_off_qty(cfg_szse_off_qty), .cfg_off_side(cfg_szse_off_side),
    .cfg_off_oid(cfg_szse_off_oid), .cfg_len_hdr(cfg_szse_len_hdr),
    .cfg_type_lut(cfg_szse_type_lut), .cfg_off_ch_hint(cfg_szse_off_ch_hint),
    .s_axis_tdata(pay_tdata[3]), .s_axis_tkeep(pay_tkeep[3]),
    .s_axis_tvalid(pay_tvalid[3]), .s_axis_tlast(pay_tlast[3]),
    .s_axis_tready(pay_tready[3]), .s_axis_tuser(pay_tuser[3]),
    .m_event_tdata(dec_tdata[3]), .m_event_tvalid(dec_tvalid[3]),
    .m_event_tlast(dec_tlast[3]), .m_event_tready(dec_tready[3]),
    .m_code(dec_code[3]), .msg_ok(dec_ok[3]), .msg_bad(dec_bad[3])
  );

  // =========================================================================
  // Arb per exchange (TCP tied off). FAST ifdef off → no third merge source.
  // =========================================================================
  logic         arb_sse_tcp_rdy, arb_szse_tcp_rdy, merge_s2_rdy;
  logic [511:0] arb_sse_tdata, arb_szse_tdata;
  logic         arb_sse_tvalid, arb_szse_tvalid;
  logic         arb_sse_tlast,  arb_szse_tlast;
  logic         arb_sse_tready, arb_szse_tready;
  logic [47:0]  arb_sse_code,   arb_szse_code;
  logic [31:0]  arb_sse_fwd, arb_sse_dup, arb_sse_dtcp, arb_sse_gap;
  logic [31:0]  arb_szse_fwd, arb_szse_dup, arb_szse_dtcp, arb_szse_gap;

  arb_nway u_arb_sse (
    .clk(clk), .rst_n(rst_n),
    .s_a_tdata(dec_tdata[0]), .s_a_tvalid(dec_tvalid[0]), .s_a_tlast(dec_tlast[0]),
    .s_a_tready(dec_tready[0]), .s_a_code(dec_code[0]),
    .s_b_tdata(dec_tdata[1]), .s_b_tvalid(dec_tvalid[1]), .s_b_tlast(dec_tlast[1]),
    .s_b_tready(dec_tready[1]), .s_b_code(dec_code[1]),
    .s_tcp_tdata('0), .s_tcp_tvalid(1'b0), .s_tcp_tlast(1'b0),
    .s_tcp_tready(arb_sse_tcp_rdy), .s_tcp_code('0),
    .m_event_tdata(arb_sse_tdata), .m_event_tvalid(arb_sse_tvalid),
    .m_event_tlast(arb_sse_tlast), .m_event_tready(arb_sse_tready),
    .m_code(arb_sse_code),
    .fwd(arb_sse_fwd), .drop_dup(arb_sse_dup), .drop_tcp(arb_sse_dtcp), .gap(arb_sse_gap)
  );

  arb_nway u_arb_szse (
    .clk(clk), .rst_n(rst_n),
    .s_a_tdata(dec_tdata[2]), .s_a_tvalid(dec_tvalid[2]), .s_a_tlast(dec_tlast[2]),
    .s_a_tready(dec_tready[2]), .s_a_code(dec_code[2]),
    .s_b_tdata(dec_tdata[3]), .s_b_tvalid(dec_tvalid[3]), .s_b_tlast(dec_tlast[3]),
    .s_b_tready(dec_tready[3]), .s_b_code(dec_code[3]),
    .s_tcp_tdata('0), .s_tcp_tvalid(1'b0), .s_tcp_tlast(1'b0),
    .s_tcp_tready(arb_szse_tcp_rdy), .s_tcp_code('0),
    .m_event_tdata(arb_szse_tdata), .m_event_tvalid(arb_szse_tvalid),
    .m_event_tlast(arb_szse_tlast), .m_event_tready(arb_szse_tready),
    .m_code(arb_szse_code),
    .fwd(arb_szse_fwd), .drop_dup(arb_szse_dup), .drop_tcp(arb_szse_dtcp), .gap(arb_szse_gap)
  );

  // =========================================================================
  // event_merge: SSE + SZSE + tied-off third (FAST)
  // =========================================================================
  logic [511:0] merg_tdata;
  logic         merg_tvalid, merg_tlast, merg_tready;
  logic [47:0]  merg_code;

  event_merge u_merge (
    .clk(clk), .rst_n(rst_n),
    .s0_tdata(arb_sse_tdata), .s0_tvalid(arb_sse_tvalid), .s0_tlast(arb_sse_tlast),
    .s0_tready(arb_sse_tready), .s0_code(arb_sse_code),
    .s1_tdata(arb_szse_tdata), .s1_tvalid(arb_szse_tvalid), .s1_tlast(arb_szse_tlast),
    .s1_tready(arb_szse_tready), .s1_code(arb_szse_code),
    .s2_tdata('0), .s2_tvalid(1'b0), .s2_tlast(1'b0), .s2_tready(merge_s2_rdy), .s2_code('0),
    .m_event_tdata(merg_tdata), .m_event_tvalid(merg_tvalid),
    .m_event_tlast(merg_tlast), .m_event_tready(merg_tready),
    .m_code(merg_code)
  );

  // =========================================================================
  // sym_cam
  // =========================================================================
  logic [511:0] cam_tdata;
  logic         cam_tvalid, cam_tlast, cam_tready;
  logic [31:0]  cam_hit_c, cam_miss_c, cam_drop_c;

  sym_cam u_cam (
    .clk(clk), .rst_n(rst_n),
    .s_event_tdata(merg_tdata), .s_event_tvalid(merg_tvalid),
    .s_event_tlast(merg_tlast), .s_event_tready(merg_tready),
    .s_code(merg_code),
    .m_event_tdata(cam_tdata), .m_event_tvalid(cam_tvalid),
    .m_event_tlast(cam_tlast), .m_event_tready(cam_tready),
    .cfg_pass_miss(cfg_pass_miss), .bank_sel(cam_bank_sel), .swap(cam_swap),
    .cam_we(cam_we), .cam_addr(cam_addr), .cam_key(cam_key),
    .cam_id(cam_id), .cam_entry_valid(cam_entry_valid),
    .hit(cam_hit_c), .miss(cam_miss_c), .drop_miss(cam_drop_c)
  );

  // =========================================================================
  // event_bus: broadcast to mcast + dma (both tready=1 → AND is free)
  // =========================================================================
  logic mcast_ev_ready, dma_ev_ready;
  assign cam_tready = mcast_ev_ready && dma_ev_ready;

  logic [31:0] mcast_tx_c, mcast_df, mcast_dr;
  logic [31:0] dma_tx_c, dma_df;

  mcast_eng #(.CLIENT_ID(0)) u_mcast (
    .clk(clk), .rst_n(rst_n),
    .s_event_tdata(cam_tdata), .s_event_tvalid(cam_tvalid),
    .s_event_tlast(cam_tlast), .s_event_tready(mcast_ev_ready),
    .m_axis_tdata(m_mcast_tdata), .m_axis_tkeep(m_mcast_tkeep),
    .m_axis_tvalid(m_mcast_tvalid), .m_axis_tlast(m_mcast_tlast),
    .m_axis_tready(m_mcast_tready),
    .cfg_src_mac(cfg_mcast_src_mac), .cfg_dst_mac(cfg_mcast_dst_mac),
    .cfg_src_ip(cfg_mcast_src_ip), .cfg_dst_ip(cfg_mcast_dst_ip),
    .cfg_udp_sport(cfg_mcast_udp_sport), .cfg_udp_dport(cfg_mcast_udp_dport),
    .cfg_ch_mask(cfg_ch_mask), .cfg_period(cfg_mcast_period),
    .cfg_refill(cfg_mcast_refill),
    .filt_we(filt_we), .filt_addr(filt_addr), .filt_bit(filt_bit),
    .tx_ok(mcast_tx_c), .drop_filt(mcast_df), .drop_rate(mcast_dr)
  );

  dma_pack u_dma (
    .clk(clk), .rst_n(rst_n),
    .s_event_tdata(cam_tdata), .s_event_tvalid(cam_tvalid),
    .s_event_tlast(cam_tlast), .s_event_tready(dma_ev_ready),
    .m_axis_tdata(m_dma_tdata), .m_axis_tkeep(m_dma_tkeep),
    .m_axis_tvalid(m_dma_tvalid), .m_axis_tlast(m_dma_tlast),
    .m_axis_tready(m_dma_tready),
    .tx_ok(dma_tx_c), .drop_full(dma_df)
  );

  // =========================================================================
  // telem
  // =========================================================================
  logic [31:0] sum_ok, sum_drop, sum_msg_ok, sum_msg_bad, sum_fwd, sum_dup;
  assign sum_ok      = st_ok[0] + st_ok[1] + st_ok[2] + st_ok[3];
  assign sum_drop    = st_nudp[0]+st_nudp[1]+st_nudp[2]+st_nudp[3]
                     + st_opt[0]+st_opt[1]+st_opt[2]+st_opt[3]
                     + st_filt[0]+st_filt[1]+st_filt[2]+st_filt[3];
  assign sum_msg_ok  = dec_ok[0] + dec_ok[1] + dec_ok[2] + dec_ok[3];
  assign sum_msg_bad = dec_bad[0] + dec_bad[1] + dec_bad[2] + dec_bad[3];
  assign sum_fwd     = arb_sse_fwd + arb_szse_fwd;
  assign sum_dup     = arb_sse_dup + arb_szse_dup;

  telem u_telem (
    .clk(clk), .rst_n(rst_n),
    .strip_frames_ok(sum_ok), .strip_drop(sum_drop),
    .dec_msg_ok(sum_msg_ok), .dec_msg_bad(sum_msg_bad),
    .arb_fwd(sum_fwd), .arb_drop_dup(sum_dup),
    .cam_hit(cam_hit_c), .cam_miss(cam_miss_c),
    .mcast_tx(mcast_tx_c), .dma_tx(dma_tx_c),
    .frames_ok(telem_frames_ok), .frames_drop(telem_frames_drop),
    .msg_ok(telem_msg_ok), .msg_bad(telem_msg_bad),
    .arb_fwd_c(telem_arb_fwd), .arb_dup_c(telem_arb_dup),
    .cam_hit_c(telem_cam_hit), .cam_miss_c(telem_cam_miss),
    .mcast_tx_c(telem_mcast_tx), .dma_tx_c(telem_dma_tx)
  );

  // Silence unused (TCP stub / arb gap counters)
  logic unused_gap;
  assign unused_gap = ^{arb_sse_gap, arb_szse_gap, arb_sse_dtcp, arb_szse_dtcp,
                        cam_drop_c, mcast_df, mcast_dr, dma_df,
                        arb_sse_tcp_rdy, arb_szse_tcp_rdy, merge_s2_rdy};

endmodule
