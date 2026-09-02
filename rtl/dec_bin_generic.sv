// -----------------------------------------------------------------------------
// dec_bin_generic.sv — Parameterizable Binary market-data decoder (M2)
//
// Store-and-forward: buffer payload until tlast, register event_t, assert
// m_event_tvalid on the following cycle (tlast + 1). Wire field offsets are
// CSR ports (network / big-endian). AXIS byte 0 is tdata[7:0].
//
// event_t has no security-code field. ASCII code at cfg_off_code is emitted on
// m_code[47:0] (char0 in [7:0]) registered with m_event_tvalid for sym_cam.
// symbol_id stays 0 until sym_cam. ch := cfg_type_lut[msg_type[3:0]].
// body_len on the wire is ignored; extraction uses fixed offsets + cfg_len_hdr.
// DATA_W = 32|64 (default 64). KEEP_W = DATA_W/8.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module dec_bin_generic
  import md_pkg::*;
#(
  parameter exch_e CFG_EXCH  = EXCH_SZSE,
  parameter int    BUF_BYTES = 256,
  parameter int    DATA_W    = 64,
  parameter int    KEEP_W    = DATA_W / 8
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [7:0]   cfg_off_type,
  input  logic [7:0]   cfg_off_seq,
  input  logic [7:0]   cfg_off_code,     // 6-byte ASCII → m_code sideband
  input  logic [7:0]   cfg_off_px,
  input  logic [7:0]   cfg_off_qty,
  input  logic [7:0]   cfg_off_side,
  input  logic [7:0]   cfg_off_oid,
  input  logic [7:0]   cfg_len_hdr,
  input  logic [63:0]  cfg_type_lut,     // 16 x 4-bit ch_e; index = msg_type[3:0]
  input  logic [7:0]   cfg_off_ch_hint,  // optional; ignored for ch in v1

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
  output logic [47:0]  m_code,           // ASCII security code beside event

  output logic [31:0]  msg_ok,
  output logic [31:0]  msg_bad
);

  assign s_axis_tready = 1'b1;

  localparam int unsigned BUF_MAX = BUF_BYTES;

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

  // ch_hint unused for ch assignment in v1
  logic unused_csr;
  assign unused_csr = ^cfg_off_ch_hint;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic [15:0] be_u16(
      input logic [7:0] m [0:BUF_MAX-1],
      input int unsigned off
  );
    return {m[off], m[off+1]};
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
    int unsigned off;
    off = int'(cfg_off_code);
    // char0 → [7:0] (matches sym_cam TB code_from_ascii6)
    return {m[off+5], m[off+4], m[off+3], m[off+2], m[off+1], m[off]};
  endfunction

  function automatic event_t build_event(
      input logic [7:0] m [0:BUF_MAX-1],
      input pay_tuser_t tu
  );
    logic [15:0] mt16;
    logic [7:0]  mt8;
    logic [3:0]  idx;
    logic [3:0]  ch_v;
    event_t      ev;
    mt16 = be_u16(m, int'(cfg_off_type));
    mt8  = mt16[7:0];
    idx  = mt8[3:0];
    ch_v = cfg_type_lut[{idx, 2'b00} +: 4];

    ev           = '0;
    ev.pad       = '0;
    ev.raw_ptr   = '0;
    ev.queue_pos = '0;
    ev.level     = '0;
    ev.order_id  = be_u64(m, int'(cfg_off_oid));
    ev.side      = m[int'(cfg_off_side)][1:0];
    ev.qty       = be_u32(m, int'(cfg_off_qty));
    ev.px        = be_u64(m, int'(cfg_off_px));
    ev.flags     = 8'h0;
    ev.msg_type  = mt8;
    ev.ch        = ch_v;
    ev.exch      = CFG_EXCH[1:0];
    ev.symbol_id = 16'h0;
    ev.seq       = be_u32(m, int'(cfg_off_seq));
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

      // Complete prior emit attempt (hot path: no multi-cycle stall)
      if (emit_q) begin
        if (m_event_tready)
          ok_q <= sat_inc(ok_q);
        else
          bad_q <= sat_inc(bad_q);
      end
      emit_q <= 1'b0;

      if (s_axis_tvalid) begin
        // Shadow copy for same-cycle extract after this beat's bytes
        for (bi = 0; bi < BUF_MAX; bi++)
          mem_tmp[bi] = mem_q[bi];

        unique case (state_q)
          ST_IDLE: begin
            tu_use = s_axis_tuser;
            tuser_q <= s_axis_tuser;
            n  = 9'd0;
            ov = 1'b0;
            for (bi = 0; bi < KEEP_W; bi++) begin
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
              if (!ov && (n >= {1'b0, cfg_len_hdr})) begin
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
            for (bi = 0; bi < KEEP_W; bi++) begin
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
              if (!ov && (n >= {1'b0, cfg_len_hdr})) begin
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
