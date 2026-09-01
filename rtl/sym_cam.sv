// -----------------------------------------------------------------------------
// sym_cam.sv — Symbol CAM lookup (M4)
//
// 8192 x {valid, key[55:0], symbol_id[15:0]} dual-bank open-address hash.
// key = {exch[1:0], code_ascii[47:0]} — code arrives as s_code sideband on
// the same beat as s_event (decoder will supply later; M4 TB drives it).
//
// Hash : key[12:0] ^ key[25:13] ^ key[38:26], linear probe +0..+3.
// Banks: lookups use bank_sel; CSR writes go to ~bank_sel. swap pulse then
//        1-cycle switch; lookups keep the old bank through the switch cycle.
// Miss : cfg_pass_miss=0 drop; =1 forward symbol_id=0 | F_CAM_MISS.
// Ready: s_event_tready=1 (hot path). New beats while busy are shed.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module sym_cam
  import md_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,

  input  logic [511:0] s_event_tdata,
  input  logic         s_event_tvalid,
  input  logic         s_event_tlast,
  output logic         s_event_tready,
  input  logic [47:0]  s_code,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  logic         m_event_tready,

  input  logic         cfg_pass_miss,
  output logic         bank_sel,
  input  logic         swap,

  input  logic         cam_we,
  input  logic [12:0]  cam_addr,
  input  logic [55:0]  cam_key,
  input  logic [15:0]  cam_id,
  input  logic         cam_entry_valid,

  output logic [31:0]  hit,
  output logic [31:0]  miss,
  output logic [31:0]  drop_miss
);

  localparam int DEPTH  = CAM_DEPTH;
  localparam int AW     = CAM_AW;
  localparam int NPROBE = 4;

  logic unused_tlast;
  assign unused_tlast = s_event_tlast;

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
  endfunction

  function automatic logic [AW-1:0] hash13(input logic [55:0] k);
    return k[12:0] ^ k[25:13] ^ k[38:26];
  endfunction

  function automatic logic [511:0] ev_with_sym(
      input logic [511:0] raw,
      input logic [15:0]  sym,
      input logic         set_miss
  );
    event_t e;
    e = event_t'(raw);
    e.symbol_id = sym;
    if (set_miss)
      e.flags = e.flags | F_CAM_MISS;
    else
      e.flags = e.flags & ~F_CAM_MISS;
    return e;
  endfunction

  logic        mem_v  [0:1][0:DEPTH-1];
  logic [55:0] mem_k  [0:1][0:DEPTH-1];
  logic [15:0] mem_id [0:1][0:DEPTH-1];

  logic bank_sel_q;
  logic swap_pend_q;
  assign bank_sel = bank_sel_q;

  assign s_event_tready = 1'b1;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_RD   = 2'd1,
    ST_CHK  = 2'd2,
    ST_EMIT = 2'd3
  } state_e;

  state_e        st_q;
  logic [511:0]  ev_q;
  logic [55:0]   key_q;
  logic [AW-1:0] base_q;
  logic [1:0]    probe_q;
  logic [AW-1:0] rd_addr_q;
  logic          rd_bank_q;

  logic [15:0]   res_sym_q;
  logic          res_miss_q;

  logic [511:0]  out_data_q;
  logic          out_valid_q;

  assign m_event_tdata  = out_data_q;
  assign m_event_tvalid = out_valid_q;
  assign m_event_tlast  = 1'b1;

  wire out_fire = out_valid_q && m_event_tready;
  wire out_slot = !out_valid_q || m_event_tready;

  logic [31:0] c_hit_q, c_miss_q, c_drop_q;
  assign hit       = c_hit_q;
  assign miss      = c_miss_q;
  assign drop_miss = c_drop_q;

  logic        rd_v;
  logic [55:0] rd_k;
  logic [15:0] rd_id;
  assign rd_v  = mem_v [rd_bank_q][rd_addr_q];
  assign rd_k  = mem_k [rd_bank_q][rd_addr_q];
  assign rd_id = mem_id[rd_bank_q][rd_addr_q];

  wire hit_now = rd_v && (rd_k == key_q);

  integer bi, ai;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bank_sel_q  <= 1'b0;
      swap_pend_q <= 1'b0;
      st_q        <= ST_IDLE;
      ev_q        <= '0;
      key_q       <= '0;
      base_q      <= '0;
      probe_q     <= '0;
      rd_addr_q   <= '0;
      rd_bank_q   <= 1'b0;
      res_sym_q   <= '0;
      res_miss_q  <= 1'b0;
      out_data_q  <= '0;
      out_valid_q <= 1'b0;
      c_hit_q     <= '0;
      c_miss_q    <= '0;
      c_drop_q    <= '0;
      for (bi = 0; bi < 2; bi++)
        for (ai = 0; ai < DEPTH; ai++) begin
          mem_v [bi][ai] <= 1'b0;
          mem_k [bi][ai] <= '0;
          mem_id[bi][ai] <= '0;
        end
    end else begin
      // swap pulse → 1-cycle later flip; lookups use old bank_sel meanwhile
      if (swap)
        swap_pend_q <= 1'b1;
      else if (swap_pend_q) begin
        bank_sel_q  <= ~bank_sel_q;
        swap_pend_q <= 1'b0;
      end

      if (cam_we) begin
        mem_v [~bank_sel_q][cam_addr] <= cam_entry_valid;
        mem_k [~bank_sel_q][cam_addr] <= cam_key;
        mem_id[~bank_sel_q][cam_addr] <= cam_id;
      end

      if (out_fire)
        out_valid_q <= 1'b0;

      unique case (st_q)
        ST_IDLE: begin
          if (s_event_tvalid) begin
            event_t ein;
            logic [55:0] k;
            ein       = event_t'(s_event_tdata);
            k         = {ein.exch, s_code};
            ev_q      <= s_event_tdata;
            key_q     <= k;
            base_q    <= hash13(k);
            probe_q   <= 2'd0;
            rd_bank_q <= bank_sel_q;
            rd_addr_q <= hash13(k);
            st_q      <= ST_RD;
          end
        end

        ST_RD: begin
          st_q <= ST_CHK;
        end

        ST_CHK: begin
          if (hit_now) begin
            c_hit_q    <= sat_inc(c_hit_q);
            res_sym_q  <= rd_id;
            res_miss_q <= 1'b0;
            if (out_slot) begin
              out_data_q  <= ev_with_sym(ev_q, rd_id, 1'b0);
              out_valid_q <= 1'b1;
              st_q        <= ST_IDLE;
            end else begin
              st_q <= ST_EMIT;
            end
          end else if (probe_q != 2'(NPROBE - 1)) begin
            probe_q   <= probe_q + 2'd1;
            rd_addr_q <= AW'(base_q + AW'(probe_q) + AW'(1));
            st_q      <= ST_RD;
          end else begin
            c_miss_q <= sat_inc(c_miss_q);
            if (cfg_pass_miss) begin
              res_sym_q  <= 16'd0;
              res_miss_q <= 1'b1;
              if (out_slot) begin
                out_data_q  <= ev_with_sym(ev_q, 16'd0, 1'b1);
                out_valid_q <= 1'b1;
                st_q        <= ST_IDLE;
              end else begin
                st_q <= ST_EMIT;
              end
            end else begin
              c_drop_q <= sat_inc(c_drop_q);
              st_q     <= ST_IDLE;
            end
          end
        end

        ST_EMIT: begin
          if (out_slot) begin
            out_data_q  <= ev_with_sym(ev_q, res_sym_q, res_miss_q);
            out_valid_q <= 1'b1;
            st_q        <= ST_IDLE;
          end
        end

        default: st_q <= ST_IDLE;
      endcase
    end
  end

endmodule
