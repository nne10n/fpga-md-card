"""Shared helpers for L1 DDR cocotb tests."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

OP_ADD = 0
OP_CXL = 1
OP_TRADE = 2
SIDE_BID = 1
SIDE_ASK = 2


async def reset(dut, n=5):
    dut.rst_n.value = 0
    dut.clear.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_op.value = 0
    dut.cmd_order_id.value = 0
    dut.cmd_hot_id.value = 0
    dut.cmd_code.value = 0
    dut.cmd_side.value = 0
    dut.cmd_px.value = 0
    dut.cmd_qty.value = 0
    dut.cmd_seq.value = 0
    dut.cmd_ts_ns.value = 0
    for _ in range(n):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


async def push_cmd(
    dut,
    *,
    op: int,
    oid: int,
    code: int,
    side: int,
    px: int,
    qty: int,
    seq: int = 1,
    hot_id: int = 0,
    ts: int = 1,
    expect_accept: bool | None = None,
):
    dut.cmd_op.value = op
    dut.cmd_order_id.value = oid
    dut.cmd_hot_id.value = hot_id
    dut.cmd_code.value = code & ((1 << 48) - 1)
    dut.cmd_side.value = side
    dut.cmd_px.value = px
    dut.cmd_qty.value = qty
    dut.cmd_seq.value = seq
    dut.cmd_ts_ns.value = ts
    dut.cmd_valid.value = 1
    await RisingEdge(dut.clk)
    ready = int(dut.cmd_ready.value)
    dut.cmd_valid.value = 0
    if expect_accept is True:
        assert ready == 1, "expected accept"
    if expect_accept is False:
        assert ready == 0, "expected drop/backpressure on L1 fifo"
    return ready


async def wait_done(dut, target: int, timeout_cycles: int = 5000):
    for _ in range(timeout_cycles):
        if int(dut.done_cnt.value) >= target:
            return
        await RisingEdge(dut.clk)
    raise AssertionError(
        f"timeout waiting done_cnt>={target}: done={int(dut.done_cnt.value)} "
        f"err={int(dut.err_cnt.value)} push={int(dut.push_cnt.value)} "
        f"drop={int(dut.drop_cnt.value)}"
    )


def start_clock(dut, period_ns=10):
    cocotb.start_soon(Clock(dut.clk, period_ns, unit="ns").start())
