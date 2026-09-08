// -----------------------------------------------------------------------------
// mcast_eng.sv — Per-client multicast TX engine (N=1 sim)
//
// Evolve-in-place: keep the event AXIS + filter/rate producer contract so
// existing top/x1100/sim-mcast stay wired. Internally each accepted event is
// adapted to the frozen UDP-mcast TX stream:
//   s_udp payload = event_t (64B); SOP meta from CSR, optionally overridden.
//
// 三分法
//   CSR slow-path : src MAC/IP, default DIP/ports, ttl_default, map_en=1,
//                   mtu_pay. cfg_dst_mac is not an on-wire DA (no ARP).
//                   map_en=1 → DA=RFC1112(dip); map_en=0 → require
//                   cfg_dst_mac==RFC1112(dip) else sticky/no-TX.
//                   o_stat_dst_mac is the RFC1112(CSR dip) read-only mirror
//   AXIS + SOP    : UDP payload only; meta = dst/src_ip, sport/dport, ttl,
//                   payload_len, is_mcast — no MAC/VLAN
//   Derived       : DA=RFC1112(dip); IP/UDP lengths; IPv4 csum; UDP csum=0
//
// Order: lock meta → gate (224/4, SA not group, len match, map, mtu) → fill → TX
// Role A: s_event_tready ≡ 1; failures sticky + drop/nosend; no producer BP
// Same-clock: do not instantiate tx_afifo.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module mcast_eng
  import md_pkg::*;
#(
  parameter int CLIENT_ID = 0
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [511:0] s_event_tdata,
  input  logic         s_event_tvalid,
  input  logic         s_event_tlast,
  output logic         s_event_tready,

  output logic [63:0]  m_axis_tdata,
  output logic [7:0]   m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  input  logic         m_axis_tready,

  input  logic [47:0]  cfg_src_mac,
  input  logic [47:0]  cfg_dst_mac,     // map_en=0: must equal RFC1112(dip); never on-wire DA
  input  logic [31:0]  cfg_src_ip,
  input  logic [31:0]  cfg_dst_ip,
  input  logic [15:0]  cfg_udp_sport,
  input  logic [15:0]  cfg_udp_dport,
  input  logic [7:0]   cfg_ch_mask,
  input  logic [15:0]  cfg_period,
  input  logic [15:0]  cfg_refill,

  // CSR slow-path extensions (defaults keep existing instantiations green)
  input  logic [7:0]   cfg_ttl_default = 8'd1,
  input  logic         cfg_map_en      = 1'b1,
  input  logic [15:0]  cfg_mtu_pay     = 16'd1472,

  // SOP meta (sampled with the event). meta_valid=0 → CSR defaults.
  input  logic         i_s_udp_meta_valid  = 1'b0,
  input  logic [31:0]  i_s_udp_dst_ip      = 32'd0,
  input  logic [31:0]  i_s_udp_src_ip      = 32'd0,
  input  logic [15:0]  i_s_udp_sport       = 16'd0,
  input  logic [15:0]  i_s_udp_dport       = 16'd0,
  input  logic [7:0]   i_s_udp_ttl         = 8'd0,
  input  logic [15:0]  i_s_udp_payload_len = 16'd0,
  input  logic         i_s_udp_is_mcast    = 1'b0,

  input  logic         filt_we,
  input  logic [12:0]  filt_addr,
  input  logic         filt_bit,

  output logic [31:0]  tx_ok,
  output logic [31:0]  drop_filt,
  output logic [31:0]  drop_rate,
  output logic [31:0]  o_drop_gate,
  output logic [31:0]  o_nosend,
  output logic [47:0]  o_stat_dst_mac,

  (* keep = "true" *) output logic [0:0] o_dbg_cs_state,
  (* keep = "true" *) output logic       o_dbg_err_sticky
);

  // House-style names; this module stays on the event-bus clock (no CDC).
  logic sys_clk;
  logic sys_rst_n;
  assign sys_clk   = clk;
  assign sys_rst_n = rst_n;

  logic unused_cid;
  logic unused_tlast;
  assign unused_cid   = (CLIENT_ID == 0) ? 1'b0 : 1'b1;
  assign unused_tlast = s_event_tlast;

  // Role A: always accept; never backpressure the producer.
  assign s_event_tready = 1'b1;

  localparam int unsigned MAX_PAY     = 64;
  localparam int unsigned HDR_BYTES   = 42;
  localparam int unsigned MAX_FRAME   = HDR_BYTES + MAX_PAY;
  localparam int unsigned MAX_BEATS   = (MAX_FRAME + 7) / 8;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic [15:0] sat_add16(
      input logic [15:0] a,
      input logic [15:0] b
  );
    logic [16:0] s;
    s = {1'b0, a} + {1'b0, b};
    return s[16] ? 16'hFFFF : s[15:0];
  endfunction

  // SPEC: RFC1112 §6.4 — DA = 01-00-5E | (DIP & 0x7FFFFF)
  function automatic logic [47:0] rfc1112_da(input logic [31:0] dip);
    return {24'h01_00_5E, 1'b0, dip[22:0]};
  endfunction

  function automatic logic [15:0] ipv4_hdr_csum(
      input logic [31:0] src_ip,
      input logic [31:0] dst_ip,
      input logic [15:0] ip_total,
      input logic [7:0]  ttl
  );
    logic [31:0] sum;
    sum  = 32'h4500;
    sum += {16'd0, ip_total};
    sum += 32'h0000;
    sum += 32'h0000;
    sum += {16'd0, ttl, 8'h11};
    sum += {16'd0, src_ip[31:16]};
    sum += {16'd0, src_ip[15:0]};
    sum += {16'd0, dst_ip[31:16]};
    sum += {16'd0, dst_ip[15:0]};
    sum  = (sum & 32'hFFFF) + (sum >> 16);
    sum  = (sum & 32'hFFFF) + (sum >> 16);
    return ~sum[15:0];
  endfunction

  function automatic logic [31:0] pick32(
      input logic        use_meta,
      input logic [31:0] meta_v,
      input logic [31:0] csr_v
  );
    return (use_meta && (meta_v != 32'd0)) ? meta_v : csr_v;
  endfunction

  function automatic logic [15:0] pick16(
      input logic        use_meta,
      input logic [15:0] meta_v,
      input logic [15:0] csr_v
  );
    return (use_meta && (meta_v != 16'd0)) ? meta_v : csr_v;
  endfunction

  // -------------------------------------------------------------------------
  // Symbol enable bitmap
  // -------------------------------------------------------------------------
  logic r_filt [0:CAM_DEPTH-1];

  integer fi_filt;
  always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      for (fi_filt = 0; fi_filt < CAM_DEPTH; fi_filt = fi_filt + 1)
        r_filt[fi_filt] <= 1'b0;
    end else if (filt_we) begin
      r_filt[filt_addr] <= filt_bit;
    end
  end

  // -------------------------------------------------------------------------
  // Event filter / rate (producer-facing, before UDP lock)
  // -------------------------------------------------------------------------
  event_t ev_in;
  assign ev_in = event_t'(s_event_tdata);

  logic w_sym_ok;
  logic w_ch_ok;
  logic w_filt_ok;
  assign w_sym_ok  = (ev_in.symbol_id < 16'(CAM_DEPTH)) && r_filt[ev_in.symbol_id[12:0]];
  assign w_ch_ok   = (ev_in.ch < 4'd8) &&
                     ((cfg_ch_mask & (8'b1 << ev_in.ch[2:0])) != 8'd0);
  assign w_filt_ok = w_sym_ok && w_ch_ok;

  typedef enum logic [0:0] {
    ST_IDLE = 1'b0,
    ST_TX   = 1'b1
  } state_e;

  state_e cs_state;
  state_e ns_state;

  logic w_busy;
  assign w_busy = (cs_state != ST_IDLE);

  logic [15:0] r_tokens;
  logic [15:0] r_period_cnt;
  logic        w_rate_unlimited;
  logic        w_rate_ok;
  assign w_rate_unlimited = (cfg_period == 16'd0);
  assign w_rate_ok        = w_rate_unlimited || (r_tokens != 16'd0);

  logic w_cand;
  logic w_drop_filt_fire;
  logic w_drop_rate_fire;
  assign w_cand           = s_event_tvalid && w_filt_ok && w_rate_ok && !w_busy;
  assign w_drop_filt_fire = s_event_tvalid && !w_filt_ok;
  assign w_drop_rate_fire = s_event_tvalid && w_filt_ok && (!w_rate_ok || w_busy);

  // -------------------------------------------------------------------------
  // Lock meta (CSR defaults; SOP meta overrides). ttl==0 → 1.
  // -------------------------------------------------------------------------
  logic [31:0] w_lock_dip;
  logic [31:0] w_lock_sip;
  logic [15:0] w_lock_sport;
  logic [15:0] w_lock_dport;
  logic [7:0]  w_lock_ttl_raw;
  logic [7:0]  w_lock_ttl;
  logic [15:0] w_lock_pay_len;
  logic        w_lock_is_mcast;
  logic [15:0] w_mtu;

  assign w_lock_dip      = pick32(i_s_udp_meta_valid, i_s_udp_dst_ip, cfg_dst_ip);
  assign w_lock_sip      = pick32(i_s_udp_meta_valid, i_s_udp_src_ip, cfg_src_ip);
  assign w_lock_sport    = pick16(i_s_udp_meta_valid, i_s_udp_sport, cfg_udp_sport);
  assign w_lock_dport    = pick16(i_s_udp_meta_valid, i_s_udp_dport, cfg_udp_dport);
  assign w_lock_ttl_raw  = i_s_udp_meta_valid ? i_s_udp_ttl : cfg_ttl_default;
  assign w_lock_ttl      = (w_lock_ttl_raw == 8'd0) ? 8'd1 : w_lock_ttl_raw;
  assign w_lock_pay_len  = (i_s_udp_meta_valid && (i_s_udp_payload_len != 16'd0))
                           ? i_s_udp_payload_len : 16'(MAX_PAY);
  assign w_lock_is_mcast = i_s_udp_meta_valid ? i_s_udp_is_mcast : 1'b1;
  assign w_mtu           = (cfg_mtu_pay == 16'd0) ? 16'd1472 : cfg_mtu_pay;

  // Event adapter: one event beat == MAX_PAY UDP payload bytes.
  logic [15:0] w_actual_len;
  assign w_actual_len = 16'(MAX_PAY);

  logic        w_gate_mcast;
  logic        w_gate_sa;
  logic        w_gate_len;
  logic        w_gate_map;
  logic        w_gate_mtu;
  logic        w_gate_ok;
  logic        w_drop_gate_fire;
  logic        w_accept_tx;

  assign w_gate_mcast = w_lock_is_mcast && (w_lock_dip[31:28] == 4'hE);
  assign w_gate_sa    = (w_lock_sip[31:28] != 4'hE);
  assign w_gate_len   = (w_lock_pay_len == w_actual_len);
  // SPEC: docs/udp-mcast-tx-design.md §3 map gate
  assign w_gate_map   = cfg_map_en ? 1'b1
                                   : (cfg_dst_mac == rfc1112_da(w_lock_dip));
  assign w_gate_mtu   = (w_lock_pay_len != 16'd0) && (w_lock_pay_len <= w_mtu) &&
                        (w_lock_pay_len <= 16'(MAX_PAY));
  assign w_gate_ok    = w_gate_mcast && w_gate_sa && w_gate_len &&
                        w_gate_map && w_gate_mtu;

  assign w_drop_gate_fire = w_cand && !w_gate_ok;
  assign w_accept_tx      = w_cand &&  w_gate_ok;

  logic [47:0] w_da;
  assign w_da            = rfc1112_da(w_lock_dip);
  assign o_stat_dst_mac  = rfc1112_da(cfg_dst_ip);

  logic [15:0] w_udp_len;
  logic [15:0] w_ip_total;
  logic [15:0] w_frame_bytes;
  logic [3:0]  w_n_beats;
  assign w_udp_len     = 16'd8 + w_lock_pay_len;
  assign w_ip_total    = 16'd20 + w_udp_len;
  assign w_frame_bytes = 16'(HDR_BYTES) + w_lock_pay_len;
  assign w_n_beats     = 4'((w_frame_bytes + 16'd7) >> 3);

  logic w_tx_last;
  logic [3:0] r_beat;
  logic [3:0] r_n_beats;
  assign w_tx_last = (r_beat == (r_n_beats - 4'd1));

  // -------------------------------------------------------------------------
  // FSM — first process (cs only) / second process (ns only)
  // SPEC: udp-mcast-tx-design (frozen) lock→gate→fill→egress
  // -------------------------------------------------------------------------
  always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
      cs_state <= ST_IDLE;
    else
      cs_state <= ns_state;
  end

  always_comb begin
    ns_state = cs_state;
    case (cs_state)
      ST_IDLE: begin
        if (w_accept_tx)
          ns_state = ST_TX;
      end
      ST_TX: begin
        if (m_axis_tready && w_tx_last)
          ns_state = ST_IDLE;
      end
      default: ns_state = ST_IDLE;
    endcase
  end

  logic w_illegal_cs;
  assign w_illegal_cs = (cs_state != ST_IDLE) && (cs_state != ST_TX);

  assign o_dbg_cs_state = cs_state;

  // -------------------------------------------------------------------------
  // Token bucket (refill then optional consume on a gate-pass send)
  // -------------------------------------------------------------------------
  always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      r_tokens     <= 16'd0;
      r_period_cnt <= 16'd0;
    end else begin
      logic [15:0] t_next;
      logic [15:0] p_next;
      t_next = r_tokens;
      p_next = r_period_cnt;

      if (w_rate_unlimited) begin
        p_next = 16'd0;
        t_next = 16'hFFFF;
      end else if (r_period_cnt >= (cfg_period - 16'd1)) begin
        p_next = 16'd0;
        t_next = sat_add16(t_next, cfg_refill);
      end else begin
        p_next = r_period_cnt + 16'd1;
      end

      if (w_accept_tx && !w_rate_unlimited && (t_next != 16'd0))
        t_next = t_next - 16'd1;

      r_tokens     <= t_next;
      r_period_cnt <= p_next;
    end
  end

  // -------------------------------------------------------------------------
  // Counters + sticky (gate/illegal). nosend = consumed and not transmitted.
  // -------------------------------------------------------------------------
  logic [31:0] r_c_tx;
  logic [31:0] r_c_filt;
  logic [31:0] r_c_rate;
  logic [31:0] r_c_gate;
  logic [31:0] r_c_nosend;
  logic        r_err_sticky;

  assign tx_ok           = r_c_tx;
  assign drop_filt       = r_c_filt;
  assign drop_rate       = r_c_rate;
  assign o_drop_gate     = r_c_gate;
  assign o_nosend        = r_c_nosend;
  assign o_dbg_err_sticky = r_err_sticky;

  always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      r_c_tx      <= 32'd0;
      r_c_filt    <= 32'd0;
      r_c_rate    <= 32'd0;
      r_c_gate    <= 32'd0;
      r_c_nosend  <= 32'd0;
      r_err_sticky <= 1'b0;
    end else begin
      if (w_drop_filt_fire)
        r_c_filt <= sat_inc(r_c_filt);
      if (w_drop_rate_fire)
        r_c_rate <= sat_inc(r_c_rate);
      if (w_drop_gate_fire)
        r_c_gate <= sat_inc(r_c_gate);
      if (w_drop_filt_fire || w_drop_rate_fire || w_drop_gate_fire)
        r_c_nosend <= sat_inc(r_c_nosend);
      if (w_accept_tx)
        r_c_tx <= sat_inc(r_c_tx);
      if (w_drop_gate_fire || w_illegal_cs)
        r_err_sticky <= 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // Fill Ethernet/IPv4/UDP (derived DA/lengths/csum) and stream beats
  // -------------------------------------------------------------------------
  logic [63:0] r_frame [0:MAX_BEATS-1];
  logic [7:0]  r_keep  [0:MAX_BEATS-1];

  assign m_axis_tvalid = (cs_state == ST_TX);
  assign m_axis_tdata  = r_frame[r_beat];
  assign m_axis_tkeep  = r_keep[r_beat];
  assign m_axis_tlast  = w_tx_last;

  always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      r_beat    <= 4'd0;
      r_n_beats <= 4'(MAX_BEATS);
      for (int fi_frm = 0; fi_frm < MAX_BEATS; fi_frm = fi_frm + 1) begin
        r_frame[fi_frm] <= 64'd0;
        r_keep[fi_frm]  <= 8'd0;
      end
    end else begin
      logic [7:0]  fb [0:MAX_FRAME-1];
      logic [15:0] csum;
      logic [63:0] dtmp;
      logic [7:0]  ktmp;
      logic [47:0] da;
      integer i, bi, base, nb, j, nbytes;

      if (w_accept_tx) begin
        csum = ipv4_hdr_csum(w_lock_sip, w_lock_dip, w_ip_total, w_lock_ttl);
        da   = w_da;
        nbytes = int'(w_frame_bytes);

        for (i = 0; i < MAX_FRAME; i = i + 1)
          fb[i] = 8'd0;

        fb[0]  = da[47:40];
        fb[1]  = da[39:32];
        fb[2]  = da[31:24];
        fb[3]  = da[23:16];
        fb[4]  = da[15:8];
        fb[5]  = da[7:0];
        fb[6]  = cfg_src_mac[47:40];
        fb[7]  = cfg_src_mac[39:32];
        fb[8]  = cfg_src_mac[31:24];
        fb[9]  = cfg_src_mac[23:16];
        fb[10] = cfg_src_mac[15:8];
        fb[11] = cfg_src_mac[7:0];
        fb[12] = 8'h08;
        fb[13] = 8'h00;

        fb[14] = 8'h45;
        fb[15] = 8'h00;
        fb[16] = w_ip_total[15:8];
        fb[17] = w_ip_total[7:0];
        fb[18] = 8'h00;
        fb[19] = 8'h00;
        fb[20] = 8'h00;
        fb[21] = 8'h00;
        fb[22] = w_lock_ttl;
        fb[23] = 8'h11;
        fb[24] = csum[15:8];
        fb[25] = csum[7:0];
        fb[26] = w_lock_sip[31:24];
        fb[27] = w_lock_sip[23:16];
        fb[28] = w_lock_sip[15:8];
        fb[29] = w_lock_sip[7:0];
        fb[30] = w_lock_dip[31:24];
        fb[31] = w_lock_dip[23:16];
        fb[32] = w_lock_dip[15:8];
        fb[33] = w_lock_dip[7:0];

        fb[34] = w_lock_sport[15:8];
        fb[35] = w_lock_sport[7:0];
        fb[36] = w_lock_dport[15:8];
        fb[37] = w_lock_dport[7:0];
        fb[38] = w_udp_len[15:8];
        fb[39] = w_udp_len[7:0];
        fb[40] = 8'h00;
        fb[41] = 8'h00;

        for (i = 0; i < MAX_PAY; i = i + 1)
          if (i < int'(w_lock_pay_len))
            fb[HDR_BYTES + i] = s_event_tdata[8 * i +: 8];

        for (bi = 0; bi < MAX_BEATS; bi = bi + 1) begin
          base = bi * 8;
          nb   = ((base + 8) <= nbytes) ? 8 : ((base < nbytes) ? (nbytes - base) : 0);
          dtmp = 64'd0;
          ktmp = 8'd0;
          for (j = 0; j < 8; j = j + 1) begin
            if (j < nb) begin
              dtmp[8 * j +: 8] = fb[base + j];
              ktmp[j]          = 1'b1;
            end
          end
          r_frame[bi] <= dtmp;
          r_keep[bi]  <= ktmp;
        end

        r_beat    <= 4'd0;
        r_n_beats <= w_n_beats;
      end else if (cs_state == ST_TX) begin
        if (m_axis_tready) begin
          if (!w_tx_last)
            r_beat <= r_beat + 4'd1;
          else
            r_beat <= 4'd0;
        end
      end
    end
  end

endmodule

`default_nettype wire
