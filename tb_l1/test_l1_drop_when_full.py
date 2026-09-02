#!/usr/bin/env python3
"""L1.4: when bank FIFO full, drop cmd (drop_cnt++); never stall forever."""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from l1_helpers import OP_ADD, SIDE_BID, push_cmd, reset, start_clock

CODE = int.from_bytes(b"000003", "little")


def bank_of(oid: int, n_order: int = 1024, n_bank: int = 4) -> int:
    aw = (n_order - 1).bit_length()
    h = 0
    x = oid & ((1 << 64) - 1)
    for i in range(0, 64, aw):
        h ^= (x >> i) & ((1 << aw) - 1)
    h &= (1 << aw) - 1
    return h & (n_bank - 1)


@cocotb.test()
async def test_l1_drop_when_full(dut):
    start_clock(dut)
    await reset(dut)

    # Flood a single bank: BANK_FIFO_D=8 in tb_l1_top
    target_bank = 0
    oids = [oid for oid in range(1, 20000) if bank_of(oid) == target_bank]
    assert len(oids) >= 32

    accepted = 0
    dropped = 0
    # Push many back-to-back into same bank while DDR is slow (RTT=4) so FIFO fills
    for i, oid in enumerate(oids[:40]):
        dut.cmd_op.value = OP_ADD
        dut.cmd_order_id.value = oid
        dut.cmd_hot_id.value = 0
        dut.cmd_code.value = CODE
        dut.cmd_side.value = SIDE_BID
        dut.cmd_px.value = 50
        dut.cmd_qty.value = 1
        dut.cmd_seq.value = i + 1
        dut.cmd_ts_ns.value = 1
        dut.cmd_valid.value = 1
        await RisingEdge(dut.clk)
        if int(dut.cmd_ready.value) == 1:
            accepted += 1
        else:
            dropped += 1
    dut.cmd_valid.value = 0

    # Give some cycles for counters to settle
    for _ in range(5):
        await RisingEdge(dut.clk)

    assert dropped >= 1, f"expected drops, accepted={accepted} dropped={dropped}"
    assert int(dut.drop_cnt.value) == dropped
    assert int(dut.push_cnt.value) == accepted
    # cmd_ready must come back eventually (engine drains)
    recovered = False
    for _ in range(20000):
        await RisingEdge(dut.clk)
        # probe ready with valid=0 path: ready is 1 when !valid || !full
        if int(dut.cmd_ready.value) == 1 and int(dut.drop_cnt.value) >= 1:
            # try one more push into same bank
            r = await push_cmd(
                dut,
                op=OP_ADD,
                oid=oids[100],
                code=CODE,
                side=SIDE_BID,
                px=51,
                qty=1,
                seq=999,
            )
            if r == 1:
                recovered = True
                break
    assert recovered, "L1 never recovered ready after drain"
    assert int(dut.high_watermark.value) >= 1
