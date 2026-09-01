// -----------------------------------------------------------------------------
// event_merge.sv — 3-way RR merge of event AXIS (+ code sideband) (M8)
//
// Per-input 2-deep FIFO. Fairness: at most MAX_BURST=4 consecutive grants to
// the same source when another input is pending. Downstream ready usually 1.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module event_merge
  import md_pkg::*;
#(
  parameter int MAX_BURST = 4
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic [511:0] s0_tdata,
  input  logic         s0_tvalid,
  input  logic         s0_tlast,
  output logic         s0_tready,
  input  logic [47:0]  s0_code,

  input  logic [511:0] s1_tdata,
  input  logic         s1_tvalid,
  input  logic         s1_tlast,
  output logic         s1_tready,
  input  logic [47:0]  s1_code,

  input  logic [511:0] s2_tdata,
  input  logic         s2_tvalid,
  input  logic         s2_tlast,
  output logic         s2_tready,
  input  logic [47:0]  s2_code,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  logic         m_event_tready,
  output logic [47:0]  m_code
);

  localparam int N = 3;

  logic unused_tlast;
  assign unused_tlast = s0_tlast ^ s1_tlast ^ s2_tlast;

  logic [511:0] fifo_d [0:N-1][0:1];
  logic [47:0]  fifo_c [0:N-1][0:1];
  logic [1:0]   fifo_n [0:N-1];

  logic [511:0] in_d [0:N-1];
  logic [47:0]  in_c [0:N-1];
  logic         in_v [0:N-1];
  logic         in_r [0:N-1];

  assign in_d[0] = s0_tdata;
  assign in_c[0] = s0_code;
  assign in_v[0] = s0_tvalid;
  assign s0_tready = in_r[0];

  assign in_d[1] = s1_tdata;
  assign in_c[1] = s1_code;
  assign in_v[1] = s1_tvalid;
  assign s1_tready = in_r[1];

  assign in_d[2] = s2_tdata;
  assign in_c[2] = s2_code;
  assign in_v[2] = s2_tvalid;
  assign s2_tready = in_r[2];

  logic [511:0] out_d_q;
  logic [47:0]  out_c_q;
  logic         out_v_q;

  assign m_event_tdata  = out_d_q;
  assign m_event_tvalid = out_v_q;
  assign m_event_tlast  = 1'b1;
  assign m_code         = out_c_q;

  wire out_slot = !out_v_q || m_event_tready;

  logic [1:0] rr_q;
  logic [2:0] burst_q;
  logic [1:0] last_src_q;

  logic         any_pend;
  logic         sel_v;
  logic [1:0]   sel_i;
  logic [511:0] sel_d;
  logic [47:0]  sel_c;
  logic         pop_i [0:N-1];
  logic         cont_ok;
  logic [1:0]   idx_k;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      in_r[i]  = (fifo_n[i] < 2'd2);
      pop_i[i] = 1'b0;
    end

    any_pend = (fifo_n[0] != 2'd0) || (fifo_n[1] != 2'd0) || (fifo_n[2] != 2'd0);

    sel_v = 1'b0;
    sel_i = 2'd0;
    sel_d = '0;
    sel_c = '0;
    idx_k = 2'd0;
    cont_ok = (fifo_n[last_src_q] != 2'd0) &&
              (burst_q < 3'(MAX_BURST)) &&
              (burst_q != 3'd0);

    if (any_pend && out_slot) begin
      if (cont_ok) begin
        sel_v = 1'b1;
        sel_i = last_src_q;
        sel_d = fifo_d[last_src_q][0];
        sel_c = fifo_c[last_src_q][0];
      end else begin
        for (int k = 0; k < N; k++) begin
          idx_k = 2'((int'(rr_q) + k) % N);
          if (!sel_v && (fifo_n[idx_k] != 2'd0)) begin
            sel_v = 1'b1;
            sel_i = idx_k;
            sel_d = fifo_d[idx_k][0];
            sel_c = fifo_c[idx_k][0];
          end
        end
      end
    end

    for (int i = 0; i < N; i++)
      pop_i[i] = sel_v && (sel_i == 2'(unsigned'(i)));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N; i++) begin
        fifo_n[i]    <= '0;
        fifo_d[i][0] <= '0;
        fifo_d[i][1] <= '0;
        fifo_c[i][0] <= '0;
        fifo_c[i][1] <= '0;
      end
      out_v_q     <= 1'b0;
      out_d_q     <= '0;
      out_c_q     <= '0;
      rr_q        <= 2'd0;
      burst_q     <= 3'd0;
      last_src_q  <= 2'd0;
    end else begin
      if (out_v_q && m_event_tready)
        out_v_q <= 1'b0;

      if (sel_v) begin
        out_d_q <= sel_d;
        out_c_q <= sel_c;
        out_v_q <= 1'b1;
        if (sel_i == last_src_q)
          burst_q <= burst_q + 3'd1;
        else
          burst_q <= 3'd1;
        last_src_q <= sel_i;
        rr_q <= 2'((int'(sel_i) + 1) % N);
      end

      for (int i = 0; i < N; i++) begin
        logic push;
        logic [1:0] ncur;
        push = in_v[i] && in_r[i];
        ncur = fifo_n[i];

        if (pop_i[i] && push) begin
          if (ncur == 2'd1) begin
            fifo_d[i][0] <= in_d[i];
            fifo_c[i][0] <= in_c[i];
            fifo_n[i]    <= 2'd1;
          end else begin
            fifo_d[i][0] <= fifo_d[i][1];
            fifo_c[i][0] <= fifo_c[i][1];
            fifo_d[i][1] <= in_d[i];
            fifo_c[i][1] <= in_c[i];
            fifo_n[i]    <= 2'd2;
          end
        end else if (pop_i[i]) begin
          if (ncur == 2'd1) begin
            fifo_n[i] <= 2'd0;
          end else begin
            fifo_d[i][0] <= fifo_d[i][1];
            fifo_c[i][0] <= fifo_c[i][1];
            fifo_n[i]    <= 2'd1;
          end
        end else if (push) begin
          if (ncur == 2'd0) begin
            fifo_d[i][0] <= in_d[i];
            fifo_c[i][0] <= in_c[i];
            fifo_n[i]    <= 2'd1;
          end else begin
            fifo_d[i][1] <= in_d[i];
            fifo_c[i][1] <= in_c[i];
            fifo_n[i]    <= 2'd2;
          end
        end
      end
    end
  end

endmodule
