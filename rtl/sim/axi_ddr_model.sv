// -----------------------------------------------------------------------------
// axi_ddr_model.sv — sparse AXI4-MM slave for L1 DDR simulation (not for synth)
// Associative mem[addr]=data; configurable RTT; byte-aligned ADDR, DATA_W beat.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module axi_ddr_model #(
  parameter int ADDR_W   = 33,
  parameter int DATA_W   = 512,
  parameter int ID_W     = 4,
  parameter int RTT      = 20,   // cycles from AR/AW handshake to R/B response
  parameter int MAX_PEND = 16
) (
  input  logic clk,
  input  logic rst_n,

  // Write address
  input  logic [ID_W-1:0]    s_axi_awid,
  input  logic [ADDR_W-1:0]  s_axi_awaddr,
  input  logic [7:0]         s_axi_awlen,
  input  logic [2:0]         s_axi_awsize,
  input  logic [1:0]         s_axi_awburst,
  input  logic               s_axi_awvalid,
  output logic               s_axi_awready,

  // Write data
  input  logic [DATA_W-1:0]  s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic               s_axi_wlast,
  input  logic               s_axi_wvalid,
  output logic               s_axi_wready,

  // Write response
  output logic [ID_W-1:0]    s_axi_bid,
  output logic [1:0]         s_axi_bresp,
  output logic               s_axi_bvalid,
  input  logic               s_axi_bready,

  // Read address
  input  logic [ID_W-1:0]    s_axi_arid,
  input  logic [ADDR_W-1:0]  s_axi_araddr,
  input  logic [7:0]         s_axi_arlen,
  input  logic [2:0]         s_axi_arsize,
  input  logic [1:0]         s_axi_arburst,
  input  logic               s_axi_arvalid,
  output logic               s_axi_arready,

  // Read data
  output logic [ID_W-1:0]    s_axi_rid,
  output logic [DATA_W-1:0]  s_axi_rdata,
  output logic [1:0]         s_axi_rresp,
  output logic               s_axi_rlast,
  output logic               s_axi_rvalid,
  input  logic               s_axi_rready,

  // Stats
  output logic [31:0]        rd_cnt,
  output logic [31:0]        wr_cnt
);

  localparam int STRB_W = DATA_W / 8;

  // Sparse memory: key = beat-aligned byte address
  logic [DATA_W-1:0] mem [logic [ADDR_W-1:0]];

  // Pending write: AW then W, then B after RTT
  typedef struct packed {
    logic                valid;
    logic [ID_W-1:0]     id;
    logic [ADDR_W-1:0]   addr;
    logic [DATA_W-1:0]   data;
    logic [STRB_W-1:0]   strb;
    logic                got_aw;
    logic                got_w;
    logic [15:0]         ttl;
  } wr_pend_t;

  typedef struct packed {
    logic                valid;
    logic [ID_W-1:0]     id;
    logic [ADDR_W-1:0]   addr;
    logic [15:0]         ttl;
  } rd_pend_t;

  wr_pend_t wr_q [0:MAX_PEND-1];
  rd_pend_t rd_q [0:MAX_PEND-1];

  logic [31:0] rd_c, wr_c;
  assign rd_cnt = rd_c;
  assign wr_cnt = wr_c;

  // Align to beat
  function automatic logic [ADDR_W-1:0] beat_addr(input logic [ADDR_W-1:0] a);
    return {a[ADDR_W-1:$clog2(STRB_W)], {$clog2(STRB_W){1'b0}}};
  endfunction

  function automatic logic [DATA_W-1:0] apply_strb(
      input logic [DATA_W-1:0] old_d,
      input logic [DATA_W-1:0] new_d,
      input logic [STRB_W-1:0] strb
  );
    logic [DATA_W-1:0] r;
    for (int i = 0; i < STRB_W; i++)
      r[i*8 +: 8] = strb[i] ? new_d[i*8 +: 8] : old_d[i*8 +: 8];
    return r;
  endfunction

  function automatic int find_free_wr();
    for (int i = 0; i < MAX_PEND; i++)
      if (!wr_q[i].valid) return i;
    return -1;
  endfunction

  function automatic int find_free_rd();
    for (int i = 0; i < MAX_PEND; i++)
      if (!rd_q[i].valid) return i;
    return -1;
  endfunction

  function automatic int find_open_wr_aw();
    for (int i = 0; i < MAX_PEND; i++)
      if (wr_q[i].valid && wr_q[i].got_aw && !wr_q[i].got_w) return i;
    return -1;
  endfunction

  // AW/AR ready if free slot
  logic aw_ok, ar_ok, w_ok;
  int   aw_slot, ar_slot, w_slot;

  always_comb begin
    aw_slot = find_free_wr();
    ar_slot = find_free_rd();
    w_slot  = find_open_wr_aw();
    aw_ok   = (aw_slot >= 0);
    ar_ok   = (ar_slot >= 0);
    w_ok    = (w_slot >= 0);
  end

  assign s_axi_awready = aw_ok;
  assign s_axi_arready = ar_ok;
  assign s_axi_wready  = w_ok;

  // B / R output mux: pick first ready (ttl==0)
  logic        b_fire, r_fire;
  int          b_sel, r_sel;
  logic        b_sel_v, r_sel_v;

  always_comb begin
    b_sel_v = 1'b0;
    b_sel   = 0;
    for (int i = 0; i < MAX_PEND; i++) begin
      if (wr_q[i].valid && wr_q[i].got_aw && wr_q[i].got_w && wr_q[i].ttl == 0 && !b_sel_v) begin
        b_sel_v = 1'b1;
        b_sel   = i;
      end
    end
    r_sel_v = 1'b0;
    r_sel   = 0;
    for (int i = 0; i < MAX_PEND; i++) begin
      if (rd_q[i].valid && rd_q[i].ttl == 0 && !r_sel_v) begin
        r_sel_v = 1'b1;
        r_sel   = i;
      end
    end
  end

  assign s_axi_bvalid = b_sel_v;
  assign s_axi_bid    = b_sel_v ? wr_q[b_sel].id : '0;
  assign s_axi_bresp  = 2'b00;

  logic [DATA_W-1:0] rdata_mux;
  always_comb begin
    rdata_mux = '0;
    if (r_sel_v) begin
      if (mem.exists(rd_q[r_sel].addr))
        rdata_mux = mem[rd_q[r_sel].addr];
      else
        rdata_mux = '0;
    end
  end

  assign s_axi_rvalid = r_sel_v;
  assign s_axi_rid    = r_sel_v ? rd_q[r_sel].id : '0;
  assign s_axi_rdata  = rdata_mux;
  assign s_axi_rresp  = 2'b00;
  assign s_axi_rlast  = r_sel_v;

  assign b_fire = s_axi_bvalid && s_axi_bready;
  assign r_fire = s_axi_rvalid && s_axi_rready;

  integer i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_c <= '0;
      wr_c <= '0;
      for (i = 0; i < MAX_PEND; i++) begin
        wr_q[i] <= '0;
        rd_q[i] <= '0;
      end
      // mem sparse: leave as-is (clear on demand via writes of 0)
    end else begin
      // Countdown
      for (i = 0; i < MAX_PEND; i++) begin
        if (wr_q[i].valid && wr_q[i].got_aw && wr_q[i].got_w && wr_q[i].ttl != 0)
          wr_q[i].ttl <= wr_q[i].ttl - 16'd1;
        if (rd_q[i].valid && rd_q[i].ttl != 0)
          rd_q[i].ttl <= rd_q[i].ttl - 16'd1;
      end

      // Accept AW
      if (s_axi_awvalid && s_axi_awready) begin
        wr_q[aw_slot].valid  <= 1'b1;
        wr_q[aw_slot].id     <= s_axi_awid;
        wr_q[aw_slot].addr   <= beat_addr(s_axi_awaddr);
        wr_q[aw_slot].got_aw <= 1'b1;
        wr_q[aw_slot].got_w  <= 1'b0;
        wr_q[aw_slot].ttl    <= 16'(RTT);
        // ignore len/burst — single-beat only for L1
        if (s_axi_awlen != 0) begin
          // still accept; model is single-beat
        end
      end

      // Accept W (match oldest open AW)
      if (s_axi_wvalid && s_axi_wready) begin
        wr_q[w_slot].data  <= s_axi_wdata;
        wr_q[w_slot].strb  <= s_axi_wstrb;
        wr_q[w_slot].got_w <= 1'b1;
        wr_q[w_slot].ttl   <= 16'(RTT);
        // Commit write immediately into mem (B comes after RTT)
        begin
          logic [DATA_W-1:0] old_d, new_d;
          logic [ADDR_W-1:0] wa;
          wa = wr_q[w_slot].addr;
          // If AW and W same cycle race: use address from AW if just accepted
          old_d = mem.exists(wa) ? mem[wa] : '0;
          new_d = apply_strb(old_d, s_axi_wdata, s_axi_wstrb);
          mem[wa] = new_d;
          wr_c <= wr_c + 32'd1;
        end
      end

      // Accept AR
      if (s_axi_arvalid && s_axi_arready) begin
        rd_q[ar_slot].valid <= 1'b1;
        rd_q[ar_slot].id    <= s_axi_arid;
        rd_q[ar_slot].addr  <= beat_addr(s_axi_araddr);
        rd_q[ar_slot].ttl   <= 16'(RTT);
        rd_c <= rd_c + 32'd1;
      end

      // Complete B
      if (b_fire)
        wr_q[b_sel] <= '0;

      // Complete R
      if (r_fire)
        rd_q[r_sel] <= '0;
    end
  end

  // Silence unused
  logic unused;
  assign unused = |{s_axi_awsize, s_axi_awburst, s_axi_arsize, s_axi_arburst,
                    s_axi_awlen, s_axi_arlen, s_axi_wlast};

endmodule
