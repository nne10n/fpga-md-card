// -----------------------------------------------------------------------------
// md_rx_top_x1100.sv — Yusur NDPP X1100 2×10G / 32b SZSE-only hot path
//
// s_axis_a / s_axis_b (32b eth)
//   → udp_strip #(.DATA_W(32)) ×2
//   → dec_szse_bin #(.DATA_W(32)) ×2
//   → arb_nway (TCP tied off)
//   → [ENABLE_BOOK=0] sym_cam → mcast + dma
//   → [ENABLE_BOOK=1] book_engine (hot_cam path; 8k sym_cam bypassed)
//                     → bypass → mcast + dma
//                     → book_delta + l1 stub
// No SSE / FAST / event_merge / futures. event_t layout unchanged (md_pkg).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module md_rx_top_x1100
  import md_pkg::*;
  import ndpp_pkg::*;
  import book_pkg::*;
#(
  parameter bit ENABLE_BOOK = 1'b0
) (
  input  logic         clk,
  input  logic         rst_n,

  // ---- shared strip filter ----
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

  // ---- CAM (sym_cam; used when ENABLE_BOOK=0) ----
  input  logic         cfg_pass_miss,
  input  logic         cam_we,
  input  logic [12:0]  cam_addr,
  input  logic [55:0]  cam_key,
  input  logic [15:0]  cam_id,
  input  logic         cam_entry_valid,
  input  logic         cam_swap,
  output logic         cam_bank_sel,

  // ---- hot_cam / book CSR (used when ENABLE_BOOK=1) ----
  input  logic              hot_we,
  input  logic [HOT_AW-1:0] hot_addr,
  input  logic [47:0]       hot_code,
  input  logic              hot_entry_valid,
  input  logic              book_clear,

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

  // ---- 2 eth ingress A/B (32-bit) ----
  input  logic [NDPP_AXIS_W-1:0]      s_axis_a_tdata,
  input  logic [NDPP_AXIS_KEEP_W-1:0] s_axis_a_tkeep,
  input  logic                        s_axis_a_tvalid,
  input  logic                        s_axis_a_tlast,
  output logic                        s_axis_a_tready,
  input  eth_tuser_t                  s_axis_a_tuser,

  input  logic [NDPP_AXIS_W-1:0]      s_axis_b_tdata,
  input  logic [NDPP_AXIS_KEEP_W-1:0] s_axis_b_tkeep,
  input  logic                        s_axis_b_tvalid,
  input  logic                        s_axis_b_tlast,
  output logic                        s_axis_b_tready,
  input  eth_tuser_t                  s_axis_b_tuser,

  // ---- egress (mcast eth builder remains 64b) ----
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

  // ---- book_delta AXIS (packed book_delta_t) ----
  output logic [255:0] m_book_tdata,
  output logic         m_book_tvalid,
  output logic         m_book_tlast,
  input  logic         m_book_tready,

  // ---- book status ----
  output logic [31:0]  book_l1_push_cnt,
  output logic [31:0]  book_hot_hit_cnt,
  output logic [31:0]  book_hot_miss_cnt,
  output logic [31:0]  book_delta_cnt,

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
  // Strip ×2 (32b)
  // =========================================================================
  logic [NDPP_AXIS_W-1:0]      pay_tdata  [0:1];
  logic [NDPP_AXIS_KEEP_W-1:0] pay_tkeep  [0:1];
  logic                        pay_tvalid [0:1];
  logic                        pay_tlast  [0:1];
  logic                        pay_tready [0:1];
  pay_tuser_t                  pay_tuser  [0:1];

  logic [31:0] st_ok   [0:1];
  logic [31:0] st_nudp [0:1];
  logic [31:0] st_opt  [0:1];
  logic [31:0] st_filt [0:1];

  eth_tuser_t a_tu_fix, b_tu_fix;
  // udp_strip o_dbg_* intentionally unused at this layer (house-rule keep ports)
  logic [2:0] strip_dbg_cs_nc   [0:1];
  logic       strip_dbg_err_nc  [0:1];
  logic       strip_dbg_ovfl_nc [0:1];
  always_comb begin
    a_tu_fix = s_axis_a_tuser; a_tu_fix.port_id = 3'(NDPP_P_A);
    b_tu_fix = s_axis_b_tuser; b_tu_fix.port_id = 3'(NDPP_P_B);
  end

  // Eth/IPv4/UDP cut-through strip, 32b port A. o_dbg_* left open on purpose.
  udp_strip #(.DATA_W(NDPP_AXIS_W)) u_strip_a (
    .clk(clk), .rst_n(rst_n),                                 // 电平
    .i_cfg_dst_mac(cfg_dst_mac), .i_cfg_dst_ip(cfg_dst_ip), .i_cfg_udp_dport(cfg_udp_dport), // 电平
    .i_s_tdata(s_axis_a_tdata), .i_s_tkeep(s_axis_a_tkeep),   // 握手
    .i_s_tvalid(s_axis_a_tvalid), .i_s_tlast(s_axis_a_tlast),
    .o_s_tready(s_axis_a_tready), .i_s_tuser(a_tu_fix),
    .o_m_tdata(pay_tdata[0]), .o_m_tkeep(pay_tkeep[0]),       // 握手
    .o_m_tvalid(pay_tvalid[0]), .o_m_tlast(pay_tlast[0]),
    .i_m_tready(pay_tready[0]), .o_m_tuser(pay_tuser[0]),
    .o_drop_not_udp(st_nudp[0]), .o_drop_opt(st_opt[0]),
    .o_drop_filter(st_filt[0]), .o_frames_ok(st_ok[0]),
    .o_dbg_cs_state(strip_dbg_cs_nc[0]), .o_dbg_err_sticky(strip_dbg_err_nc[0]), .o_dbg_skid_ovfl(strip_dbg_ovfl_nc[0])
  );

  // Eth/IPv4/UDP cut-through strip, 32b port B. o_dbg_* left open on purpose.
  udp_strip #(.DATA_W(NDPP_AXIS_W)) u_strip_b (
    .clk(clk), .rst_n(rst_n),                                 // 电平
    .i_cfg_dst_mac(cfg_dst_mac), .i_cfg_dst_ip(cfg_dst_ip), .i_cfg_udp_dport(cfg_udp_dport), // 电平
    .i_s_tdata(s_axis_b_tdata), .i_s_tkeep(s_axis_b_tkeep),   // 握手
    .i_s_tvalid(s_axis_b_tvalid), .i_s_tlast(s_axis_b_tlast),
    .o_s_tready(s_axis_b_tready), .i_s_tuser(b_tu_fix),
    .o_m_tdata(pay_tdata[1]), .o_m_tkeep(pay_tkeep[1]),       // 握手
    .o_m_tvalid(pay_tvalid[1]), .o_m_tlast(pay_tlast[1]),
    .i_m_tready(pay_tready[1]), .o_m_tuser(pay_tuser[1]),
    .o_drop_not_udp(st_nudp[1]), .o_drop_opt(st_opt[1]),
    .o_drop_filter(st_filt[1]), .o_frames_ok(st_ok[1]),
    .o_dbg_cs_state(strip_dbg_cs_nc[1]), .o_dbg_err_sticky(strip_dbg_err_nc[1]), .o_dbg_skid_ovfl(strip_dbg_ovfl_nc[1])
  );

  // =========================================================================
  // SZSE Binary decoders ×2 (32b)
  // =========================================================================
  logic [511:0] dec_tdata  [0:1];
  logic         dec_tvalid [0:1];
  logic         dec_tlast  [0:1];
  logic         dec_tready [0:1];
  logic [47:0]  dec_code   [0:1];
  logic [31:0]  dec_ok     [0:1];
  logic [31:0]  dec_bad    [0:1];

  dec_szse_bin #(.DATA_W(NDPP_AXIS_W)) u_dec_a (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_szse_off_type), .cfg_off_seq(cfg_szse_off_seq),
    .cfg_off_code(cfg_szse_off_code), .cfg_off_px(cfg_szse_off_px),
    .cfg_off_qty(cfg_szse_off_qty), .cfg_off_side(cfg_szse_off_side),
    .cfg_off_oid(cfg_szse_off_oid), .cfg_len_hdr(cfg_szse_len_hdr),
    .cfg_type_lut(cfg_szse_type_lut), .cfg_off_ch_hint(cfg_szse_off_ch_hint),
    .s_axis_tdata(pay_tdata[0]), .s_axis_tkeep(pay_tkeep[0]),
    .s_axis_tvalid(pay_tvalid[0]), .s_axis_tlast(pay_tlast[0]),
    .s_axis_tready(pay_tready[0]), .s_axis_tuser(pay_tuser[0]),
    .m_event_tdata(dec_tdata[0]), .m_event_tvalid(dec_tvalid[0]),
    .m_event_tlast(dec_tlast[0]), .m_event_tready(dec_tready[0]),
    .m_code(dec_code[0]), .msg_ok(dec_ok[0]), .msg_bad(dec_bad[0])
  );

  dec_szse_bin #(.DATA_W(NDPP_AXIS_W)) u_dec_b (
    .clk(clk), .rst_n(rst_n),
    .cfg_off_type(cfg_szse_off_type), .cfg_off_seq(cfg_szse_off_seq),
    .cfg_off_code(cfg_szse_off_code), .cfg_off_px(cfg_szse_off_px),
    .cfg_off_qty(cfg_szse_off_qty), .cfg_off_side(cfg_szse_off_side),
    .cfg_off_oid(cfg_szse_off_oid), .cfg_len_hdr(cfg_szse_len_hdr),
    .cfg_type_lut(cfg_szse_type_lut), .cfg_off_ch_hint(cfg_szse_off_ch_hint),
    .s_axis_tdata(pay_tdata[1]), .s_axis_tkeep(pay_tkeep[1]),
    .s_axis_tvalid(pay_tvalid[1]), .s_axis_tlast(pay_tlast[1]),
    .s_axis_tready(pay_tready[1]), .s_axis_tuser(pay_tuser[1]),
    .m_event_tdata(dec_tdata[1]), .m_event_tvalid(dec_tvalid[1]),
    .m_event_tlast(dec_tlast[1]), .m_event_tready(dec_tready[1]),
    .m_code(dec_code[1]), .msg_ok(dec_ok[1]), .msg_bad(dec_bad[1])
  );

  // =========================================================================
  // arb_nway (A/B only; TCP tied off) — no event_merge
  // =========================================================================
  logic         arb_tcp_rdy;
  logic [511:0] arb_tdata;
  logic         arb_tvalid, arb_tlast, arb_tready;
  logic [47:0]  arb_code;
  logic [31:0]  arb_fwd_c, arb_dup_c, arb_dtcp, arb_gap;

  arb_nway u_arb (
    .clk(clk), .rst_n(rst_n),
    .s_a_tdata(dec_tdata[0]), .s_a_tvalid(dec_tvalid[0]), .s_a_tlast(dec_tlast[0]),
    .s_a_tready(dec_tready[0]), .s_a_code(dec_code[0]),
    .s_b_tdata(dec_tdata[1]), .s_b_tvalid(dec_tvalid[1]), .s_b_tlast(dec_tlast[1]),
    .s_b_tready(dec_tready[1]), .s_b_code(dec_code[1]),
    .s_tcp_tdata('0), .s_tcp_tvalid(1'b0), .s_tcp_tlast(1'b0),
    .s_tcp_tready(arb_tcp_rdy), .s_tcp_code('0),
    .m_event_tdata(arb_tdata), .m_event_tvalid(arb_tvalid),
    .m_event_tlast(arb_tlast), .m_event_tready(arb_tready),
    .m_code(arb_code),
    .fwd(arb_fwd_c), .drop_dup(arb_dup_c), .drop_tcp(arb_dtcp), .gap(arb_gap)
  );

  // =========================================================================
  // Post-arb: sym_cam OR book_engine
  // =========================================================================
  logic [511:0] post_tdata;
  logic         post_tvalid, post_tlast, post_tready;
  logic [31:0]  cam_hit_c, cam_miss_c, cam_drop_c;

  logic [31:0]  b_l1, b_hit, b_miss, b_dcnt;
  book_delta_t  b_delta;
  logic         b_delta_v;
  level_t       dbg0, dbg1, dbg2, dbg3, dbg4, dbg5, dbg6, dbg7, dbg8, dbg9;

  generate
    if (ENABLE_BOOK) begin : g_book
      logic book_rdy;
      book_engine u_book (
        .clk(clk), .rst_n(rst_n),
        .s_event_tdata(arb_tdata), .s_event_tvalid(arb_tvalid),
        .s_event_tlast(arb_tlast), .s_event_tready(book_rdy),
        .s_code(arb_code),
        .m_bypass_tdata(post_tdata), .m_bypass_tvalid(post_tvalid),
        .m_bypass_tlast(post_tlast), .m_bypass_tready(post_tready),
        .m_delta(b_delta), .m_delta_valid(b_delta_v),
        .m_delta_ready(m_book_tready),
        .hot_we(hot_we), .hot_addr(hot_addr),
        .hot_code(hot_code), .hot_entry_valid(hot_entry_valid),
        .book_clear(book_clear),
        .l1_push_cnt(b_l1), .hot_hit_cnt(b_hit),
        .hot_miss_cnt(b_miss), .delta_cnt(b_dcnt),
        .dbg_hot_id(7'd1), .dbg_side(SIDE_BID),
        .dbg_lvl0(dbg0), .dbg_lvl1(dbg1), .dbg_lvl2(dbg2), .dbg_lvl3(dbg3),
        .dbg_lvl4(dbg4), .dbg_lvl5(dbg5), .dbg_lvl6(dbg6), .dbg_lvl7(dbg7),
        .dbg_lvl8(dbg8), .dbg_lvl9(dbg9)
      );
      assign arb_tready   = book_rdy; // always 1
      assign cam_bank_sel = 1'b0;
      assign cam_hit_c    = 32'd0;
      assign cam_miss_c   = 32'd0;
      assign cam_drop_c   = 32'd0;
    end else begin : g_cam
      sym_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .s_event_tdata(arb_tdata), .s_event_tvalid(arb_tvalid),
        .s_event_tlast(arb_tlast), .s_event_tready(arb_tready),
        .s_code(arb_code),
        .m_event_tdata(post_tdata), .m_event_tvalid(post_tvalid),
        .m_event_tlast(post_tlast), .m_event_tready(post_tready),
        .cfg_pass_miss(cfg_pass_miss), .bank_sel(cam_bank_sel), .swap(cam_swap),
        .cam_we(cam_we), .cam_addr(cam_addr), .cam_key(cam_key),
        .cam_id(cam_id), .cam_entry_valid(cam_entry_valid),
        .hit(cam_hit_c), .miss(cam_miss_c), .drop_miss(cam_drop_c)
      );
      assign b_l1    = 32'd0;
      assign b_hit   = 32'd0;
      assign b_miss  = 32'd0;
      assign b_dcnt  = 32'd0;
      assign b_delta = '0;
      assign b_delta_v = 1'b0;
      assign dbg0 = '0; assign dbg1 = '0; assign dbg2 = '0; assign dbg3 = '0;
      assign dbg4 = '0; assign dbg5 = '0; assign dbg6 = '0; assign dbg7 = '0;
      assign dbg8 = '0; assign dbg9 = '0;
    end
  endgenerate

  assign book_l1_push_cnt  = b_l1;
  assign book_hot_hit_cnt  = b_hit;
  assign book_hot_miss_cnt = b_miss;
  assign book_delta_cnt    = b_dcnt;

  assign m_book_tdata  = 256'(b_delta);
  assign m_book_tvalid = b_delta_v;
  assign m_book_tlast  = 1'b1;

  // =========================================================================
  // Broadcast to mcast + dma
  // =========================================================================
  logic mcast_ev_ready, dma_ev_ready;
  assign post_tready = mcast_ev_ready && dma_ev_ready;

  logic [31:0] mcast_tx_c, mcast_df, mcast_dr;
  logic [31:0] dma_tx_c, dma_df;

  mcast_eng #(.CLIENT_ID(0)) u_mcast (
    .clk(clk), .rst_n(rst_n),
    .s_event_tdata(post_tdata), .s_event_tvalid(post_tvalid),
    .s_event_tlast(post_tlast), .s_event_tready(mcast_ev_ready),
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
    .s_event_tdata(post_tdata), .s_event_tvalid(post_tvalid),
    .s_event_tlast(post_tlast), .s_event_tready(dma_ev_ready),
    .m_axis_tdata(m_dma_tdata), .m_axis_tkeep(m_dma_tkeep),
    .m_axis_tvalid(m_dma_tvalid), .m_axis_tlast(m_dma_tlast),
    .m_axis_tready(m_dma_tready),
    .tx_ok(dma_tx_c), .drop_full(dma_df)
  );

  // =========================================================================
  // telem
  // =========================================================================
  logic [31:0] sum_ok, sum_drop, sum_msg_ok, sum_msg_bad;

  assign sum_ok      = st_ok[0] + st_ok[1];
  assign sum_drop    = st_nudp[0] + st_nudp[1] + st_opt[0] + st_opt[1]
                     + st_filt[0] + st_filt[1];
  assign sum_msg_ok  = dec_ok[0] + dec_ok[1];
  assign sum_msg_bad = dec_bad[0] + dec_bad[1];

  telem u_telem (
    .clk(clk), .rst_n(rst_n),
    .strip_frames_ok(sum_ok), .strip_drop(sum_drop),
    .dec_msg_ok(sum_msg_ok), .dec_msg_bad(sum_msg_bad),
    .arb_fwd(arb_fwd_c), .arb_drop_dup(arb_dup_c),
    .cam_hit(cam_hit_c), .cam_miss(cam_miss_c),
    .mcast_tx(mcast_tx_c), .dma_tx(dma_tx_c),
    .frames_ok(telem_frames_ok), .frames_drop(telem_frames_drop),
    .msg_ok(telem_msg_ok), .msg_bad(telem_msg_bad),
    .arb_fwd_c(telem_arb_fwd), .arb_dup_c(telem_arb_dup),
    .cam_hit_c(telem_cam_hit), .cam_miss_c(telem_cam_miss),
    .mcast_tx_c(telem_mcast_tx), .dma_tx_c(telem_dma_tx)
  );

  logic unused_tie;
  assign unused_tie = ^{arb_gap, arb_dtcp, cam_drop_c, mcast_df, mcast_dr,
                        dma_df, arb_tcp_rdy, hot_we, hot_addr, hot_code,
                        hot_entry_valid, book_clear, dbg0, dbg1, dbg2, dbg3,
                        dbg4, dbg5, dbg6, dbg7, dbg8, dbg9};

endmodule
