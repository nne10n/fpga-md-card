// -----------------------------------------------------------------------------
// order_cache.sv — L0 order hash (N_ORDER) + Top-10 per hot_id / side
//
// cmd_ready always 1. Worse-than-10th ADD keeps order in cache but does not
// forge an 11th visible level. CXL/TRADE miss → no L0 delta.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module order_cache
  import md_pkg::*;
  import book_pkg::*;
#(
  parameter int N_ORD = N_ORDER,
  parameter int N_H   = N_HOT
) (
  input  logic            clk,
  input  logic            rst_n,

  input  logic            clear,

  input  logic            cmd_valid,
  input  book_op_e        cmd_op,
  input  logic [63:0]     cmd_order_id,
  input  logic [HOT_AW:0] cmd_hot_id,
  input  logic [1:0]      cmd_side,
  input  logic [63:0]     cmd_px,
  input  logic [31:0]     cmd_qty,
  input  logic [31:0]     cmd_seq,
  input  logic [63:0]     cmd_ts,
  output logic            cmd_ready,

  output book_delta_t     m_delta,
  output logic            m_delta_valid,
  input  logic            m_delta_ready,

  input  logic [HOT_AW:0] dbg_hot_id,
  input  logic [1:0]      dbg_side,
  output level_t          dbg_lvl0,
  output level_t          dbg_lvl1,
  output level_t          dbg_lvl2,
  output level_t          dbg_lvl3,
  output level_t          dbg_lvl4,
  output level_t          dbg_lvl5,
  output level_t          dbg_lvl6,
  output level_t          dbg_lvl7,
  output level_t          dbg_lvl8,
  output level_t          dbg_lvl9
);

  assign cmd_ready = 1'b1;

  order_slot_t slots [0:N_ORD-1];
  level_t top_bid [0:N_H-1][0:TOP_N-1];
  level_t top_ask [0:N_H-1][0:TOP_N-1];

  book_delta_t delta_q;
  logic        delta_v_q;
  assign m_delta       = delta_q;
  assign m_delta_valid = delta_v_q;

  integer hi, oi, k, w;

  // ---- dbg flatten (Verilator-friendly; no unpacked port array) ----
  level_t dbg_arr [0:TOP_N-1];
  always_comb begin
    for (int li = 0; li < TOP_N; li++) begin
      dbg_arr[li].valid = 1'b0;
      dbg_arr[li].px    = '0;
      dbg_arr[li].qty   = '0;
    end
    if (dbg_hot_id >= (HOT_AW+1)'(1) && dbg_hot_id <= (HOT_AW+1)'(N_H)) begin
      for (int li = 0; li < TOP_N; li++) begin
        if (dbg_side == SIDE_BID)
          dbg_arr[li] = top_bid[dbg_hot_id-1][li];
        else
          dbg_arr[li] = top_ask[dbg_hot_id-1][li];
      end
    end
  end
  assign dbg_lvl0 = dbg_arr[0];
  assign dbg_lvl1 = dbg_arr[1];
  assign dbg_lvl2 = dbg_arr[2];
  assign dbg_lvl3 = dbg_arr[3];
  assign dbg_lvl4 = dbg_arr[4];
  assign dbg_lvl5 = dbg_arr[5];
  assign dbg_lvl6 = dbg_arr[6];
  assign dbg_lvl7 = dbg_arr[7];
  assign dbg_lvl8 = dbg_arr[8];
  assign dbg_lvl9 = dbg_arr[9];

  function automatic logic [ORDER_AW-1:0] probe_addr(
      input logic [63:0] oid,
      input int          p
  );
    return hash_oid(oid) + ORDER_AW'(p);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    logic found, ok, placed, insert_ok, changed;
    logic [ORDER_AW-1:0] idx, a;
    logic [HOT_AW-1:0] hidx;
    logic [1:0]  use_side;
    logic [63:0] use_px;
    logic [31:0] use_qty, newq;
    logic [3:0]  found_i, ch_level, nfill, pos;
    logic        ch_valid;
    logic [63:0] ch_px;
    logic [31:0] ch_qty;
    level_t tmp [0:TOP_N-1];
    level_t sh  [0:TOP_N-1];
    level_t neu;
    int p;

    if (!rst_n) begin
      delta_v_q <= 1'b0;
      delta_q   <= '0;
      for (oi = 0; oi < N_ORD; oi++) begin
        slots[oi] <= '0;
      end
      for (hi = 0; hi < N_H; hi++)
        for (int li = 0; li < TOP_N; li++) begin
          top_bid[hi][li] <= '0;
          top_ask[hi][li] <= '0;
        end
    end else begin
      if (m_delta_ready && delta_v_q)
        delta_v_q <= 1'b0;

      if (clear) begin
        delta_v_q <= 1'b0;
        for (oi = 0; oi < N_ORD; oi++)
          slots[oi].valid <= 1'b0;
        for (hi = 0; hi < N_H; hi++)
          for (int li = 0; li < TOP_N; li++) begin
            top_bid[hi][li].valid <= 1'b0;
            top_ask[hi][li].valid <= 1'b0;
          end
      end else if (cmd_valid && cmd_hot_id >= (HOT_AW+1)'(1)
                              && cmd_hot_id <= (HOT_AW+1)'(N_H)
                              && (cmd_op == OP_ADD || cmd_op == OP_CXL
                                  || cmd_op == OP_TRADE)) begin
        hidx = HOT_AW'(cmd_hot_id - 1'b1);

        // ---- find order ----
        found = 1'b0;
        idx   = '0;
        for (p = 0; p < N_PROBE; p++) begin
          a = probe_addr(cmd_order_id, p);
          if (slots[a].valid && slots[a].order_id == cmd_order_id) begin
            found = 1'b1;
            idx   = a;
          end
        end

        use_side = cmd_side;
        use_px   = cmd_px;
        use_qty  = cmd_qty;
        ok       = 1'b0;
        changed  = 1'b0;
        ch_level = '0;
        ch_valid = 1'b0;
        ch_px    = '0;
        ch_qty   = '0;

        if (cmd_op == OP_ADD) begin
          if (found) begin
            slots[idx].qty <= slots[idx].qty + cmd_qty;
            use_px   = slots[idx].px;
            use_side = slots[idx].side;
            use_qty  = cmd_qty;
            ok       = 1'b1;
          end else begin
            for (p = 0; p < N_PROBE; p++) begin
              a = probe_addr(cmd_order_id, p);
              if (!slots[a].valid && !ok) begin
                ok  = 1'b1;
                idx = a;
              end
            end
            if (ok) begin
              slots[idx].valid    <= 1'b1;
              slots[idx].order_id <= cmd_order_id;
              slots[idx].hot_id   <= cmd_hot_id;
              slots[idx].side     <= cmd_side;
              slots[idx].px       <= cmd_px;
              slots[idx].qty      <= cmd_qty;
              use_px   = cmd_px;
              use_side = cmd_side;
              use_qty  = cmd_qty;
            end
          end
        end else begin
          // CXL / TRADE
          if (found) begin
            use_px   = slots[idx].px;
            use_side = slots[idx].side;
            if (cmd_qty == 32'd0 || cmd_qty >= slots[idx].qty)
              use_qty = slots[idx].qty;
            else
              use_qty = cmd_qty;
            if (use_qty >= slots[idx].qty) begin
              slots[idx].valid <= 1'b0;
              slots[idx].qty   <= '0;
            end else
              slots[idx].qty <= slots[idx].qty - use_qty;
            ok = 1'b1;
          end
        end

        // ---- top10 update ----
        if (ok) begin
          for (k = 0; k < TOP_N; k++) begin
            if (use_side == SIDE_BID)
              tmp[k] = top_bid[hidx][k];
            else
              tmp[k] = top_ask[hidx][k];
          end

          found_i = '0;
          found   = 1'b0; // reuse: same-px in top10
          for (k = 0; k < TOP_N; k++) begin
            if (tmp[k].valid && tmp[k].px == use_px) begin
              found   = 1'b1;
              found_i = 4'(k);
            end
          end

          if (cmd_op == OP_ADD) begin
            if (found) begin
              newq = tmp[found_i].qty + use_qty;
              tmp[found_i].qty = newq;
              changed  = 1'b1;
              ch_level = found_i;
              ch_valid = 1'b1;
              ch_px    = use_px;
              ch_qty   = newq;
            end else begin
              nfill = '0;
              for (k = 0; k < TOP_N; k++)
                if (tmp[k].valid)
                  nfill = nfill + 4'd1;
              insert_ok = (nfill < 4'(TOP_N)) ||
                          (tmp[TOP_N-1].valid && px_better(use_side, use_px, tmp[TOP_N-1].px));
              if (!tmp[TOP_N-1].valid)
                insert_ok = 1'b1;
              if (insert_ok) begin
                neu.valid = 1'b1;
                neu.px    = use_px;
                neu.qty   = use_qty;
                for (k = 0; k < TOP_N; k++)
                  sh[k] = '0;
                w = 0;
                placed = 1'b0;
                for (k = 0; k < TOP_N; k++) begin
                  if (!placed && (!tmp[k].valid || px_better(use_side, use_px, tmp[k].px))) begin
                    if (w < TOP_N) begin
                      sh[w] = neu;
                      w++;
                    end
                    placed = 1'b1;
                  end
                  if (tmp[k].valid && w < TOP_N) begin
                    sh[w] = tmp[k];
                    w++;
                  end
                end
                if (!placed && w < TOP_N) begin
                  sh[w] = neu;
                  w++;
                end
                for (k = 0; k < TOP_N; k++)
                  tmp[k] = sh[k];
                for (k = 0; k < TOP_N; k++) begin
                  if (tmp[k].valid && tmp[k].px == use_px) begin
                    ch_level = 4'(k);
                    ch_valid = 1'b1;
                    ch_px    = use_px;
                    ch_qty   = tmp[k].qty;
                  end
                end
                changed = 1'b1;
              end
            end
          end else begin
            // subtract
            if (found) begin
              if (tmp[found_i].qty > use_qty)
                newq = tmp[found_i].qty - use_qty;
              else
                newq = 32'd0;
              if (newq == 32'd0) begin
                for (k = 0; k < TOP_N; k++)
                  sh[k] = '0;
                w = 0;
                for (k = 0; k < TOP_N; k++) begin
                  if (k != int'(found_i) && tmp[k].valid) begin
                    sh[w] = tmp[k];
                    w++;
                  end
                end
                for (k = 0; k < TOP_N; k++)
                  tmp[k] = sh[k];
                changed  = 1'b1;
                ch_level = found_i;
                ch_valid = 1'b0;
                ch_px    = use_px;
                ch_qty   = 32'd0;
              end else begin
                tmp[found_i].qty = newq;
                changed  = 1'b1;
                ch_level = found_i;
                ch_valid = 1'b1;
                ch_px    = use_px;
                ch_qty   = newq;
              end
            end
          end

          // write back top10
          for (k = 0; k < TOP_N; k++) begin
            if (use_side == SIDE_BID)
              top_bid[hidx][k] <= tmp[k];
            else
              top_ask[hidx][k] <= tmp[k];
          end

          if (changed) begin
            delta_q.valid       <= 1'b1;
            delta_q.hot_id      <= cmd_hot_id;
            delta_q.side        <= use_side;
            delta_q.level       <= ch_level;
            delta_q.level_valid <= ch_valid;
            delta_q.px          <= ch_px;
            delta_q.qty         <= ch_qty;
            delta_q.seq         <= cmd_seq;
            delta_q.ts_ns       <= cmd_ts;
            delta_q.op          <= cmd_op;
            delta_v_q           <= 1'b1;
          end
        end
      end
    end
  end

endmodule
