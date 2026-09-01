// -----------------------------------------------------------------------------
// dec_sse_fast.sv — Synthetic FAST template decoder (M9)
//
// v1.0 hard-coded wire layout (NOT exchange FAST template PDF):
//   [0]     PMap / msg_type  (1 byte)
//   [1..6]  security code ASCII (6 bytes)
//   [7..10] seq u32 big-endian
//   [11..18] px u64 big-endian  (design §3.5 said u32; use u64 to match
//            event_t.px / Binary TB — see README)
//   [19..22] qty u32 big-endian
// MIN_LEN = 23. Network/big-endian; AXIS first byte = tdata[7:0].
//
// exch=EXCH_SSE, ch=CH_SNAP (fixed), msg_type=PMap byte,
// ts_ns=tuser.sop_ts, symbol_id=0, flags=0, side=0, order_id=0.
// Store-and-forward; emit on tlast+1. m_code sideband same as dec_bin_generic.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module dec_sse_fast
  import md_pkg::*;
#(
  parameter int BUF_BYTES = 64
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [63:0]  s_axis_tdata,
  input  logic [7:0]   s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,
  input  pay_tuser_t   s_axis_tuser,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  logic         m_event_tready,
  output logic [47:0]  m_code,

  output logic [31:0]  msg_ok,
  output logic [31:0]  msg_bad
);

  assign s_axis_tready = 1'b1;

  localparam int unsigned BUF_MAX  = BUF_BYTES;
  localparam int unsigned MIN_LEN  = 23;
  localparam int unsigned OFF_PMAP = 0;
  localparam int unsigned OFF_CODE = 1;
  localparam int unsigned OFF_SEQ  = 7;
  localparam int unsigned OFF_PX   = 11;
  localparam int unsigned OFF_QTY  = 19;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_BUF  = 2'd1,
    ST_DROP = 2'd2
  } state_e;

  state_e          state_q;
  logic [7:0]      mem_q [0:BUF_MAX-1];
  logic [8:0]      len_q;
  logic            ovf_q;
  pay_tuser_t      tuser_q;

  logic [31:0]     ok_q;
  logic [31:0]     bad_q;

  event_t          ev_q;
  logic [47:0]     code_q;
  logic            emit_q;

  assign msg_ok         = ok_q;
  assign msg_bad        = bad_q;
  assign m_event_tdata  = ev_q;
  assign m_event_tvalid = emit_q;
  assign m_event_tlast  = 1'b1;
  assign m_code         = code_q;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic [31:0] be_u32(
      input logic [7:0] m [0:BUF_MAX-1],
      input int unsigned off
  );
    return {m[off], m[off+1], m[off+2], m[off+3]};
  endfunction

  function automatic logic [63:0] be_u64(
      input logic [7:0] m [0:BUF_MAX-1],
      input int unsigned off
  );
    return {m[off], m[off+1], m[off+2], m[off+3],
            m[off+4], m[off+5], m[off+6], m[off+7]};
  endfunction

  function automatic logic [47:0] extract_code(
      input logic [7:0] m [0:BUF_MAX-1]
  );
    // char0 → [7:0] (matches sym_cam / Binary decoders)
    return {m[OFF_CODE+5], m[OFF_CODE+4], m[OFF_CODE+3],
            m[OFF_CODE+2], m[OFF_CODE+1], m[OFF_CODE]};
  endfunction

  function automatic event_t build_event(
      input logic [7:0] m [0:BUF_MAX-1],
      input pay_tuser_t tu
  );
    event_t ev;
    ev           = '0;
    ev.pad       = '0;
    ev.raw_ptr   = '0;
    ev.queue_pos = '0;
    ev.level     = '0;
    ev.order_id  = 64'h0;
    ev.side      = 2'b00;
    ev.qty       = be_u32(m, OFF_QTY);
    ev.px        = be_u64(m, OFF_PX);
    ev.flags     = 8'h0;
    ev.msg_type  = m[OFF_PMAP];
    ev.ch        = CH_SNAP[3:0];
    ev.exch      = EXCH_SSE[1:0];
    ev.symbol_id = 16'h0;
    ev.seq       = be_u32(m, OFF_SEQ);
    ev.ts_ns     = tu.sop_ts;
    return ev;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    integer            bi;
    logic [7:0]        mem_tmp [0:BUF_MAX-1];
    logic [8:0]        n;
    logic              ov;
    pay_tuser_t        tu_use;
    logic              do_emit;
    logic              do_bad;

    if (!rst_n) begin
      state_q <= ST_IDLE;
      len_q   <= '0;
      ovf_q   <= 1'b0;
      tuser_q <= '0;
      ok_q    <= '0;
      bad_q   <= '0;
      ev_q    <= '0;
      code_q  <= '0;
      emit_q  <= 1'b0;
      for (bi = 0; bi < BUF_MAX; bi++)
        mem_q[bi] <= 8'h0;
    end else begin
      do_emit = 1'b0;
      do_bad  = 1'b0;

      if (emit_q) begin
        if (m_event_tready)
          ok_q <= sat_inc(ok_q);
        else
          bad_q <= sat_inc(bad_q);
      end
      emit_q <= 1'b0;

      if (s_axis_tvalid) begin
        for (bi = 0; bi < BUF_MAX; bi++)
          mem_tmp[bi] = mem_q[bi];

        unique case (state_q)
          ST_IDLE: begin
            tu_use = s_axis_tuser;
            tuser_q <= s_axis_tuser;
            n  = 9'd0;
            ov = 1'b0;
            for (bi = 0; bi < 8; bi++) begin
              if (s_axis_tkeep[bi]) begin
                if (n < BUF_MAX[8:0]) begin
                  mem_tmp[n] = s_axis_tdata[8*bi +: 8];
                  mem_q[n[7:0]] <= s_axis_tdata[8*bi +: 8];
                  n = n + 9'd1;
                end else begin
                  ov = 1'b1;
                end
              end
            end
            len_q <= n;
            ovf_q <= ov;

            if (s_axis_tlast) begin
              if (!ov && (n >= MIN_LEN[8:0])) begin
                ev_q   <= build_event(mem_tmp, tu_use);
                code_q <= extract_code(mem_tmp);
                do_emit = 1'b1;
              end else begin
                do_bad = 1'b1;
              end
              state_q <= ST_IDLE;
            end else begin
              state_q <= ov ? ST_DROP : ST_BUF;
            end
          end

          ST_BUF: begin
            tu_use = tuser_q;
            n  = len_q;
            ov = ovf_q;
            for (bi = 0; bi < 8; bi++) begin
              if (s_axis_tkeep[bi]) begin
                if (n < BUF_MAX[8:0]) begin
                  mem_tmp[n] = s_axis_tdata[8*bi +: 8];
                  mem_q[n[7:0]] <= s_axis_tdata[8*bi +: 8];
                  n = n + 9'd1;
                end else begin
                  ov = 1'b1;
                end
              end
            end
            len_q <= n;
            ovf_q <= ov;

            if (s_axis_tlast) begin
              if (!ov && (n >= MIN_LEN[8:0])) begin
                ev_q   <= build_event(mem_tmp, tu_use);
                code_q <= extract_code(mem_tmp);
                do_emit = 1'b1;
              end else begin
                do_bad = 1'b1;
              end
              state_q <= ST_IDLE;
            end else if (ov) begin
              state_q <= ST_DROP;
            end
          end

          ST_DROP: begin
            if (s_axis_tlast) begin
              do_bad  = 1'b1;
              state_q <= ST_IDLE;
              len_q   <= '0;
              ovf_q   <= 1'b0;
            end
          end

          default: state_q <= ST_IDLE;
        endcase

        if (do_bad)
          bad_q <= sat_inc(bad_q);
        if (do_emit)
          emit_q <= 1'b1;
      end
    end
  end

endmodule
