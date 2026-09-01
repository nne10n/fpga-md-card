// -----------------------------------------------------------------------------
// dma_pack.sv — Soft-host DMA packer (M6)
//
// Input : event AXIS-512 (single-beat event_t). s_event_tready tied 1 —
//         never backpressure the event bus; FIFO-full drops are counted.
// FIFO  : depth 32 events. On full + new event → drop_full++, discard.
// Output: AXIS-64, 8 beats per event, LE beat order matching mcast payload:
//           beat0 = event[63:0]  (= ts_ns)
//           beat1 = event[127:64]
//           ...
//           beat7 = event[511:448]
//         tkeep = 8'hFF every beat; tlast on beat7.
//         m_axis_tready may pause; drain FIFO when ready.
// Counters (32b saturating): tx_ok (event fully handed to host), drop_full.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module dma_pack
  import md_pkg::*;
(
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

  output logic [31:0]  tx_ok,
  output logic [31:0]  drop_full
);

  localparam int unsigned DEPTH   = 32;
  localparam int unsigned PTR_W   = 5; // log2(32)
  localparam int unsigned N_BEATS = 8;


  assign s_event_tready = 1'b1;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  // -------------------------------------------------------------------------
  // Event FIFO (simple sync circular buffer). Head peeked while streaming;
  // pop on last-beat handshake so capacity is exactly DEPTH while paused.
  // -------------------------------------------------------------------------
  (* RAM_STYLE = "block" *) logic [511:0] mem_q [0:DEPTH-1];
  logic [PTR_W-1:0] wr_q, rd_q;
  logic [PTR_W:0]   count_q; // 0..32
  logic [2:0]       beat_q;

  wire full  = (count_q == (PTR_W+1)'(DEPTH));
  wire empty = (count_q == '0);

  wire wr_fire   = s_event_tvalid && !full;
  wire drop_fire = s_event_tvalid && full;

  wire [511:0] head = mem_q[rd_q];

  assign m_axis_tvalid = !empty;
  assign m_axis_tdata  = head[64 * beat_q +: 64];
  assign m_axis_tkeep  = 8'hFF;
  assign m_axis_tlast  = (beat_q == 3'(N_BEATS - 1));

  logic [31:0] c_tx_q, c_drop_q;
  assign tx_ok     = c_tx_q;
  assign drop_full = c_drop_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_q     <= '0;
      rd_q     <= '0;
      count_q  <= '0;
      beat_q   <= 3'd0;
      c_tx_q   <= 32'd0;
      c_drop_q <= 32'd0;
    end else begin
      logic [PTR_W:0] c_next;
      c_next = count_q;

      if (drop_fire)
        c_drop_q <= sat_inc(c_drop_q);

      if (wr_fire) begin
        mem_q[wr_q] <= s_event_tdata;
        wr_q        <= wr_q + PTR_W'(1);
        c_next      = c_next + (PTR_W+1)'(1);
      end

      if (!empty && m_axis_tready) begin
        if (beat_q == 3'(N_BEATS - 1)) begin
          rd_q   <= rd_q + PTR_W'(1);
          c_next = c_next - (PTR_W+1)'(1);
          beat_q <= 3'd0;
          c_tx_q <= sat_inc(c_tx_q);
        end else begin
          beat_q <= beat_q + 3'd1;
        end
      end else if (empty) begin
        beat_q <= 3'd0;
      end

      count_q <= c_next;
    end
  end

endmodule
