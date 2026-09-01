// -----------------------------------------------------------------------------
// sym_cam.sv — Symbol CAM lookup (M4)
//
// 8192 x {valid, epoch, key[55:0], symbol_id[15:0]} dual-bank open-address hash.
// key = {exch[1:0], code_ascii[47:0]} on s_code beside s_event.
//
// Hash : key[12:0] ^ key[25:13] ^ key[38:26], linear probe +0..+3.
// Memory: 2 banks x 4 address-striped BRAMs (2048 x 89b) so all 4 probes
//         read in one cycle. Epoch increments on reset-release so leftover
//         BRAM entries (not wiped) do not alias across resets.
// Banks: lookups use bank_sel; CSR writes go to ~bank_sel. swap pulse then
//        1-cycle switch; lookups keep the old bank through the switch cycle.
// Miss : cfg_pass_miss=0 drop; =1 forward symbol_id=0 | F_CAM_MISS.
// Ready: s_event_tready=1 (hot path). New beats while busy are shed.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module sym_cam
  import md_pkg::*;
(
  input  wire          clk,
  input  wire          rst_n,

  input  wire [511:0]  s_event_tdata,
  input  wire          s_event_tvalid,
  input  wire          s_event_tlast,
  output wire          s_event_tready,
  input  wire [47:0]   s_code,

  output logic [511:0] m_event_tdata,
  output logic         m_event_tvalid,
  output logic         m_event_tlast,
  input  wire          m_event_tready,

  input  wire          cfg_pass_miss,
  output logic         bank_sel,
  input  wire          swap,

  input  wire          cam_we,
  input  wire [12:0]   cam_addr,
  input  wire [55:0]   cam_key,
  input  wire [15:0]   cam_id,
  input  wire          cam_entry_valid,

  output logic [31:0]  hit,
  output logic [31:0]  miss,
  output logic [31:0]  drop_miss
);

  localparam int DEPTH  = CAM_DEPTH;
  localparam int AW     = CAM_AW;
  localparam int NPROBE = 4;
  localparam int STRIPE = 4;
  localparam int ROWS   = DEPTH / STRIPE; // 2048
  localparam int ROW_W  = AW - 2;         // 11
  localparam int W_RAM  = 89;             // {v, epoch[15:0], key[55:0], id[15:0]}

  logic unused_tlast;
  logic        bank_sel_q;
  logic        swap_pend_q;
  logic [15:0] epoch_q = 16'd1;
  logic        rst_n_d;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_CHK  = 2'd1,
    ST_EMIT = 2'd2
  } state_e;

  state_e        st_q;
  state_e        st_next;
  logic [511:0]  ev_q;
  logic [55:0]   key_q;
  logic [AW-1:0] base_q;
  logic          rd_bank_q;

  logic [15:0]   res_sym_q;
  logic          res_miss_q;

  logic [511:0]  out_data_q;
  logic          out_valid_q;

  logic          out_fire;
  logic          out_slot;
  assign out_fire = out_valid_q && m_event_tready;
  assign out_slot = !out_valid_q || m_event_tready;

  logic [31:0] c_hit_q, c_miss_q, c_drop_q;

  assign unused_tlast   = s_event_tlast;
  assign s_event_tready = 1'b1;
  assign bank_sel       = bank_sel_q;
  assign m_event_tdata  = out_data_q;
  assign m_event_tvalid = out_valid_q;
  assign m_event_tlast  = 1'b1;
  assign hit            = c_hit_q;
  assign miss           = c_miss_q;
  assign drop_miss      = c_drop_q;

  event_t      ev_live;
  logic [55:0] key_live;
  logic [AW-1:0] hash_live;
  logic [AW-1:0] base_rd;
  logic          rd_bank_use;

  assign ev_live     = event_t'(s_event_tdata);
  assign key_live    = {ev_live.exch, s_code};
  assign hash_live   = key_live[12:0] ^ key_live[25:13] ^ key_live[38:26];
  assign base_rd     = ((st_q == ST_IDLE) && s_event_tvalid) ? hash_live : base_q;
  assign rd_bank_use = ((st_q == ST_IDLE) && s_event_tvalid) ? bank_sel_q : rd_bank_q;

  logic [ROW_W-1:0] rd_row [0:STRIPE-1];
  logic [AW-1:0]    stripe_addr;
  logic [1:0]       stripe_delta;

  always_comb begin
    for (int s = 0; s < STRIPE; s++) begin
      stripe_delta = 2'(s) - base_rd[1:0];
      stripe_addr  = base_rd + {11'd0, stripe_delta};
      rd_row[s]    = stripe_addr[AW-1:2];
    end
  end

  logic [W_RAM-1:0] wr_pack;
  logic [1:0]       wr_str;
  logic [ROW_W-1:0] wr_row;
  logic             wr_bank;
  assign wr_str  = cam_addr[1:0];
  assign wr_row  = cam_addr[AW-1:2];
  assign wr_bank = ~bank_sel_q;
  assign wr_pack = {cam_entry_valid, epoch_q, cam_key, cam_id};

  logic [W_RAM-1:0] rd_pack [0:1][0:STRIPE-1];
  logic [W_RAM-1:0] rd_sel  [0:STRIPE-1];
  logic [W_RAM-1:0] rd_probe[0:NPROBE-1];

  genvar gb, gs;
  generate
    for (gb = 0; gb < 2; gb++) begin : g_bank
      for (gs = 0; gs < STRIPE; gs++) begin : g_str
        (* RAM_STYLE = "block" *) logic [W_RAM-1:0] ram [0:ROWS-1];
        logic [W_RAM-1:0] rd_q;
        always_ff @(posedge clk) begin
          if (cam_we && (wr_bank == 1'(gb)) && (wr_str == 2'(gs))) begin
            ram[wr_row] <= wr_pack;
          end
          rd_q <= ram[rd_row[gs]];
        end
        assign rd_pack[gb][gs] = rd_q;
      end
    end
  endgenerate

  always_comb begin
    for (int s = 0; s < STRIPE; s++) begin
      rd_sel[s] = rd_pack[rd_bank_use][s];
    end
    for (int p = 0; p < NPROBE; p++) begin
      rd_probe[p] = rd_sel[base_q[1:0] + 2'(p)];
    end
  end

  logic        pr_v  [0:NPROBE-1];
  logic [15:0] pr_ep [0:NPROBE-1];
  logic [55:0] pr_k  [0:NPROBE-1];
  logic [15:0] pr_id [0:NPROBE-1];
  logic        pr_hit[0:NPROBE-1];
  logic        any_hit;
  logic [15:0] hit_id;

  always_comb begin
    any_hit = 1'b0;
    hit_id  = 16'd0;
    for (int p = 0; p < NPROBE; p++) begin
      pr_v[p]  = rd_probe[p][88];
      pr_ep[p] = rd_probe[p][87:72];
      pr_k[p]  = rd_probe[p][71:16];
      pr_id[p] = rd_probe[p][15:0];
      pr_hit[p] = pr_v[p] && (pr_ep[p] == epoch_q) && (pr_k[p] == key_q);
      if (!any_hit && pr_hit[p]) begin
        any_hit = 1'b1;
        hit_id  = pr_id[p];
      end
    end
  end

  event_t emit_ev;
  always_comb begin
    emit_ev = event_t'(ev_q);
    if (st_q == ST_CHK && any_hit) begin
      emit_ev.symbol_id = hit_id;
      emit_ev.flags     = emit_ev.flags & ~F_CAM_MISS;
    end else begin
      emit_ev.symbol_id = (st_q == ST_EMIT) ? res_sym_q : 16'd0;
      if ((st_q == ST_CHK && !any_hit && cfg_pass_miss) ||
          (st_q == ST_EMIT && res_miss_q)) begin
        emit_ev.flags = emit_ev.flags | F_CAM_MISS;
      end else begin
        emit_ev.flags = emit_ev.flags & ~F_CAM_MISS;
      end
    end
  end

  always_comb begin
    st_next = st_q;
    case (st_q)
      ST_IDLE: begin
        if (s_event_tvalid) begin
          st_next = ST_CHK;
        end
      end
      ST_CHK: begin
        if (any_hit) begin
          st_next = out_slot ? ST_IDLE : ST_EMIT;
        end else if (cfg_pass_miss) begin
          st_next = out_slot ? ST_IDLE : ST_EMIT;
        end else begin
          st_next = ST_IDLE;
        end
      end
      ST_EMIT: begin
        if (out_slot) begin
          st_next = ST_IDLE;
        end
      end
      default: begin
        st_next = ST_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bank_sel_q  <= 1'b0;
      swap_pend_q <= 1'b0;
      rst_n_d     <= 1'b0;
      st_q        <= ST_IDLE;
      ev_q        <= '0;
      key_q       <= '0;
      base_q      <= '0;
      rd_bank_q   <= 1'b0;
      res_sym_q   <= '0;
      res_miss_q  <= 1'b0;
      out_data_q  <= '0;
      out_valid_q <= 1'b0;
      c_hit_q     <= '0;
      c_miss_q    <= '0;
      c_drop_q    <= '0;
    end else begin
      rst_n_d <= 1'b1;

      if (swap) begin
        swap_pend_q <= 1'b1;
      end else if (swap_pend_q) begin
        bank_sel_q  <= ~bank_sel_q;
        swap_pend_q <= 1'b0;
      end

      if (out_fire) begin
        out_valid_q <= 1'b0;
      end

      st_q <= st_next;

      if (st_q == ST_IDLE && s_event_tvalid) begin
        ev_q      <= s_event_tdata;
        key_q     <= key_live;
        base_q    <= hash_live;
        rd_bank_q <= bank_sel_q;
      end

      if (st_q == ST_CHK) begin
        if (any_hit) begin
          if (c_hit_q != 32'hFFFF_FFFF) begin
            c_hit_q <= c_hit_q + 32'd1;
          end
          res_sym_q  <= hit_id;
          res_miss_q <= 1'b0;
          if (out_slot) begin
            out_data_q  <= emit_ev;
            out_valid_q <= 1'b1;
          end
        end else begin
          if (c_miss_q != 32'hFFFF_FFFF) begin
            c_miss_q <= c_miss_q + 32'd1;
          end
          if (cfg_pass_miss) begin
            res_sym_q  <= 16'd0;
            res_miss_q <= 1'b1;
            if (out_slot) begin
              out_data_q  <= emit_ev;
              out_valid_q <= 1'b1;
            end
          end else if (c_drop_q != 32'hFFFF_FFFF) begin
            c_drop_q <= c_drop_q + 32'd1;
          end
        end
      end else if (st_q == ST_EMIT && out_slot) begin
        out_data_q  <= emit_ev;
        out_valid_q <= 1'b1;
      end
    end
  end

  // Epoch is not async-reset: increment once on reset *release* so BRAM
  // contents from a previous run cannot match (BRAM is not wiped).
  always_ff @(posedge clk) begin
    if (rst_n && !rst_n_d) begin
      if (epoch_q == 16'hFFFF) begin
        epoch_q <= 16'd1;
      end else begin
        epoch_q <= epoch_q + 16'd1;
      end
    end
  end

endmodule

`default_nettype wire
