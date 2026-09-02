#!/usr/bin/env python3
"""L1.4: different order_ids map to different banks; parallel progress."""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from l1_helpers import OP_ADD, SIDE_BID, push_cmd, reset, start_clock, wait_done

CODE = int.from_bytes(b"000002", "little")


def bank_of(oid: int, n_order: int = 1024, n_bank: int = 4) -> int:
    """Match RTL hash_l1 fold + low bits."""
    aw = (n_order - 1).bit_length()  # clog2
    h = 0
    x = oid & ((1 << 64) - 1)
    for i in range(0, 64, aw):
        h ^= (x >> i) & ((1 << aw) - 1)
    h &= (1 << aw) - 1
    return h & (n_bank - 1)


@cocotb.test()
async def test_l1_bank_parallel(dut):
    start_clock(dut)
    await reset(dut)

    # Pick 4 oids with distinct banks
    chosen = []
    banks = set()
    for oid in range(1, 5000):
        b = bank_of(oid)
        if b not in banks:
            banks.add(b)
            chosen.append(oid)
        if len(chosen) == 4:
            break
    assert len(chosen) == 4, chosen
    assert len({bank_of(o) for o in chosen}) == 4

    # Burst push without waiting — banks should absorb in parallel
    for i, oid in enumerate(chosen):
        r = await push_cmd(
            dut,
            op=OP_ADD,
            oid=oid,
            code=CODE,
            side=SIDE_BID,
            px=200 + i,
            qty=1 + i,
            seq=i + 1,
            expect_accept=True,
        )
        assert r == 1

    await wait_done(dut, 4, timeout_cycles=8000)
    assert int(dut.err_cnt.value) == 0
    assert int(dut.push_cnt.value) == 4
    assert int(dut.drop_cnt.value) == 0
    # Parallel banks ⇒ DDR traffic for 4 cmds
    assert int(dut.ddr_rd_cnt.value) >= 8  # order+level per cmd
    assert int(dut.high_watermark.value) >= 1
