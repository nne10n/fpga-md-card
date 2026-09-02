// -----------------------------------------------------------------------------
// udp_strip.sv — Cut-through Eth/IPv4/UDP header strip → payload AXIS
// Wire byte 0 in tdata[7:0]. o_s_tready tied 1. No L3/L4 checksum checks.
// Extra counter o_drop_filter: dest MAC/IP/UDP-port filter miss (not proto/IHL).
// DATA_W = 32|64 (default 64). KEEP_W = DATA_W/8. Same-clock 2-deep skid.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module udp_strip
  import md_pkg::*;
#(
  parameter int DATA_W = 64,
  parameter int KEEP_W = DATA_W / 8
) (
  input  logic        clk,
  /* verilator lint_off SYNCASYNCNET */
  input  logic        rst_n,
  /* verilator lint_on SYNCASYNCNET */

  input  logic [47:0] i_cfg_dst_mac,
  input  logic [31:0] i_cfg_dst_ip,
  input  logic [15:0] i_cfg_udp_dport,

  input  logic [DATA_W-1:0] i_s_tdata,
  input  logic [KEEP_W-1:0] i_s_tkeep,
  input  logic              i_s_tvalid,
  input  logic              i_s_tlast,
  output logic              o_s_tready,
  input  eth_tuser_t        i_s_tuser,

  output logic [DATA_W-1:0] o_m_tdata,
  output logic [KEEP_W-1:0] o_m_tkeep,
  output logic              o_m_tvalid,
  output logic              o_m_tlast,
  input  logic              i_m_tready,
  output pay_tuser_t        o_m_tuser,

  output logic [31:0] o_drop_not_udp,
  output logic [31:0] o_drop_opt,
  output logic [31:0] o_drop_filter,
  output logic [31:0] o_frames_ok,

  (* keep = "true" *) output logic [2:0] o_dbg_cs_state,
  (* keep = "true" *) output logic       o_dbg_err_sticky,
  (* keep = "true" *) output logic       o_dbg_skid_ovfl
);

  assign o_s_tready = 1'b1;

  localparam int unsigned HDR_LEN   = 42;
  localparam int unsigned PEND_N_W  = $clog2(KEEP_W + 1);

  generate
    if ((DATA_W != 32) && (DATA_W != 64)) begin : g_data_w_illegal
      initial $error("udp_strip: DATA_W must be 32 or 64");
    end
  endgenerate

  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_HDR   = 3'd1,
    ST_PASS  = 3'd2,
    ST_DRAIN = 3'd3,
    ST_DROP  = 3'd4
  } state_e;

  state_e cs_state;
  state_e ns_state;

  logic        w_s_fire;
  assign w_s_fire = i_s_tvalid && o_s_tready;

  logic [7:0]  r_hdr   [0:HDR_LEN-1];
  logic [5:0]  r_hdr_n;
  logic [15:0] r_dport;
  eth_tuser_t  r_tuser;

  logic [7:0]  w_hdr   [0:HDR_LEN-1];
  logic [5:0]  w_hdr_n;
  logic [15:0] w_dport;
  eth_tuser_t  w_tuser;

  logic [15:0]                r_pay_rem;
  logic [7:0]                 r_pend  [0:KEEP_W-1];
  logic [PEND_N_W-1:0]        r_pend_n;
  logic [DATA_W-1:0]          r_odata [0:1];
  logic [KEEP_W-1:0]          r_okeep [0:1];
  logic                       r_olast [0:1];
  pay_tuser_t                 r_otuser[0:1];
  logic [1:0]                 r_ocount;

  logic [15:0]                w_pay_rem;
  logic [7:0]                 w_pend  [0:KEEP_W-1];
  logic [PEND_N_W-1:0]        w_pend_n;

  logic [DATA_W-1:0]          w_odata_pop [0:1];
  logic [KEEP_W-1:0]          w_okeep_pop [0:1];
  logic                       w_olast_pop [0:1];
  pay_tuser_t                 w_otuser_pop[0:1];
  logic [1:0]                 w_ocount_pop;

  logic [DATA_W-1:0]          w_emit_data [0:1];
  logic [KEEP_W-1:0]          w_emit_keep [0:1];
  logic                       w_emit_last [0:1];
  pay_tuser_t                 w_emit_user [0:1];
  logic [1:0]                 w_emit_n;

  logic                       w_flush_valid;
  logic [DATA_W-1:0]          w_flush_data;
  logic [KEEP_W-1:0]          w_flush_keep;
  logic                       w_flush_last;
  pay_tuser_t                 w_flush_user;

  logic [DATA_W-1:0]          w_odata [0:1];
  logic [KEEP_W-1:0]          w_okeep [0:1];
  logic                       w_olast [0:1];
  pay_tuser_t                 w_otuser[0:1];
  logic [1:0]                 w_ocount;

  logic        w_hdr_just_done;
  logic        w_go_drop;
  logic [1:0]  w_why;
  logic        w_bp_fail;
  logic        w_illegal_cs;

  logic        w_inc_not_udp;
  logic        w_inc_opt;
  logic        w_inc_filt;
  logic        w_inc_ok;

  logic        w_ethertype_ipv4;
  logic        w_ip_v4;
  logic        w_ihl_eq5;
  logic        w_ihl_gt5;
  logic        w_ihl_lt5;
  logic        w_proto_udp;
  logic        w_ulen_ge8;
  logic        w_mac_ok;
  logic        w_dip_ok;
  logic        w_dport_ok;
  logic        w_filter_ok;
  logic [15:0] w_udp_plen;

  logic [31:0] r_c_not_udp;
  logic [31:0] r_c_opt;
  logic [31:0] r_c_filt;
  logic [31:0] r_c_ok;
  logic        r_err_sticky;
  logic        r_skid_ovfl;

  assign w_illegal_cs = (cs_state != ST_IDLE) && (cs_state != ST_HDR) &&
                        (cs_state != ST_PASS) && (cs_state != ST_DRAIN) &&
                        (cs_state != ST_DROP);

  assign o_drop_not_udp = r_c_not_udp;
  assign o_drop_opt     = r_c_opt;
  assign o_drop_filter  = r_c_filt;
  assign o_frames_ok    = r_c_ok;

  assign o_m_tvalid = (r_ocount != 2'd0);
  assign o_m_tdata  = r_odata[0];
  assign o_m_tkeep  = r_okeep[0];
  assign o_m_tlast  = r_olast[0];
  assign o_m_tuser  = r_otuser[0];

  assign o_dbg_cs_state         = cs_state;
  assign o_dbg_err_sticky = r_err_sticky;
  assign o_dbg_skid_ovfl  = r_skid_ovfl;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic mac_accept(
      input logic [7:0] b0, b1, b2, b3, b4, b5
  );
    logic [47:0] dst;
    dst = {b0, b1, b2, b3, b4, b5};
    return (dst == i_cfg_dst_mac) ||
           (dst == 48'hFFFF_FFFF_FFFF) ||
           (b0[0] == 1'b1);
  endfunction

  function automatic void pack_pend(
      input  logic [7:0]          pend [0:KEEP_W-1],
      input  logic [PEND_N_W-1:0] n,
      output logic [DATA_W-1:0]   data,
      output logic [KEEP_W-1:0]   keep
  );
    automatic int k;
    data = '0;
    keep = '0;
    for (k = 0; k < KEEP_W; k++) begin
      if (k < int'(n)) begin
        data[k*8 +: 8] = pend[k];
        keep[k]        = 1'b1;
      end
    end
  endfunction

  // Pop occupied skid slots when the payload AXIS consumer is ready.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    w_odata_pop[0]  = r_odata[0];
    w_odata_pop[1]  = r_odata[1];
    w_okeep_pop[0]  = r_okeep[0];
    w_okeep_pop[1]  = r_okeep[1];
    w_olast_pop[0]  = r_olast[0];
    w_olast_pop[1]  = r_olast[1];
    w_otuser_pop[0] = r_otuser[0];
    w_otuser_pop[1] = r_otuser[1];
    w_ocount_pop    = r_ocount;
    if ((r_ocount != 2'd0) && i_m_tready) begin
      w_odata_pop[0]  = r_odata[1];
      w_okeep_pop[0]  = r_okeep[1];
      w_olast_pop[0]  = r_olast[1];
      w_otuser_pop[0] = r_otuser[1];
      w_odata_pop[1]  = '0;
      w_okeep_pop[1]  = '0;
      w_olast_pop[1]  = 1'b0;
      w_otuser_pop[1] = '0;
      w_ocount_pop    = r_ocount - 2'd1;
    end
  end

  // Capture Ethernet/IPv4/UDP header bytes and dest port from the ingress beat.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    automatic int i;
    automatic logic [5:0]  w_hn;
    automatic logic [15:0] w_dp;
    automatic eth_tuser_t  w_tu;
    automatic logic [7:0]  w_b;

    for (i = 0; i < HDR_LEN; i++)
      w_hdr[i] = r_hdr[i];
    w_hdr_n         = r_hdr_n;
    w_dport         = r_dport;
    w_tuser         = r_tuser;
    w_hdr_just_done = 1'b0;

    w_hn = r_hdr_n;
    w_dp = r_dport;
    w_tu = r_tuser;
    w_b  = '0;

    if (w_s_fire) begin
      if (cs_state == ST_IDLE) begin
        w_tu = i_s_tuser;
        w_hn = '0;
        for (i = 0; i < HDR_LEN; i++)
          w_hdr[i] = '0;
      end

      for (i = 0; i < KEEP_W; i++) begin
        if (i_s_tkeep[i]) begin
          w_b = i_s_tdata[i*8 +: 8];
          if ((cs_state == ST_IDLE || cs_state == ST_HDR) &&
              !w_hdr_just_done && (w_hn < HDR_LEN[5:0])) begin
            w_hdr[w_hn] = w_b;
            w_hn = w_hn + 6'd1;
            if (w_hn == HDR_LEN[5:0]) begin
              w_dp            = {w_hdr[36], w_hdr[37]};
              w_hdr_just_done = 1'b1;
            end
          end
        end
      end

      if (i_s_tlast)
        w_hn = '0;

      w_hdr_n = w_hn;
      w_dport = w_dp;
      w_tuser = w_tu;
    end
  end

  assign w_ethertype_ipv4 = ({w_hdr[12], w_hdr[13]} == 16'h0800);
  assign w_ip_v4          = (w_hdr[14][7:4] == 4'd4);
  assign w_ihl_eq5        = (w_hdr[14][3:0] == 4'd5);
  assign w_ihl_gt5        = (w_hdr[14][3:0] >  4'd5);
  assign w_ihl_lt5        = (w_hdr[14][3:0] <  4'd5);
  assign w_proto_udp      = (w_hdr[23] == 8'd17);
  assign w_ulen_ge8       = ({w_hdr[38], w_hdr[39]} >= 16'd8);
  assign w_mac_ok         = mac_accept(w_hdr[0], w_hdr[1], w_hdr[2],
                                       w_hdr[3], w_hdr[4], w_hdr[5]);
  assign w_dip_ok         = ({w_hdr[30], w_hdr[31], w_hdr[32], w_hdr[33]} ==
                             i_cfg_dst_ip);
  assign w_dport_ok       = (i_cfg_udp_dport == 16'd0) ||
                            ({w_hdr[36], w_hdr[37]} == i_cfg_udp_dport);
  assign w_filter_ok      = w_mac_ok && w_dip_ok && w_dport_ok;
  assign w_udp_plen       = w_ulen_ge8 ? ({w_hdr[38], w_hdr[39]} - 16'd8)
                                       : 16'd0;
  // same priority as old classify_hdr: etype/ver/ihl<5/proto/ulen → 1;
  // ihl>5 → 2 even if proto bad; else filter → 3
  assign w_why = (!w_ethertype_ipv4 || !w_ip_v4 || w_ihl_lt5 ||
                  (w_ihl_eq5 && (!w_proto_udp || !w_ulen_ge8))) ? 2'd1 :
                 w_ihl_gt5 ? 2'd2 :
                 (!w_filter_ok) ? 2'd3 : 2'd0;
  assign w_go_drop = w_hdr_just_done && (w_why != 2'd0);

  // Realign payload bytes, emit full words, and flush leftovers on tlast.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    automatic int i;
    automatic int w_ei;
    automatic logic [5:0]           w_hn;
    automatic logic [PEND_N_W-1:0]  w_pn;
    automatic logic [15:0]          w_pr;
    automatic logic [7:0]           w_b;
    automatic logic                 w_is_last;
    automatic logic [DATA_W-1:0]    w_ed;
    automatic logic [KEEP_W-1:0]    w_ek;
    automatic pay_tuser_t           w_pu;

    for (i = 0; i < KEEP_W; i++)
      w_pend[i] = r_pend[i];
    w_pend_n  = r_pend_n;
    w_pay_rem = r_pay_rem;

    w_bp_fail     = 1'b0;
    w_emit_data[0] = '0;
    w_emit_data[1] = '0;
    w_emit_keep[0] = '0;
    w_emit_keep[1] = '0;
    w_emit_last[0] = 1'b0;
    w_emit_last[1] = 1'b0;
    w_emit_user[0] = '0;
    w_emit_user[1] = '0;
    w_emit_n       = 2'd0;
    w_flush_valid  = 1'b0;
    w_flush_data   = '0;
    w_flush_keep   = '0;
    w_flush_last   = 1'b0;
    w_flush_user   = '0;

    w_hn      = (cs_state == ST_IDLE) ? 6'd0 : r_hdr_n;
    w_pn      = r_pend_n;
    w_pr      = r_pay_rem;
    w_b       = '0;
    w_is_last = 1'b0;
    w_ed      = '0;
    w_ek      = '0;
    w_ei      = 0;
    w_pu      = '0;

    if (w_s_fire) begin
      if (cs_state == ST_IDLE) begin
        w_pn = '0;
        w_pr = '0;
        for (i = 0; i < KEEP_W; i++)
          w_pend[i] = '0;
      end

      if (w_hdr_just_done && !w_go_drop)
        w_pr = w_udp_plen;
      else if (cs_state == ST_PASS)
        w_pr = r_pay_rem;

      w_pu.port_id   = w_tuser.port_id;
      w_pu.sop_ts    = w_tuser.sop_ts;
      w_pu.udp_dport = w_dport;
      w_pu.l4_prot   = 8'd17;
      w_pu.from_tcp  = 1'b0;

      for (i = 0; i < KEEP_W; i++) begin
        if (i_s_tkeep[i]) begin
          w_b = i_s_tdata[i*8 +: 8];
          if (w_hn < HDR_LEN[5:0]) begin
            w_hn = w_hn + 6'd1;
          end else if (!w_go_drop && !w_bp_fail) begin
            if (w_pr != 16'd0) begin
              w_is_last    = (w_pr == 16'd1);
              w_pend[w_pn] = w_b;
              w_pn         = w_pn + PEND_N_W'(1);
              w_pr         = w_pr - 16'd1;
              if ((w_pn == PEND_N_W'(KEEP_W)) || w_is_last) begin
                pack_pend(w_pend, w_pn, w_ed, w_ek);
                if ((w_ocount_pop + w_emit_n) >= 2'd2) begin
                  w_bp_fail = 1'b1;
                end else begin
                  w_ei              = int'(w_emit_n);
                  w_emit_data[w_ei] = w_ed;
                  w_emit_keep[w_ei] = w_ek;
                  w_emit_last[w_ei] = w_is_last;
                  w_emit_user[w_ei] = w_pu;
                  w_emit_n          = w_emit_n + 2'd1;
                end
                w_pn = '0;
              end
            end
          end
        end
      end

      if (i_s_tlast) begin
        if ((w_pn != '0) &&
            (cs_state == ST_PASS || cs_state == ST_DRAIN ||
             (w_hdr_just_done && w_why == 2'd0)) &&
            !w_go_drop && !w_bp_fail) begin
          pack_pend(w_pend, w_pn, w_ed, w_ek);
          w_flush_valid = 1'b1;
          w_flush_data  = w_ed;
          w_flush_keep  = w_ek;
          w_flush_last  = 1'b1;
          w_flush_user  = w_pu;
        end
        w_pn = '0;
        w_pr = '0;
      end

      w_pend_n  = w_pn;
      w_pay_rem = w_pr;
    end
  end

  // Strobe saturating not-UDP / options / filter / ok counters.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    w_inc_not_udp = 1'b0;
    w_inc_opt     = 1'b0;
    w_inc_filt    = 1'b0;
    w_inc_ok      = 1'b0;
    if (w_s_fire) begin
      if (i_s_tlast && (cs_state == ST_IDLE || cs_state == ST_HDR) && !w_hdr_just_done)
        w_inc_not_udp = 1'b1;
      else if (w_go_drop) begin
        if (w_why == 2'd1)      w_inc_not_udp = 1'b1;
        else if (w_why == 2'd2) w_inc_opt     = 1'b1;
        else                    w_inc_filt    = 1'b1;
      end else if (i_s_tlast && w_bp_fail) begin
        ;
      end else if (i_s_tlast && (cs_state == ST_PASS || cs_state == ST_DRAIN ||
                                 (w_hdr_just_done && w_why == 2'd0))) begin
        w_inc_ok = 1'b1;
      end
    end
  end

  // Merge pop skid with this-beat emit words and optional tlast leftover flush.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    automatic int i;
    automatic logic [1:0] w_oc;

    w_odata[0]  = w_odata_pop[0];
    w_odata[1]  = w_odata_pop[1];
    w_okeep[0]  = w_okeep_pop[0];
    w_okeep[1]  = w_okeep_pop[1];
    w_olast[0]  = w_olast_pop[0];
    w_olast[1]  = w_olast_pop[1];
    w_otuser[0] = w_otuser_pop[0];
    w_otuser[1] = w_otuser_pop[1];
    w_oc        = w_ocount_pop;

    for (i = 0; i < 2; i++) begin
      if (i < int'(w_emit_n)) begin
        if (w_oc == 2'd0) begin
          w_odata[0]  = w_emit_data[i];
          w_okeep[0]  = w_emit_keep[i];
          w_olast[0]  = w_emit_last[i];
          w_otuser[0] = w_emit_user[i];
        end else begin
          w_odata[1]  = w_emit_data[i];
          w_okeep[1]  = w_emit_keep[i];
          w_olast[1]  = w_emit_last[i];
          w_otuser[1] = w_emit_user[i];
        end
        w_oc = w_oc + 2'd1;
      end
    end

    if (w_flush_valid && (w_oc < 2'd2)) begin
      if (w_oc == 2'd0) begin
        w_odata[0]  = w_flush_data;
        w_okeep[0]  = w_flush_keep;
        w_olast[0]  = w_flush_last;
        w_otuser[0] = w_flush_user;
      end else begin
        w_odata[1]  = w_flush_data;
        w_okeep[1]  = w_flush_keep;
        w_olast[1]  = w_flush_last;
        w_otuser[1] = w_flush_user;
      end
      w_oc = w_oc + 2'd1;
    end

    w_ocount = w_oc;
  end

  // Select next FSM state from captured header fields and payload remainder.
  // SPEC: module-design-v1.md §3.1
  always_comb begin
    ns_state = cs_state;
    case (cs_state)
      ST_IDLE: begin
        if (i_s_tvalid && i_s_tlast)
          ns_state = ST_IDLE;
        else if (i_s_tvalid)
          ns_state = ST_HDR;
      end
      ST_HDR: begin
        if (i_s_tvalid && i_s_tlast)
          ns_state = ST_IDLE;
        else if (i_s_tvalid && w_bp_fail)
          ns_state = ST_DROP;
        else if (i_s_tvalid && w_hdr_just_done &&
                 (!w_ethertype_ipv4 || !w_ip_v4 || w_ihl_lt5 ||
                  !w_proto_udp || !w_ulen_ge8))
          ns_state = ST_DROP;
        else if (i_s_tvalid && w_hdr_just_done && w_ihl_gt5)
          ns_state = ST_DROP;
        else if (i_s_tvalid && w_hdr_just_done && !w_filter_ok)
          ns_state = ST_DROP;
        else if (i_s_tvalid && w_hdr_just_done &&
                 (w_udp_plen == 16'd0 || w_pay_rem == 16'd0))
          ns_state = ST_DRAIN;
        else if (i_s_tvalid && w_hdr_just_done)
          ns_state = ST_PASS;
      end
      ST_PASS: begin
        if (i_s_tvalid && i_s_tlast)
          ns_state = ST_IDLE;
        else if (i_s_tvalid && w_bp_fail)
          ns_state = ST_DROP;
        else if (i_s_tvalid && (w_pay_rem == 16'd0))
          ns_state = ST_DRAIN;
      end
      ST_DRAIN: begin
        if (i_s_tvalid && i_s_tlast)
          ns_state = ST_IDLE;
      end
      ST_DROP: begin
        if (i_s_tvalid && i_s_tlast)
          ns_state = ST_IDLE;
      end
      default: ns_state = ST_IDLE;
    endcase
  end

  // Register current FSM state.
  // SPEC: module-design-v1.md §3.1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      cs_state <= ST_IDLE;
    else
      cs_state <= ns_state;
  end

  // Capture stripped header bytes, UDP dport, and SOP tuser.
  // SPEC: module-design-v1.md §3.1
  always_ff @(posedge clk) begin
    automatic int i;
    if (!rst_n) begin
      r_hdr_n <= '0;
      r_dport <= '0;
      r_tuser <= '0;
      for (i = 0; i < HDR_LEN; i++)
        r_hdr[i] <= '0;
    end else begin
      r_hdr_n <= w_hdr_n;
      r_dport <= w_dport;
      r_tuser <= w_tuser;
      for (i = 0; i < HDR_LEN; i++)
        r_hdr[i] <= w_hdr[i];
    end
  end

  // Payload realign pending bytes and same-clock 2-deep skid registers.
  // SPEC: module-design-v1.md §3.1
  always_ff @(posedge clk) begin
    automatic int i;
    if (!rst_n) begin
      r_pay_rem <= '0;
      r_pend_n  <= '0;
      r_ocount  <= '0;
      for (i = 0; i < KEEP_W; i++)
        r_pend[i] <= '0;
      for (i = 0; i < 2; i++) begin
        r_odata[i]  <= '0;
        r_okeep[i]  <= '0;
        r_olast[i]  <= 1'b0;
        r_otuser[i] <= '0;
      end
    end else begin
      r_pay_rem   <= w_pay_rem;
      r_pend_n    <= w_pend_n;
      r_ocount    <= w_ocount;
      for (i = 0; i < KEEP_W; i++)
        r_pend[i] <= w_pend[i];
      r_odata[0]  <= w_odata[0];
      r_odata[1]  <= w_odata[1];
      r_okeep[0]  <= w_okeep[0];
      r_okeep[1]  <= w_okeep[1];
      r_olast[0]  <= w_olast[0];
      r_olast[1]  <= w_olast[1];
      r_otuser[0] <= w_otuser[0];
      r_otuser[1] <= w_otuser[1];
    end
  end

  // Saturating drop/ok counters and sticky illegal-state / skid-overflow flags.
  // SPEC: module-design-v1.md §3.1
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_c_not_udp  <= '0;
      r_c_opt      <= '0;
      r_c_filt     <= '0;
      r_c_ok       <= '0;
      r_err_sticky <= 1'b0;
      r_skid_ovfl  <= 1'b0;
    end else begin
      if (w_inc_not_udp) r_c_not_udp <= sat_inc(r_c_not_udp);
      if (w_inc_opt)     r_c_opt     <= sat_inc(r_c_opt);
      if (w_inc_filt)    r_c_filt    <= sat_inc(r_c_filt);
      if (w_inc_ok)      r_c_ok      <= sat_inc(r_c_ok);
      if (w_illegal_cs)  r_err_sticky <= 1'b1;
      if (w_bp_fail)     r_skid_ovfl  <= 1'b1;
    end
  end

endmodule

`default_nettype wire
