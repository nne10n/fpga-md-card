// -----------------------------------------------------------------------------
// mcast_eng.sv — Per-client multicast TX engine (M5, N=1 sim)
//
// Input : event AXIS-512 (single-beat). s_event_tready tied 1 — never
//         backpressure the event bus; filter/rate/busy drops are counted.
// Filter: 8192-bit enable vector[symbol_id[12:0]] AND ch_mask & (1<<ch).
// Rate  : token bucket — +cfg_refill every cfg_period cycles (cfg_period==0
//         disables limiting); send costs 1 token.
// Output: Ethernet/IPv4/UDP frame on AXIS-64 (wire byte0 = tdata[7:0]).
//         Payload = entire event_t as 64 LE bytes (event[7:0] first).
//         UDP checksum = 0; IPv4 header checksum computed in RTL.
//         No VLAN, no FCS. Store-and-forward one frame.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

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
  input  logic [47:0]  cfg_dst_mac,
  input  logic [31:0]  cfg_src_ip,
  input  logic [31:0]  cfg_dst_ip,
  input  logic [15:0]  cfg_udp_sport,
  input  logic [15:0]  cfg_udp_dport,
  input  logic [7:0]   cfg_ch_mask,
  input  logic [15:0]  cfg_period,
  input  logic [15:0]  cfg_refill,

  input  logic         filt_we,
  input  logic [12:0]  filt_addr,
  input  logic         filt_bit,

  output logic [31:0]  tx_ok,
  output logic [31:0]  drop_filt,
  output logic [31:0]  drop_rate
);

  logic unused_cid;
  logic unused_tlast;
  assign unused_cid   = (CLIENT_ID == 0) ? 1'b0 : 1'b1;
  assign unused_tlast = s_event_tlast;

  assign s_event_tready = 1'b1;

  localparam int unsigned FRAME_BYTES = 106; // 14 eth + 20 ip + 8 udp + 64 pay
  localparam int unsigned N_BEATS     = 14;  // last beat: 2 bytes
  localparam logic [15:0] IP_TOTAL    = 16'd92;
  localparam logic [15:0] UDP_LEN     = 16'd72;

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

  function automatic logic [15:0] ipv4_hdr_csum(
      input logic [31:0] src_ip,
      input logic [31:0] dst_ip
  );
    logic [31:0] sum;
    sum  = 32'h4500;
    sum += {16'd0, IP_TOTAL};
    sum += 32'h0000;
    sum += 32'h0000;
    sum += 32'h4011;
    sum += {16'd0, src_ip[31:16]};
    sum += {16'd0, src_ip[15:0]};
    sum += {16'd0, dst_ip[31:16]};
    sum += {16'd0, dst_ip[15:0]};
    sum  = (sum & 32'hFFFF) + (sum >> 16);
    sum  = (sum & 32'hFFFF) + (sum >> 16);
    return ~sum[15:0];
  endfunction

  // -------------------------------------------------------------------------
  // Symbol enable bitmap
  // -------------------------------------------------------------------------
  (* RAM_STYLE = "distributed" *) logic [CAM_DEPTH-1:0] filt_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      filt_q <= {CAM_DEPTH{1'b0}};
    end else if (filt_we) begin
      filt_q[filt_addr] <= filt_bit;
    end
  end

  // -------------------------------------------------------------------------
  // Filter / rate / busy decision
  // -------------------------------------------------------------------------
  event_t ev_in;
  assign ev_in = event_t'(s_event_tdata);

  wire sym_ok  = (ev_in.symbol_id < 16'(CAM_DEPTH)) && filt_q[ev_in.symbol_id[12:0]];
  wire ch_ok   = (ev_in.ch < 4'd8) &&
                 ((cfg_ch_mask & (8'b1 << ev_in.ch[2:0])) != 8'd0);
  wire filt_ok = sym_ok && ch_ok;

  typedef enum logic [0:0] {
    ST_IDLE = 1'b0,
    ST_TX   = 1'b1
  } state_e;

  state_e      st_q;
  logic [3:0]  beat_q;
  logic [63:0] frame_q [0:N_BEATS-1];
  logic [7:0]  keep_q  [0:N_BEATS-1];

  wire busy = (st_q != ST_IDLE);

  logic [15:0] tokens_q;
  logic [15:0] period_cnt_q;
  wire rate_unlimited = (cfg_period == 16'd0);
  wire rate_ok = rate_unlimited || (tokens_q != 16'd0);

  wire accept_fire    = s_event_tvalid && filt_ok && rate_ok && !busy;
  wire drop_filt_fire = s_event_tvalid && !filt_ok;
  wire drop_rate_fire = s_event_tvalid && filt_ok && (!rate_ok || busy);

  // -------------------------------------------------------------------------
  // Token bucket (refill then optional consume)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tokens_q     <= 16'd0;
      period_cnt_q <= 16'd0;
    end else begin
      logic [15:0] t_next;
      logic [15:0] p_next;
      t_next = tokens_q;
      p_next = period_cnt_q;

      if (rate_unlimited) begin
        p_next = 16'd0;
        t_next = 16'hFFFF;
      end else if (period_cnt_q >= (cfg_period - 16'd1)) begin
        p_next = 16'd0;
        t_next = sat_add16(t_next, cfg_refill);
      end else begin
        p_next = period_cnt_q + 16'd1;
      end

      if (accept_fire && !rate_unlimited && (t_next != 16'd0))
        t_next = t_next - 16'd1;

      tokens_q     <= t_next;
      period_cnt_q <= p_next;
    end
  end

  // -------------------------------------------------------------------------
  // Counters + frame build + TX
  // -------------------------------------------------------------------------
  logic [31:0] c_tx_q, c_filt_q, c_rate_q;
  assign tx_ok     = c_tx_q;
  assign drop_filt = c_filt_q;
  assign drop_rate = c_rate_q;

  assign m_axis_tvalid = (st_q == ST_TX);
  assign m_axis_tdata  = frame_q[beat_q];
  assign m_axis_tkeep  = keep_q[beat_q];
  assign m_axis_tlast  = (beat_q == 4'(N_BEATS - 1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q     <= ST_IDLE;
      beat_q   <= 4'd0;
      c_tx_q   <= 32'd0;
      c_filt_q <= 32'd0;
      c_rate_q <= 32'd0;
      for (int fi = 0; fi < N_BEATS; fi = fi + 1) begin
        frame_q[fi] <= 64'd0;
        keep_q[fi]  <= 8'd0;
      end
    end else begin
      logic [7:0]  fb [0:FRAME_BYTES-1];
      logic [15:0] csum;
      logic [63:0] dtmp;
      logic [7:0]  ktmp;
      integer i, bi, base, nb, j;

      if (drop_filt_fire)
        c_filt_q <= sat_inc(c_filt_q);
      if (drop_rate_fire)
        c_rate_q <= sat_inc(c_rate_q);

      if (accept_fire) begin
        csum = ipv4_hdr_csum(cfg_src_ip, cfg_dst_ip);

        fb[0]  = cfg_dst_mac[47:40];
        fb[1]  = cfg_dst_mac[39:32];
        fb[2]  = cfg_dst_mac[31:24];
        fb[3]  = cfg_dst_mac[23:16];
        fb[4]  = cfg_dst_mac[15:8];
        fb[5]  = cfg_dst_mac[7:0];
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
        fb[16] = IP_TOTAL[15:8];
        fb[17] = IP_TOTAL[7:0];
        fb[18] = 8'h00;
        fb[19] = 8'h00;
        fb[20] = 8'h00;
        fb[21] = 8'h00;
        fb[22] = 8'h40;
        fb[23] = 8'h11;
        fb[24] = csum[15:8];
        fb[25] = csum[7:0];
        fb[26] = cfg_src_ip[31:24];
        fb[27] = cfg_src_ip[23:16];
        fb[28] = cfg_src_ip[15:8];
        fb[29] = cfg_src_ip[7:0];
        fb[30] = cfg_dst_ip[31:24];
        fb[31] = cfg_dst_ip[23:16];
        fb[32] = cfg_dst_ip[15:8];
        fb[33] = cfg_dst_ip[7:0];

        fb[34] = cfg_udp_sport[15:8];
        fb[35] = cfg_udp_sport[7:0];
        fb[36] = cfg_udp_dport[15:8];
        fb[37] = cfg_udp_dport[7:0];
        fb[38] = UDP_LEN[15:8];
        fb[39] = UDP_LEN[7:0];
        fb[40] = 8'h00;
        fb[41] = 8'h00;

        for (i = 0; i < 64; i = i + 1)
          fb[42 + i] = s_event_tdata[8 * i +: 8];

        for (bi = 0; bi < N_BEATS; bi = bi + 1) begin
          base = bi * 8;
          nb   = ((base + 8) <= FRAME_BYTES) ? 8 : (FRAME_BYTES - base);
          dtmp = 64'd0;
          ktmp = 8'd0;
          for (j = 0; j < 8; j = j + 1) begin
            if (j < nb) begin
              dtmp[8 * j +: 8] = fb[base + j];
              ktmp[j]          = 1'b1;
            end
          end
          frame_q[bi] <= dtmp;
          keep_q[bi]  <= ktmp;
        end

        st_q   <= ST_TX;
        beat_q <= 4'd0;
        c_tx_q <= sat_inc(c_tx_q);
      end else if (st_q == ST_TX) begin
        if (m_axis_tready) begin
          if (beat_q == 4'(N_BEATS - 1)) begin
            st_q   <= ST_IDLE;
            beat_q <= 4'd0;
          end else begin
            beat_q <= beat_q + 4'd1;
          end
        end
      end
    end
  end

endmodule
