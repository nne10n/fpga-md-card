// -----------------------------------------------------------------------------
// arb_nway.sv — Post-decode A/B(+TCP) sequence arbiter (M3)
//
// Inputs : port A, B, TCP (optional backfill) — event AXIS 512b + code[47:0]
// Output : one event AXIS + m_code (muxed from winning source)
// Key    : event.seq + event.ch  (same exch assumed per instance)
// State  : expect_seq[N_CH] flop array (combo read; 1-cycle registered emit)
//
// Rules (module-design-v1 §3.2):
//   1. seq == expect → forward, expect++
//   2. seq <  expect → drop (A/B → drop_dup; TCP → drop_tcp)
//   3. seq >  expect → forward + F_GAP, expect = seq+1
//   4. TCP: OR F_FROM_TCP; if seq already taken (seq < expect) drop
// Flags  : clear F_WINNER_B/F_FROM_TCP/F_GAP from input, then OR by source/gap
// Tie    : A before B before TCP (deterministic)
// Backpress: 1-deep input skid; hold selected skid if forward and out full
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module arb_nway
  import md_pkg::*;
#(
  parameter int N_CH = 16
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [511:0] s_a_tdata,
  input  logic         s_a_tvalid,
  input  logic         s_a_tlast,
  output logic         s_a_tready,
  input  logic [47:0]  s_a_code,

  input  logic [511:0] s_b_tdata,
  input  logic         s_b_tvalid,
  input  logic         s_b_tlast,
  output logic         s_b_tready,
  input  logic [47:0]  s_b_code,

  input  logic [511:0] s_tcp_tdata,
  input  logic         s_tcp_tvalid,
  input  logic         s_tcp_tlast,
  output logic         s_tcp_tready,
  input  logic [47:0]  s_tcp_code,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  logic         m_event_tready,
  output logic [47:0]  m_code,

  output logic [31:0]  fwd,
  output logic [31:0]  drop_dup,
  output logic [31:0]  drop_tcp,
  output logic [31:0]  gap
);

  // Unused tlast (events are single-beat); keep ports for AXIS shape
  logic unused_tlast;
  assign unused_tlast = s_a_tlast ^ s_b_tlast ^ s_tcp_tlast;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  // ch[3:0] indexes 0..15; if N_CH < 16, wrap
  function automatic logic [3:0] ch_index(input logic [3:0] ch);
    if (N_CH >= 16)
      return ch;
    else
      return ch % 4'(N_CH);
  endfunction

  // -------------------------------------------------------------------------
  // 1-deep input skids
  // -------------------------------------------------------------------------
  localparam int N_PORTS = 3;

  logic [511:0] sk_data_q  [0:N_PORTS-1];
  logic [47:0]  sk_code_q  [0:N_PORTS-1];
  logic         sk_valid_q [0:N_PORTS-1];

  logic [511:0] in_tdata  [0:N_PORTS-1];
  logic [47:0]  in_code   [0:N_PORTS-1];
  logic         in_tvalid [0:N_PORTS-1];
  logic         in_tready [0:N_PORTS-1];

  assign in_tdata[0]  = s_a_tdata;
  assign in_code[0]   = s_a_code;
  assign in_tvalid[0] = s_a_tvalid;
  assign s_a_tready   = in_tready[0];

  assign in_tdata[1]  = s_b_tdata;
  assign in_code[1]   = s_b_code;
  assign in_tvalid[1] = s_b_tvalid;
  assign s_b_tready   = in_tready[1];

  assign in_tdata[2]  = s_tcp_tdata;
  assign in_code[2]   = s_tcp_code;
  assign in_tvalid[2] = s_tcp_tvalid;
  assign s_tcp_tready = in_tready[2];

  // -------------------------------------------------------------------------
  // Output register
  // -------------------------------------------------------------------------
  logic [511:0] out_data_q;
  logic [47:0]  out_code_q;
  logic         out_valid_q;

  assign m_event_tdata  = out_data_q;
  assign m_event_tvalid = out_valid_q;
  assign m_event_tlast  = 1'b1;
  assign m_code         = out_code_q;

  wire out_slot = !out_valid_q || m_event_tready;

  // -------------------------------------------------------------------------
  // expect_seq — init 1 (exchange seq typically starts at 1)
  // -------------------------------------------------------------------------
  logic [31:0] expect_q [0:N_CH-1];

  logic [31:0] c_fwd_q, c_dup_q, c_tcp_q, c_gap_q;
  assign fwd      = c_fwd_q;
  assign drop_dup = c_dup_q;
  assign drop_tcp = c_tcp_q;
  assign gap      = c_gap_q;

  // -------------------------------------------------------------------------
  // Select lowest ready skid (A > B > TCP). Process when drop, or forward
  // with a free output slot.
  // -------------------------------------------------------------------------
  logic         sel_valid;
  logic [1:0]   sel_port;
  logic [511:0] sel_data;
  logic [47:0]  sel_code;
  event_t       sel_ev;
  logic [3:0]   sel_ch;
  logic [31:0]  sel_seq;
  logic [31:0]  sel_expect;
  logic         is_dup;
  logic         is_gap;
  logic         is_match;
  logic         do_fwd;
  logic         do_drop;
  logic         can_fire;
  event_t       out_ev;
  logic [7:0]   flags_base;
  logic [7:0]   flags_new;
  logic [31:0]  expect_next;

  always_comb begin
    sel_valid = 1'b0;
    sel_port  = 2'd0;
    sel_data  = '0;
    sel_code  = '0;
    for (int i = 0; i < N_PORTS; i++) begin
      if (!sel_valid && sk_valid_q[i]) begin
        sel_valid = 1'b1;
        sel_port  = 2'(unsigned'(i));
        sel_data  = sk_data_q[i];
        sel_code  = sk_code_q[i];
      end
    end

    sel_ev     = event_t'(sel_data);
    sel_ch     = ch_index(sel_ev.ch);
    sel_seq    = sel_ev.seq;
    sel_expect = expect_q[sel_ch];

    is_match = sel_valid && (sel_seq == sel_expect);
    is_dup   = sel_valid && (sel_seq <  sel_expect);
    is_gap   = sel_valid && (sel_seq >  sel_expect);
    do_fwd   = is_match || is_gap;
    do_drop  = is_dup;

    can_fire = sel_valid && (do_drop || (do_fwd && out_slot));

    // flags: preserve non-arb bits; set source / gap
    flags_base = sel_ev.flags & ~(F_WINNER_B | F_FROM_TCP | F_GAP);
    flags_new  = flags_base;
    if (sel_port == 2'd1)
      flags_new = flags_new | F_WINNER_B;
    if (sel_port == 2'd2)
      flags_new = flags_new | F_FROM_TCP;
    if (is_gap)
      flags_new = flags_new | F_GAP;

    out_ev = sel_ev;
    out_ev.flags = flags_new;

    expect_next = is_gap ? (sel_seq + 32'd1) : (sel_expect + 32'd1);
  end

  // Skid ready / pop
  logic pop_sk [0:N_PORTS-1];
  always_comb begin
    for (int i = 0; i < N_PORTS; i++) begin
      pop_sk[i]    = can_fire && (sel_port == 2'(unsigned'(i)));
      in_tready[i] = !sk_valid_q[i] || pop_sk[i];
    end
  end

  // -------------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N_PORTS; i++) begin
        sk_valid_q[i] <= 1'b0;
        sk_data_q[i]  <= '0;
        sk_code_q[i]  <= '0;
      end
      for (int c = 0; c < N_CH; c++)
        expect_q[c] <= 32'd1;
      out_valid_q <= 1'b0;
      out_data_q  <= '0;
      out_code_q  <= '0;
      c_fwd_q <= '0;
      c_dup_q <= '0;
      c_tcp_q <= '0;
      c_gap_q <= '0;
    end else begin
      // Output drain / load
      if (out_valid_q && m_event_tready)
        out_valid_q <= 1'b0;

      // Process selected
      if (can_fire) begin
        if (do_fwd) begin
          out_data_q  <= out_ev;
          out_code_q  <= sel_code;
          out_valid_q <= 1'b1;
          expect_q[sel_ch] <= expect_next;
          c_fwd_q <= sat_inc(c_fwd_q);
          if (is_gap)
            c_gap_q <= sat_inc(c_gap_q);
        end else begin
          // duplicate
          if (sel_port == 2'd2)
            c_tcp_q <= sat_inc(c_tcp_q);
          else
            c_dup_q <= sat_inc(c_dup_q);
        end
      end

      // Skid fill / pop
      for (int i = 0; i < N_PORTS; i++) begin
        if (pop_sk[i]) begin
          if (in_tvalid[i] && in_tready[i]) begin
            // simultaneous pop + push
            sk_data_q[i]  <= in_tdata[i];
            sk_code_q[i]  <= in_code[i];
            sk_valid_q[i] <= 1'b1;
          end else begin
            sk_valid_q[i] <= 1'b0;
          end
        end else if (in_tvalid[i] && in_tready[i]) begin
          sk_data_q[i]  <= in_tdata[i];
          sk_code_q[i]  <= in_code[i];
          sk_valid_q[i] <= 1'b1;
        end
      end
    end
  end

endmodule
