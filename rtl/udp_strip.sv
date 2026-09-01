// -----------------------------------------------------------------------------
// udp_strip.sv — Cut-through Eth/IPv4/UDP header strip → payload AXIS-64
// Wire byte 0 in tdata[7:0]. s_axis_tready tied 1. No L3/L4 checksum checks.
// Extra counter drop_filter: dest MAC/IP/UDP-port filter miss (not proto/IHL).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module udp_strip
  import md_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [47:0] cfg_dst_mac,
  input  logic [31:0] cfg_dst_ip,
  input  logic [15:0] cfg_udp_dport,

  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,
  input  eth_tuser_t  s_axis_tuser,

  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,
  output pay_tuser_t  m_axis_tuser,

  output logic [31:0] drop_not_udp,
  output logic [31:0] drop_opt,
  output logic [31:0] drop_filter,
  output logic [31:0] frames_ok
);

  assign s_axis_tready = 1'b1;

  localparam int unsigned HDR_LEN = 42;

  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_HDR   = 3'd1,
    ST_PASS  = 3'd2,
    ST_DRAIN = 3'd3,
    ST_DROP  = 3'd4
  } state_e;

  state_e state_q;

  logic [7:0]  hdr_q   [0:HDR_LEN-1];
  logic [5:0]  hdr_n_q;
  logic [15:0] pay_rem_q;
  logic [15:0] dport_q;
  eth_tuser_t  tuser_q;

  logic [7:0]  pend_q  [0:7];
  logic [3:0]  pend_n_q;

  // 2-deep output skid (realign can produce 2 beats per input beat)
  logic [63:0] odata_q [0:1];
  logic [7:0]  okeep_q [0:1];
  logic        olast_q [0:1];
  pay_tuser_t  otuser_q[0:1];
  logic [1:0]  ocount_q; // 0..2

  logic [31:0] c_not_udp_q;
  logic [31:0] c_opt_q;
  logic [31:0] c_filt_q;
  logic [31:0] c_ok_q;

  assign drop_not_udp = c_not_udp_q;
  assign drop_opt     = c_opt_q;
  assign drop_filter  = c_filt_q;
  assign frames_ok    = c_ok_q;

  assign m_axis_tvalid = (ocount_q != 2'd0);
  assign m_axis_tdata  = odata_q[0];
  assign m_axis_tkeep  = okeep_q[0];
  assign m_axis_tlast  = olast_q[0];
  assign m_axis_tuser  = otuser_q[0];

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic mac_accept(
      input logic [7:0] b0, b1, b2, b3, b4, b5
  );
    logic [47:0] dst;
    dst = {b0, b1, b2, b3, b4, b5};
    return (dst == cfg_dst_mac) ||
           (dst == 48'hFFFF_FFFF_FFFF) ||
           (b0[0] == 1'b1);
  endfunction

  // why: 0=ok 1=not_udp 2=opt 3=filter
  function automatic logic [1:0] classify_hdr(
      input  logic [7:0] h [0:HDR_LEN-1],
      output logic [15:0] dport_o,
      output logic [15:0] pay_len_o
  );
    logic [15:0] etype;
    logic [3:0]  ihl;
    logic [3:0]  ver;
    logic [7:0]  proto;
    logic [31:0] dip;
    logic [15:0] dport;
    logic [15:0] ulen;
    etype = {h[12], h[13]};
    ver   = h[14][7:4];
    ihl   = h[14][3:0];
    proto = h[23];
    dip   = {h[30], h[31], h[32], h[33]};
    dport = {h[36], h[37]};
    ulen  = {h[38], h[39]};
    dport_o   = dport;
    pay_len_o = (ulen >= 16'd8) ? (ulen - 16'd8) : 16'd0;

    if (etype != 16'h0800 || ver != 4'd4)
      return 2'd1;
    if (ihl > 4'd5)
      return 2'd2;
    if (ihl < 4'd5)
      return 2'd1;
    if (proto != 8'd17 || ulen < 16'd8)
      return 2'd1;
    if (!mac_accept(h[0], h[1], h[2], h[3], h[4], h[5]) ||
        dip != cfg_dst_ip ||
        (cfg_udp_dport != 16'd0 && dport != cfg_udp_dport))
      return 2'd3;
    return 2'd0;
  endfunction

  integer i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= ST_IDLE;
      hdr_n_q     <= '0;
      pay_rem_q   <= '0;
      dport_q     <= '0;
      tuser_q     <= '0;
      pend_n_q    <= '0;
      ocount_q    <= '0;
      c_not_udp_q <= '0;
      c_opt_q     <= '0;
      c_filt_q    <= '0;
      c_ok_q      <= '0;
      for (i = 0; i < HDR_LEN; i++)
        hdr_q[i] <= '0;
      for (i = 0; i < 8; i++)
        pend_q[i] <= '0;
      for (i = 0; i < 2; i++) begin
        odata_q[i]  <= '0;
        okeep_q[i]  <= '0;
        olast_q[i]  <= 1'b0;
        otuser_q[i] <= '0;
      end
    end else begin
      automatic logic [1:0] oc = ocount_q;
      automatic logic [63:0] od0 = odata_q[0], od1 = odata_q[1];
      automatic logic [7:0]  ok0 = okeep_q[0], ok1 = okeep_q[1];
      automatic logic        ol0 = olast_q[0], ol1 = olast_q[1];
      automatic pay_tuser_t  ou0 = otuser_q[0], ou1 = otuser_q[1];

      // Pop front if downstream ready
      if (oc != 2'd0 && m_axis_tready) begin
        od0 = od1;
        ok0 = ok1;
        ol0 = ol1;
        ou0 = ou1;
        od1 = '0;
        ok1 = '0;
        ol1 = 1'b0;
        ou1 = '0;
        oc  = oc - 2'd1;
      end

      if (s_axis_tvalid) begin
        automatic state_e      st = state_q;
        automatic logic [5:0]  hn = hdr_n_q;
        automatic logic [3:0]  pn = pend_n_q;
        automatic logic [15:0] pr = pay_rem_q;
        automatic logic [15:0] dp = dport_q;
        automatic eth_tuser_t  tu = tuser_q;
        automatic logic [7:0]  htmp [0:HDR_LEN-1];
        automatic logic [7:0]  ptmp [0:7];
        automatic logic        go_drop = 1'b0;
        automatic logic [1:0]  why = 2'd0;
        automatic logic        hdr_just_done = 1'b0;
        automatic logic [15:0] plen = 16'd0;
        automatic logic        bp_fail = 1'b0;
        automatic pay_tuser_t  pu;

        for (i = 0; i < HDR_LEN; i++)
          htmp[i] = hdr_q[i];
        for (i = 0; i < 8; i++)
          ptmp[i] = pend_q[i];

        if (st == ST_IDLE) begin
          tu = s_axis_tuser;
          hn = '0;
          pn = '0;
          pr = '0;
          for (i = 0; i < HDR_LEN; i++)
            htmp[i] = '0;
          for (i = 0; i < 8; i++)
            ptmp[i] = '0;
          st = ST_HDR;
        end

        pu.port_id   = tu.port_id;
        pu.sop_ts    = tu.sop_ts;
        pu.udp_dport = dp;
        pu.l4_prot   = 8'd17;
        pu.from_tcp  = 1'b0;

        for (i = 0; i < 8; i++) begin
          if (s_axis_tkeep[i]) begin
            automatic logic [7:0] b = s_axis_tdata[i*8 +: 8];

            if (st == ST_HDR) begin
              if (hn < HDR_LEN[5:0]) begin
                htmp[hn] = b;
                hn = hn + 6'd1;
                if (hn == HDR_LEN[5:0]) begin
                  why = classify_hdr(htmp, dp, plen);
                  hdr_just_done = 1'b1;
                  pu.udp_dport = dp;
                  if (why != 2'd0) begin
                    go_drop = 1'b1;
                    st = ST_DROP;
                  end else begin
                    pr = plen;
                    if (pr == 16'd0)
                      st = ST_DRAIN;
                    else
                      st = ST_PASS;
                  end
                end
              end
            end else if (st == ST_PASS) begin
              if (pr != 16'd0) begin
                automatic logic is_last = (pr == 16'd1);
                automatic logic [63:0] ed;
                automatic logic [7:0]  ek;
                automatic integer k;
                ptmp[pn] = b;
                pn = pn + 4'd1;
                pr = pr - 16'd1;
                if (pn == 4'd8 || is_last) begin
                  ed = '0;
                  ek = '0;
                  for (k = 0; k < 8; k++) begin
                    if (k < pn) begin
                      ed[k*8 +: 8] = ptmp[k];
                      ek[k] = 1'b1;
                    end
                  end
                  // Push to skid; if full and can't take → drop rest of frame
                  if (oc >= 2'd2) begin
                    bp_fail = 1'b1;
                    st = ST_DROP;
                  end else begin
                    if (oc == 2'd0) begin
                      od0 = ed;
                      ok0 = ek;
                      ol0 = is_last;
                      ou0 = pu;
                    end else begin
                      od1 = ed;
                      ok1 = ek;
                      ol1 = is_last;
                      ou1 = pu;
                    end
                    oc = oc + 2'd1;
                  end
                  pn = 4'd0;
                end
                if (is_last && !bp_fail)
                  st = ST_DRAIN;
              end
            end
          end
        end

        if (s_axis_tlast) begin
          if (st == ST_HDR && !hdr_just_done) begin
            c_not_udp_q <= sat_inc(c_not_udp_q);
          end else if (go_drop) begin
            if (why == 2'd1)      c_not_udp_q <= sat_inc(c_not_udp_q);
            else if (why == 2'd2) c_opt_q     <= sat_inc(c_opt_q);
            else                  c_filt_q    <= sat_inc(c_filt_q);
          end else if (bp_fail) begin
            // abandoned due to backpressure; no counter required
          end else if (st == ST_PASS || st == ST_DRAIN ||
                       (hdr_just_done && why == 2'd0)) begin
            // Flush residual pend (partial last beat not already emitted)
            if (pn != 4'd0) begin
              automatic logic [63:0] ed = '0;
              automatic logic [7:0]  ek = '0;
              automatic integer k;
              for (k = 0; k < 8; k++) begin
                if (k < pn) begin
                  ed[k*8 +: 8] = ptmp[k];
                  ek[k] = 1'b1;
                end
              end
              if (oc < 2'd2) begin
                if (oc == 2'd0) begin
                  od0 = ed; ok0 = ek; ol0 = 1'b1; ou0 = pu;
                end else begin
                  od1 = ed; ok1 = ek; ol1 = 1'b1; ou1 = pu;
                end
                oc = oc + 2'd1;
              end
            end
            c_ok_q <= sat_inc(c_ok_q);
          end
          st = ST_IDLE;
          hn = '0;
          pn = '0;
          pr = '0;
        end else if (go_drop) begin
          if (why == 2'd1)      c_not_udp_q <= sat_inc(c_not_udp_q);
          else if (why == 2'd2) c_opt_q     <= sat_inc(c_opt_q);
          else                  c_filt_q    <= sat_inc(c_filt_q);
        end

        state_q   <= st;
        hdr_n_q   <= hn;
        pend_n_q  <= pn;
        pay_rem_q <= pr;
        dport_q   <= dp;
        tuser_q   <= tu;
        for (i = 0; i < HDR_LEN; i++)
          hdr_q[i] <= htmp[i];
        for (i = 0; i < 8; i++)
          pend_q[i] <= ptmp[i];
      end

      ocount_q    <= oc;
      odata_q[0]  <= od0;
      odata_q[1]  <= od1;
      okeep_q[0]  <= ok0;
      okeep_q[1]  <= ok1;
      olast_q[0]  <= ol0;
      olast_q[1]  <= ol1;
      otuser_q[0] <= ou0;
      otuser_q[1] <= ou1;
    end
  end

endmodule
