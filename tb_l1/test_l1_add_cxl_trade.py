#!/usr/bin/env python3
"""L1.4: ADD / CXL / TRADE RMW against OrderTable + LevelTable."""
from __future__ import annotations

import cocotb

from l1_helpers import (
    OP_ADD,
    OP_CXL,
    OP_TRADE,
    SIDE_BID,
    push_cmd,
    reset,
    start_clock,
    wait_done,
)

CODE = int.from_bytes(b"000001", "little")


@cocotb.test()
async def test_l1_add_cxl_trade(dut):
    start_clock(dut)
    await reset(dut)

    # ADD oid=1 qty=10
    assert await push_cmd(
        dut, op=OP_ADD, oid=1, code=CODE, side=SIDE_BID, px=100, qty=10, seq=1,
        expect_accept=True,
    )
    await wait_done(dut, 1)
    assert int(dut.err_cnt.value) == 0
    assert int(dut.push_cnt.value) == 1

    # ADD oid=2 same px qty=5 → level accumulates (done=2)
    assert await push_cmd(
        dut, op=OP_ADD, oid=2, code=CODE, side=SIDE_BID, px=100, qty=5, seq=2,
        expect_accept=True,
    )
    await wait_done(dut, 2)

    # CXL oid=1 → level -=10
    assert await push_cmd(
        dut, op=OP_CXL, oid=1, code=CODE, side=SIDE_BID, px=100, qty=10, seq=3,
        expect_accept=True,
    )
    await wait_done(dut, 3)
    assert int(dut.err_cnt.value) == 0

    # TRADE oid=2 qty=5 → clear order, level→0
    assert await push_cmd(
        dut, op=OP_TRADE, oid=2, code=CODE, side=SIDE_BID, px=100, qty=5, seq=4,
        expect_accept=True,
    )
    await wait_done(dut, 4)
    assert int(dut.err_cnt.value) == 0
    assert int(dut.done_cnt.value) == 4
    assert int(dut.ddr_rd_cnt.value) >= 4
    assert int(dut.ddr_wr_cnt.value) >= 4

    # Orphan CXL → err_cnt
    assert await push_cmd(
        dut, op=OP_CXL, oid=99, code=CODE, side=SIDE_BID, px=100, qty=1, seq=5,
        expect_accept=True,
    )
    # orphan ends without done++
    for _ in range(400):
        if int(dut.err_cnt.value) >= 1:
            break
        await cocotb.triggers.RisingEdge(dut.clk)
    assert int(dut.err_cnt.value) >= 1
    assert int(dut.done_cnt.value) == 4
