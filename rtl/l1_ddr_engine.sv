// -----------------------------------------------------------------------------
// l1_ddr_engine.sv — L1 full-book multi-bank AXI RMW (OrderTable + LevelTable)
// Never backpressure decode: s_valid && !s_ready → drop_cnt++.
// ASYNC=0 single-clock OK for sim. repair_* held 0 in v1.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module l1_ddr_engine
  import md_pkg::*;
  import book_pkg::*;
#(
  parameter int N_BANK       = 4,
  parameter int BANK_FIFO_D  = 64,
  parameter int AXI_ADDR_W   = 33,
  parameter int AXI_DATA_W   = 512,
  parameter int AXI_ID_W     = 4,
  parameter int MAX_OUTSTAND = 4,
  parameter int N_ORDER_L1   = 1024,
  parameter int N_LEVEL_L1   = 1024,
  parameter int MAX_CHAIN    = 8,
  parameter int ASYNC        = 0,
  parameter logic [AXI_ADDR_W-1:0] BASE_ORDER = '0,
  parameter logic [AXI_ADDR_W-1:0] BASE_LEVEL = AXI_ADDR_W'(N_ORDER_L1 * 64)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic clear,

  input  l1_cmd_t s_cmd,
  input  logic    s_valid,
  output logic    s_ready,

  output logic [31:0] push_cnt,
  output logic [31:0] drop_cnt,
  output logic [31:0] done_cnt,
  output logic [31:0] err_cnt,
  output logic [31:0] high_watermark,

  output logic        repair_valid,
  output book_delta_t repair_delta,

  output logic [AXI_ID_W-1:0]      m_axi_awid,
  output logic [AXI_ADDR_W-1:0]    m_axi_awaddr,
  output logic [7:0]               m_axi_awlen,
  output logic [2:0]               m_axi_awsize,
  output logic [1:0]               m_axi_awburst,
  output logic                     m_axi_awvalid,
  input  logic                     m_axi_awready,

  output logic [AXI_DATA_W-1:0]    m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0]  m_axi_wstrb,
  output logic                     m_axi_wlast,
  output logic                     m_axi_wvalid,
  input  logic                     m_axi_wready,

  input  logic [AXI_ID_W-1:0]      m_axi_bid,
  input  logic [1:0]               m_axi_bresp,
  input  logic                     m_axi_bvalid,
  output logic                     m_axi_bready,

  output logic [AXI_ID_W-1:0]      m_axi_arid,
  output logic [AXI_ADDR_W-1:0]    m_axi_araddr,
  output logic [7:0]               m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,

  input  logic [AXI_ID_W-1:0]      m_axi_rid,
  input  logic [AXI_DATA_W-1:0]    m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready
);

  localparam int L1_ORDER_AW = $clog2(N_ORDER_L1);
  localparam int L1_LEVEL_AW = $clog2(N_LEVEL_L1);
  localparam int BANK_AW  = (N_BANK <= 1) ? 1 : $clog2(N_BANK);
  localparam int BF_AW    = $clog2(BANK_FIFO_D);
  localparam int STRB_W   = AXI_DATA_W / 8;
  localparam logic [31:0] SLOT_NULL = 32'hFFFF_FFFF;

  assign repair_valid = 1'b0;
  assign repair_delta = '0;
  logic unused_async; assign unused_async = ASYNC[0];

  // -------------------- helpers --------------------
  function automatic logic [L1_ORDER_AW-1:0] hash_l1(input logic [63:0] oid);
    logic [L1_ORDER_AW-1:0] h; h = '0;
    for (int i = 0; i < 64; i += L1_ORDER_AW) h ^= oid[i +: L1_ORDER_AW];
    return h;
  endfunction

  function automatic logic [BANK_AW-1:0] bank_of(input logic [63:0] oid);
    // N_BANK power-of-2: low bits of hash_l1 (design §4)
    return hash_l1(oid)[BANK_AW-1:0];
  endfunction

  function automatic logic [L1_LEVEL_AW-1:0] hash_level(
      input logic [47:0] code, input logic [1:0] side, input logic [63:0] px);
    logic [63:0] mix;
    mix = {16'b0, code} ^ px ^ {62'b0, side};
    return mix[L1_LEVEL_AW-1:0] ^ mix[32 +: L1_LEVEL_AW];
  endfunction

  function automatic logic [AXI_ADDR_W-1:0] order_addr(input logic [31:0] slot);
    return BASE_ORDER + AXI_ADDR_W'(slot * 32'd64);
  endfunction
  function automatic logic [AXI_ADDR_W-1:0] level_addr(input logic [L1_LEVEL_AW-1:0] k);
    return BASE_LEVEL + AXI_ADDR_W'(32'(k) * 32'd64);
  endfunction

  function automatic logic        o_valid(input logic [AXI_DATA_W-1:0] d); return d[0]; endfunction
  function automatic logic [1:0]  o_side (input logic [AXI_DATA_W-1:0] d); return d[2:1]; endfunction
  function automatic logic [63:0] o_oid  (input logic [AXI_DATA_W-1:0] d); return d[127:64]; endfunction
  function automatic logic [47:0] o_code (input logic [AXI_DATA_W-1:0] d); return d[175:128]; endfunction
  function automatic logic [63:0] o_px   (input logic [AXI_DATA_W-1:0] d); return d[255:192]; endfunction
  function automatic logic [31:0] o_qty  (input logic [AXI_DATA_W-1:0] d); return d[287:256]; endfunction
  function automatic logic [31:0] o_seq  (input logic [AXI_DATA_W-1:0] d); return d[319:288]; endfunction
  function automatic logic [31:0] o_next (input logic [AXI_DATA_W-1:0] d); return d[351:320]; endfunction

  function automatic logic [AXI_DATA_W-1:0] pack_ord(
      input logic v, input logic [1:0] side, input logic [63:0] oid,
      input logic [47:0] code, input logic [63:0] px,
      input logic [31:0] qty, input logic [31:0] seq, input logic [31:0] nxt);
    logic [AXI_DATA_W-1:0] d; d = '0;
    d[0]=v; d[2:1]=side; d[127:64]=oid; d[175:128]=code;
    d[255:192]=px; d[287:256]=qty; d[319:288]=seq; d[351:320]=nxt;
    return d;
  endfunction

  function automatic logic        l_valid(input logic [AXI_DATA_W-1:0] d); return d[0]; endfunction
  function automatic logic [1:0]  l_side (input logic [AXI_DATA_W-1:0] d); return d[2:1]; endfunction
  function automatic logic [63:0] l_px   (input logic [AXI_DATA_W-1:0] d); return d[127:64]; endfunction
  function automatic logic [31:0] l_qty  (input logic [AXI_DATA_W-1:0] d); return d[159:128]; endfunction
  function automatic logic [47:0] l_code (input logic [AXI_DATA_W-1:0] d); return d[207:160]; endfunction

  function automatic logic [AXI_DATA_W-1:0] pack_lvl(
      input logic v, input logic [1:0] side, input logic [63:0] px,
      input logic [31:0] qty, input logic [47:0] code, input logic [31:0] seq);
    logic [AXI_DATA_W-1:0] d; d = '0;
    d[0]=v; d[2:1]=side; d[127:64]=px; d[159:128]=qty; d[207:160]=code; d[239:208]=seq;
    return d;
  endfunction

  function automatic logic is_null_slot(input logic [31:0] n);
    return (n == SLOT_NULL) || (n == 32'h0);
  endfunction

  function automatic logic lvl_key_eq(
      input logic [AXI_DATA_W-1:0] d,
      input logic [47:0] code, input logic [1:0] side, input logic [63:0] px);
    return l_valid(d) && l_code(d)==code && l_side(d)==side && l_px(d)==px;
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] c);
    return (c == 32'hFFFF_FFFF) ? c : c + 32'd1;
  endfunction

  // -------------------- bank FIFOs --------------------
  l1_cmd_t            bf_mem [0:N_BANK-1][0:BANK_FIFO_D-1];
  logic [BF_AW:0]     bf_wptr [0:N_BANK-1], bf_rptr [0:N_BANK-1];

  function automatic logic [BF_AW:0] bf_occ(input int b);
    return bf_wptr[b] - bf_rptr[b];
  endfunction
  function automatic logic bf_full_f(input int b);
    return bf_occ(b) >= (BF_AW+1)'(BANK_FIFO_D);
  endfunction
  function automatic logic bf_empty_f(input int b);
    return bf_wptr[b] == bf_rptr[b];
  endfunction

  wire [BANK_AW-1:0] in_bank = bank_of(s_cmd.order_id);
  assign s_ready = !s_valid || !bf_full_f(int'(in_bank));

  logic [31:0] push_q, drop_q, done_q, err_q, hwm_q;
  assign push_cnt = push_q; assign drop_cnt = drop_q;
  assign done_cnt = done_q; assign err_cnt = err_q;
  assign high_watermark = hwm_q;

  // -------------------- AXI slot scoreboard --------------------
  typedef enum logic [2:0] {AX_EMPTY, AX_AR, AX_R, AX_AW, AX_W, AX_B} ax_st_e;
  typedef struct packed {
    logic                  v;
    logic [BANK_AW-1:0]    bank;
    logic                  wr;
    logic [AXI_ADDR_W-1:0] addr;
    logic [AXI_DATA_W-1:0] wdata;
    ax_st_e                st;
  } ax_t;
  ax_t axq [0:MAX_OUTSTAND-1];

  logic [N_BANK-1:0] brq_v, brq_wr, brq_accept, bcp_v, bcp_wr;
  logic [AXI_ADDR_W-1:0] brq_addr [0:N_BANK-1];
  logic [AXI_DATA_W-1:0] brq_wdata[0:N_BANK-1];
  logic [AXI_DATA_W-1:0] bcp_data [0:N_BANK-1];

  logic [BANK_AW-1:0] rr_ptr;

  function automatic int ax_free_idx();
    for (int i = 0; i < MAX_OUTSTAND; i++) if (!axq[i].v) return i;
    return -1;
  endfunction
  function automatic int ax_idx_st(input ax_st_e s);
    for (int i = 0; i < MAX_OUTSTAND; i++) if (axq[i].v && axq[i].st == s) return i;
    return -1;
  endfunction
  function automatic logic bank_busy(input logic [BANK_AW-1:0] b);
    for (int i = 0; i < MAX_OUTSTAND; i++) if (axq[i].v && axq[i].bank == b) return 1'b1;
    return 1'b0;
  endfunction

  logic               rr_found;
  logic [BANK_AW-1:0] rr_sel;
  always_comb begin
    rr_found = 1'b0;
    rr_sel   = '0;
    for (int off = 0; off < N_BANK; off++) begin
      logic [BANK_AW-1:0] cand;
      cand = BANK_AW'( (int'(rr_ptr) + off) % N_BANK );
      if (!rr_found && brq_v[cand] && !bank_busy(cand)) begin
        rr_found = 1'b1;
        rr_sel   = cand;
      end
    end
  end

  int aw_i, w_i, ar_i;
  always_comb begin
    aw_i = ax_idx_st(AX_AW);
    w_i  = ax_idx_st(AX_W);
    ar_i = ax_idx_st(AX_AR);
  end

  assign m_axi_awlen=0; assign m_axi_arlen=0;
  assign m_axi_awsize=3'($clog2(STRB_W)); assign m_axi_arsize=3'($clog2(STRB_W));
  assign m_axi_awburst=2'b01; assign m_axi_arburst=2'b01;
  assign m_axi_wstrb={STRB_W{1'b1}}; assign m_axi_wlast=1'b1;
  assign m_axi_bready=1'b1; assign m_axi_rready=1'b1;

  assign m_axi_awvalid = (aw_i>=0);
  assign m_axi_awid    = (aw_i>=0) ? AXI_ID_W'(axq[aw_i].bank) : '0;
  assign m_axi_awaddr  = (aw_i>=0) ? axq[aw_i].addr : '0;
  assign m_axi_wvalid  = (w_i>=0);
  assign m_axi_wdata   = (w_i>=0) ? axq[w_i].wdata : '0;
  assign m_axi_arvalid = (ar_i>=0);
  assign m_axi_arid    = (ar_i>=0) ? AXI_ID_W'(axq[ar_i].bank) : '0;
  assign m_axi_araddr  = (ar_i>=0) ? axq[ar_i].addr : '0;

  // -------------------- bank FSM --------------------
  typedef enum logic [4:0] {
    ST_IDLE,
    ST_ISSUE_ORD_RD, ST_WAIT_ORD_RD,
    ST_ISSUE_ORD_WR, ST_WAIT_ORD_WR,
    ST_ISSUE_LNK_RD, ST_WAIT_LNK_RD,
    ST_ISSUE_LNK_WR, ST_WAIT_LNK_WR,
    ST_ISSUE_LVL_RD, ST_WAIT_LVL_RD,
    ST_ISSUE_LVL_WR, ST_WAIT_LVL_WR,
    ST_DONE, ST_ERR
  } st_e;

  typedef enum logic [1:0] {PH_ADD, PH_CXL, PH_TRADE} phase_e;

  st_e    st   [0:N_BANK-1];
  phase_e ph   [0:N_BANK-1];
  l1_cmd_t cmd [0:N_BANK-1];

  logic [31:0] cur_slot [0:N_BANK-1];
  logic [31:0] link_slot[0:N_BANK-1];
  logic [31:0] new_slot [0:N_BANK-1];
  logic [3:0]  depth    [0:N_BANK-1];
  logic        need_link[0:N_BANK-1];
  logic        found    [0:N_BANK-1];
  logic [AXI_DATA_W-1:0] ord_beat[0:N_BANK-1];
  logic [AXI_DATA_W-1:0] lnk_beat[0:N_BANK-1];
  logic [AXI_DATA_W-1:0] lvl_beat[0:N_BANK-1];
  logic [63:0] sav_px  [0:N_BANK-1];
  logic [31:0] sav_qty [0:N_BANK-1];
  logic [1:0]  sav_side[0:N_BANK-1];
  logic [47:0] sav_code[0:N_BANK-1];
  logic [31:0] delta_q [0:N_BANK-1]; // qty delta for level (+add / -cxl/trade)
  logic        lvl_add [0:N_BANK-1]; // 1=add to level, 0=sub

  integer bi, ai;

  always_ff @(posedge clk or negedge rst_n) begin
    logic [BF_AW:0] occ, maxocc;
    int fi;
    logic [L1_ORDER_AW-1:0] h0;
    logic [L1_LEVEL_AW-1:0] lk;
    logic [31:0] nqty, probe;
    logic [AXI_DATA_W-1:0] wb;
    logic hit_oid, empty_sl;
    logic [BANK_AW-1:0] bb;

    if (!rst_n) begin
      push_q<=0; drop_q<=0; done_q<=0; err_q<=0; hwm_q<=0; rr_ptr<=0;
      for (bi=0; bi<N_BANK; bi++) begin
        bf_wptr[bi]<=0; bf_rptr[bi]<=0;
        st[bi]<=ST_IDLE; brq_v[bi]<=0; bcp_v[bi]<=0;
      end
      for (ai=0; ai<MAX_OUTSTAND; ai++) axq[ai]<= '0;
    end else if (clear) begin
      push_q<=0; drop_q<=0; done_q<=0; err_q<=0; hwm_q<=0;
      for (bi=0; bi<N_BANK; bi++) begin
        bf_wptr[bi]<=0; bf_rptr[bi]<=0;
        st[bi]<=ST_IDLE; brq_v[bi]<=0;
      end
      for (ai=0; ai<MAX_OUTSTAND; ai++) axq[ai]<= '0;
    end else begin
      // clear 1-cycle accepts / completions
      for (bi=0; bi<N_BANK; bi++) begin
        brq_accept[bi] <= 1'b0;
        bcp_v[bi]      <= 1'b0;
      end

      // ---- ingress ----
      if (s_valid) begin
        bb = in_bank;
        if (!bf_full_f(int'(bb))) begin
          bf_mem[bb][bf_wptr[bb][BF_AW-1:0]] <= s_cmd;
          bf_wptr[bb] <= bf_wptr[bb] + (BF_AW+1)'(1);
          push_q <= sat_inc(push_q);
        end else
          drop_q <= sat_inc(drop_q);
      end

      maxocc = 0;
      for (bi=0; bi<N_BANK; bi++) begin
        occ = bf_occ(bi);
        if (occ > maxocc) maxocc = occ;
      end
      if (32'(maxocc) > hwm_q) hwm_q <= 32'(maxocc);

      // ---- AXI accept new from RR ----
      fi = ax_free_idx();
      if (rr_found && fi >= 0) begin
        axq[fi].v     <= 1'b1;
        axq[fi].bank  <= rr_sel;
        axq[fi].wr    <= brq_wr[rr_sel];
        axq[fi].addr  <= brq_addr[rr_sel];
        axq[fi].wdata <= brq_wdata[rr_sel];
        axq[fi].st    <= brq_wr[rr_sel] ? AX_AW : AX_AR;
        brq_accept[rr_sel] <= 1'b1;
        brq_v[rr_sel]      <= 1'b0;
        rr_ptr <= BANK_AW'((int'(rr_sel)+1) % N_BANK);
      end

      // ---- AXI progress ----
      for (ai=0; ai<MAX_OUTSTAND; ai++) if (axq[ai].v) begin
        unique case (axq[ai].st)
          AX_AR: if (m_axi_arvalid && m_axi_arready && ar_i==ai) axq[ai].st <= AX_R;
          AX_R:  if (m_axi_rvalid && m_axi_rid==AXI_ID_W'(axq[ai].bank)) begin
                   bcp_v[axq[ai].bank]    <= 1'b1;
                   bcp_wr[axq[ai].bank]   <= 1'b0;
                   bcp_data[axq[ai].bank] <= m_axi_rdata;
                   axq[ai] <= '0;
                 end
          AX_AW: if (m_axi_awvalid && m_axi_awready && aw_i==ai) axq[ai].st <= AX_W;
          AX_W:  if (m_axi_wvalid && m_axi_wready && w_i==ai) axq[ai].st <= AX_B;
          AX_B:  if (m_axi_bvalid && m_axi_bid==AXI_ID_W'(axq[ai].bank)) begin
                   bcp_v[axq[ai].bank]  <= 1'b1;
                   bcp_wr[axq[ai].bank] <= 1'b1;
                   bcp_data[axq[ai].bank] <= '0;
                   axq[ai] <= '0;
                 end
          default: ;
        endcase
      end

      // ---- banks ----
      for (bi=0; bi<N_BANK; bi++) begin
        unique case (st[bi])
          ST_IDLE: begin
            if (!bf_empty_f(bi)) begin
              cmd[bi] <= bf_mem[bi][bf_rptr[bi][BF_AW-1:0]];
              bf_rptr[bi] <= bf_rptr[bi] + (BF_AW+1)'(1);
              h0 = hash_l1(bf_mem[bi][bf_rptr[bi][BF_AW-1:0]].order_id);
              // use cmd after nonblocking — recompute from mem
              cur_slot[bi]  <= 32'(hash_l1(bf_mem[bi][bf_rptr[bi][BF_AW-1:0]].order_id));
              depth[bi]     <= 0;
              found[bi]     <= 0;
              need_link[bi] <= 0;
              link_slot[bi] <= SLOT_NULL;
              new_slot[bi]  <= SLOT_NULL;
              if (bf_mem[bi][bf_rptr[bi][BF_AW-1:0]].op == OP_ADD) begin
                ph[bi] <= PH_ADD; st[bi] <= ST_ISSUE_ORD_RD;
              end else if (bf_mem[bi][bf_rptr[bi][BF_AW-1:0]].op == OP_CXL) begin
                ph[bi] <= PH_CXL; st[bi] <= ST_ISSUE_ORD_RD;
              end else if (bf_mem[bi][bf_rptr[bi][BF_AW-1:0]].op == OP_TRADE) begin
                ph[bi] <= PH_TRADE; st[bi] <= ST_ISSUE_ORD_RD;
              end else begin
                err_q <= sat_inc(err_q); st[bi] <= ST_IDLE;
              end
            end
          end

          ST_ISSUE_ORD_RD: begin
            if (!brq_v[bi]) begin
              brq_v[bi]<=1; brq_wr[bi]<=0;
              brq_addr[bi]<=order_addr(cur_slot[bi]);
              st[bi]<=ST_WAIT_ORD_RD;
            end
          end

          ST_WAIT_ORD_RD: begin
            if (brq_accept[bi]) brq_v[bi]<=0;
            if (bcp_v[bi] && !bcp_wr[bi]) begin
              ord_beat[bi] <= bcp_data[bi];
              empty_sl = !o_valid(bcp_data[bi]);
              hit_oid  = o_valid(bcp_data[bi]) &&
                         (o_oid(bcp_data[bi]) == cmd[bi].order_id);

              if (ph[bi] == PH_ADD) begin
                if (empty_sl || hit_oid) begin
                  found[bi] <= hit_oid;
                  // write order here
                  st[bi] <= ST_ISSUE_ORD_WR;
                end else if (!is_null_slot(o_next(bcp_data[bi])) &&
                            depth[bi] + 4'd1 < 4'(MAX_CHAIN)) begin
                  cur_slot[bi] <= o_next(bcp_data[bi]);
                  depth[bi]    <= depth[bi] + 4'd1;
                  st[bi]       <= ST_ISSUE_ORD_RD;
                end else if (depth[bi] + 4'd1 >= 4'(MAX_CHAIN)) begin
                  err_q <= sat_inc(err_q); st[bi] <= ST_IDLE;
                end else begin
                  // allocate probe slot and link
                  probe = (32'(hash_l1(cmd[bi].order_id)) + 32'(depth[bi]) + 32'd1) % 32'(N_ORDER_L1);
                  // avoid primary
                  if (probe == 32'(hash_l1(cmd[bi].order_id)))
                    probe = (probe + 32'd1) % 32'(N_ORDER_L1);
                  need_link[bi] <= 1'b1;
                  link_slot[bi] <= cur_slot[bi];
                  lnk_beat[bi]  <= bcp_data[bi]; // current end-of-chain
                  new_slot[bi]  <= probe;
                  cur_slot[bi]  <= probe;
                  depth[bi]     <= depth[bi] + 4'd1;
                  // verify free
                  st[bi] <= ST_ISSUE_ORD_RD;
                end
              end else begin
                // CXL / TRADE: find oid
                if (hit_oid) begin
                  found[bi]    <= 1'b1;
                  sav_px[bi]   <= o_px(bcp_data[bi]);
                  sav_qty[bi]  <= o_qty(bcp_data[bi]);
                  sav_side[bi] <= o_side(bcp_data[bi]);
                  sav_code[bi] <= o_code(bcp_data[bi]);
                  st[bi] <= ST_ISSUE_ORD_WR;
                end else if (empty_sl || is_null_slot(o_next(bcp_data[bi])) ||
                            depth[bi] + 4'd1 >= 4'(MAX_CHAIN)) begin
                  // orphan
                  err_q <= sat_inc(err_q); st[bi] <= ST_IDLE;
                end else begin
                  cur_slot[bi] <= o_next(bcp_data[bi]);
                  depth[bi]    <= depth[bi] + 4'd1;
                  st[bi]       <= ST_ISSUE_ORD_RD;
                end
              end
            end
          end

          ST_ISSUE_ORD_WR: begin
            if (!brq_v[bi]) begin
              if (ph[bi] == PH_ADD) begin
                wb = pack_ord(1'b1, cmd[bi].side, cmd[bi].order_id, cmd[bi].code,
                              cmd[bi].px, cmd[bi].qty, cmd[bi].seq,
                              is_null_slot(o_next(ord_beat[bi])) ? SLOT_NULL : o_next(ord_beat[bi]));
                // if we landed on a "probe" that was accidentally valid other oid,
                // treated earlier; here empty or match
                delta_q[bi] <= cmd[bi].qty;
                lvl_add[bi] <= 1'b1;
                sav_px[bi]  <= cmd[bi].px;
                sav_side[bi]<= cmd[bi].side;
                sav_code[bi]<= cmd[bi].code;
              end else if (ph[bi] == PH_CXL) begin
                wb = pack_ord(1'b0, 2'b0, 64'b0, 48'b0, 64'b0, 32'b0, 32'b0,
                              o_next(ord_beat[bi]));
                delta_q[bi] <= sav_qty[bi];
                lvl_add[bi] <= 1'b0;
              end else begin // TRADE
                if (sav_qty[bi] <= cmd[bi].qty) begin
                  wb = pack_ord(1'b0, 2'b0, 64'b0, 48'b0, 64'b0, 32'b0, 32'b0,
                                o_next(ord_beat[bi]));
                  delta_q[bi] <= sav_qty[bi];
                end else begin
                  nqty = sav_qty[bi] - cmd[bi].qty;
                  wb = pack_ord(1'b1, sav_side[bi], cmd[bi].order_id, sav_code[bi],
                                sav_px[bi], nqty, cmd[bi].seq, o_next(ord_beat[bi]));
                  delta_q[bi] <= cmd[bi].qty;
                end
                lvl_add[bi] <= 1'b0;
              end
              brq_v[bi]<=1; brq_wr[bi]<=1;
              brq_addr[bi]<=order_addr(cur_slot[bi]);
              brq_wdata[bi]<=wb;
              st[bi]<=ST_WAIT_ORD_WR;
            end
          end

          ST_WAIT_ORD_WR: begin
            if (brq_accept[bi]) brq_v[bi]<=0;
            if (bcp_v[bi] && bcp_wr[bi]) begin
              if (need_link[bi] && ph[bi]==PH_ADD && !found[bi])
                st[bi] <= ST_ISSUE_LNK_WR; // have lnk_beat already
              else
                st[bi] <= ST_ISSUE_LVL_RD;
            end
          end

          // patch previous next_slot → new_slot (no re-read; use lnk_beat)
          ST_ISSUE_LNK_WR: begin
            if (!brq_v[bi]) begin
              wb = pack_ord(o_valid(lnk_beat[bi]), o_side(lnk_beat[bi]),
                            o_oid(lnk_beat[bi]), o_code(lnk_beat[bi]),
                            o_px(lnk_beat[bi]), o_qty(lnk_beat[bi]),
                            o_seq(lnk_beat[bi]), new_slot[bi]);
              brq_v[bi]<=1; brq_wr[bi]<=1;
              brq_addr[bi]<=order_addr(link_slot[bi]);
              brq_wdata[bi]<=wb;
              need_link[bi]<=0;
              st[bi]<=ST_WAIT_LNK_WR;
            end
          end
          ST_WAIT_LNK_WR: begin
            if (brq_accept[bi]) brq_v[bi]<=0;
            if (bcp_v[bi] && bcp_wr[bi]) st[bi] <= ST_ISSUE_LVL_RD;
          end

          ST_ISSUE_LVL_RD: begin
            if (!brq_v[bi]) begin
              lk = hash_level(sav_code[bi], sav_side[bi], sav_px[bi]);
              brq_v[bi]<=1; brq_wr[bi]<=0;
              brq_addr[bi]<=level_addr(lk);
              st[bi]<=ST_WAIT_LVL_RD;
            end
          end

          ST_WAIT_LVL_RD: begin
            if (brq_accept[bi]) brq_v[bi]<=0;
            if (bcp_v[bi] && !bcp_wr[bi]) begin
              lvl_beat[bi] <= bcp_data[bi];
              st[bi] <= ST_ISSUE_LVL_WR;
            end
          end

          ST_ISSUE_LVL_WR: begin
            if (!brq_v[bi]) begin
              if (lvl_add[bi]) begin
                if (lvl_key_eq(lvl_beat[bi], sav_code[bi], sav_side[bi], sav_px[bi]))
                  nqty = l_qty(lvl_beat[bi]) + delta_q[bi];
                else
                  nqty = delta_q[bi];
                wb = pack_lvl(1'b1, sav_side[bi], sav_px[bi], nqty,
                              sav_code[bi], cmd[bi].seq);
              end else begin
                if (lvl_key_eq(lvl_beat[bi], sav_code[bi], sav_side[bi], sav_px[bi])) begin
                  if (l_qty(lvl_beat[bi]) <= delta_q[bi])
                    wb = pack_lvl(1'b0, 2'b0, 64'b0, 32'b0, 48'b0, 32'b0);
                  else begin
                    nqty = l_qty(lvl_beat[bi]) - delta_q[bi];
                    wb = pack_lvl(1'b1, sav_side[bi], sav_px[bi], nqty,
                                  sav_code[bi], cmd[bi].seq);
                  end
                end else begin
                  // level missing — still done (orphan level); no write needed
                  wb = lvl_beat[bi];
                end
              end
              brq_v[bi]<=1; brq_wr[bi]<=1;
              lk = hash_level(sav_code[bi], sav_side[bi], sav_px[bi]);
              brq_addr[bi]<=level_addr(lk);
              brq_wdata[bi]<=wb;
              st[bi]<=ST_WAIT_LVL_WR;
            end
          end

          ST_WAIT_LVL_WR: begin
            if (brq_accept[bi]) brq_v[bi]<=0;
            if (bcp_v[bi] && bcp_wr[bi]) begin
              done_q <= sat_inc(done_q);
              st[bi] <= ST_IDLE;
            end
          end

          default: st[bi] <= ST_IDLE;
        endcase
      end
    end
  end

  // silence unused
  logic [1:0] unused_resp;
  assign unused_resp = m_axi_bresp | m_axi_rresp;
  logic unused_rlast; assign unused_rlast = m_axi_rlast;

endmodule
