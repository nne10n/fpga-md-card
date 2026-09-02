// -----------------------------------------------------------------------------
// tb_l1_top.sv — l1_ddr_engine + axi_ddr_model harness for make sim-l1
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_l1_top
  import md_pkg::*;
  import book_pkg::*;
#(
  parameter int N_BANK       = 4,
  parameter int BANK_FIFO_D  = 8,    // small for drop test
  parameter int RTT          = 4,
  parameter int MAX_OUTSTAND = 4,
  parameter int N_ORDER_L1   = 1024,
  parameter int N_LEVEL_L1   = 1024
) (
  input  logic clk,
  input  logic rst_n,
  input  logic clear,

  // Flat l1_cmd fields (cocotb-friendly)
  input  logic [2:0]  cmd_op,
  input  logic [63:0] cmd_order_id,
  input  logic [6:0]  cmd_hot_id,
  input  logic [47:0] cmd_code,
  input  logic [1:0]  cmd_side,
  input  logic [63:0] cmd_px,
  input  logic [31:0] cmd_qty,
  input  logic [31:0] cmd_seq,
  input  logic [63:0] cmd_ts_ns,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  output logic [31:0] push_cnt,
  output logic [31:0] drop_cnt,
  output logic [31:0] done_cnt,
  output logic [31:0] err_cnt,
  output logic [31:0] high_watermark,

  output logic [31:0] ddr_rd_cnt,
  output logic [31:0] ddr_wr_cnt
);

  l1_cmd_t s_cmd;
  always_comb begin
    s_cmd.op       = book_op_e'(cmd_op);
    s_cmd.order_id = cmd_order_id;
    s_cmd.hot_id   = cmd_hot_id;
    s_cmd.code     = cmd_code;
    s_cmd.side     = cmd_side;
    s_cmd.px       = cmd_px;
    s_cmd.qty      = cmd_qty;
    s_cmd.seq      = cmd_seq;
    s_cmd.ts_ns    = cmd_ts_ns;
  end

  logic [3:0]  awid, arid, bid, rid;
  logic [32:0] awaddr, araddr;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst, bresp, rresp;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic        arvalid, arready, rvalid, rready, wlast, rlast;
  logic [511:0] wdata, rdata;
  logic [63:0]  wstrb;
  logic         repair_v;
  book_delta_t  repair_d;

  l1_ddr_engine #(
    .N_BANK(N_BANK),
    .BANK_FIFO_D(BANK_FIFO_D),
    .MAX_OUTSTAND(MAX_OUTSTAND),
    .N_ORDER_L1(N_ORDER_L1),
    .N_LEVEL_L1(N_LEVEL_L1),
    .ASYNC(0)
  ) u_l1 (
    .clk(clk), .rst_n(rst_n), .clear(clear),
    .s_cmd(s_cmd), .s_valid(cmd_valid), .s_ready(cmd_ready),
    .push_cnt(push_cnt), .drop_cnt(drop_cnt),
    .done_cnt(done_cnt), .err_cnt(err_cnt), .high_watermark(high_watermark),
    .repair_valid(repair_v), .repair_delta(repair_d),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
    .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
    .m_axi_arsize(arsize), .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
    .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  axi_ddr_model #(.ADDR_W(33), .DATA_W(512), .ID_W(4), .RTT(RTT)) u_ddr (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
    .s_axi_awsize(awsize), .s_axi_awburst(awburst),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
    .s_axi_arsize(arsize), .s_axi_arburst(arburst),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
    .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .rd_cnt(ddr_rd_cnt), .wr_cnt(ddr_wr_cnt)
  );

  logic unused_rep; assign unused_rep = ^{repair_v, repair_d};

endmodule
