#!/usr/bin/env python3
"""cocotb unit tests for book_engine (L0 hot Top-10 + L1 stub)."""

from __future__ import annotations

import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tb"))
from event_util import (  # noqa: E402
    CH_ORDER,
    CH_SNAP,
    CH_TRADE,
    EXCH_SZSE,
    pack_event_t,
    unpack_event_t,
)

MSG_ADD = 2
MSG_CXL = 4
SIDE_BID = 1
SIDE_ASK = 2
CODE_HOT = int.from_bytes(b"000001", "little")
CODE_COLD = int.from_bytes(b"999999", "little")


async def reset(dut, n=5):
    dut.rst_n.value = 0
    dut.s_event_tdata.value = 0
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 1
    dut.s_code.value = 0
    dut.m_bypass_tready.value = 1
    dut.m_delta_ready.value = 1
    dut.hot_we.value = 0
    dut.hot_addr.value = 0
    dut.hot_code.value = 0
    dut.hot_entry_valid.value = 0
    dut.book_clear.value = 0
    dut.dbg_hot_id.value = 1
    dut.dbg_side.value = SIDE_BID
    for _ in range(n):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


async def hot_load(dut, addr: int, code: int, valid: int = 1):
    dut.hot_addr.value = addr & 0x3F
    dut.hot_code.value = code & ((1 << 48) - 1)
    dut.hot_entry_valid.value = valid & 1
    dut.hot_we.value = 1
    await RisingEdge(dut.clk)
    dut.hot_we.value = 0
    await RisingEdge(dut.clk)


async def drive_event(dut, ev: int, code: int, hold_bypass: bool = False):
    """Drive one event beat. Returns (ready_ok, bypass_raw_or_None)."""
    if hold_bypass:
        dut.m_bypass_tready.value = 0
    dut.s_event_tdata.value = ev
    dut.s_code.value = code
    dut.s_event_tvalid.value = 1
    dut.s_event_tlast.value = 1
    await RisingEdge(dut.clk)
    ready_ok = int(dut.s_event_tready.value) == 1
    dut.s_event_tvalid.value = 0
    # bypass register updates on this edge; sample next cycle while held or briefly
    await RisingEdge(dut.clk)
    byp = None
    if int(dut.m_bypass_tvalid.value) == 1:
        byp = int(dut.m_bypass_tdata.value)
    if hold_bypass:
        dut.m_bypass_tready.value = 1
        await RisingEdge(dut.clk)
    return ready_ok, byp


def make_order(*, seq, oid, px, qty, side=SIDE_BID, msg=MSG_ADD, ch=CH_ORDER, ts=1):
    return pack_event_t(
        ts_ns=ts,
        seq=seq,
        symbol_id=0,
        exch=EXCH_SZSE,
        ch=ch,
        msg_type=msg,
        flags=0,
        px=px,
        qty=qty,
        side=side,
        order_id=oid,
    )


async def settle(dut, n=4):
    for _ in range(n):
        await RisingEdge(dut.clk)


async def read_top_qty(dut, level=0) -> tuple[int, int, int]:
    sig = getattr(dut, f"dbg_lvl{level}")
    try:
        return int(sig.valid.value), int(sig.px.value), int(sig.qty.value)
    except Exception:
        v = int(sig.value)
        return (v >> 96) & 1, (v >> 32) & ((1 << 64) - 1), v & 0xFFFFFFFF


@cocotb.test()
async def test_hot_add_accum_cxl_trade(dut):
    """Hot Add same px accumulates; Cancel falls back; Trade-to-0 frees slot."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await hot_load(dut, 0, CODE_HOT)

    ok, _ = await drive_event(dut, make_order(seq=1, oid=1, px=100, qty=10), CODE_HOT)
    assert ok
    await settle(dut)
    v, px, qty = await read_top_qty(dut, 0)
    assert v == 1 and px == 100 and qty == 10, (v, px, qty)
    assert int(dut.l1_push_cnt.value) >= 1
    assert int(dut.delta_cnt.value) >= 1
    assert int(dut.hot_hit_cnt.value) >= 1

    ok, _ = await drive_event(dut, make_order(seq=2, oid=2, px=100, qty=5), CODE_HOT)
    assert ok
    await settle(dut)
    v, px, qty = await read_top_qty(dut, 0)
    assert v == 1 and px == 100 and qty == 15, (v, px, qty)

    ok, _ = await drive_event(
        dut, make_order(seq=3, oid=1, px=100, qty=10, msg=MSG_CXL), CODE_HOT
    )
    assert ok
    await settle(dut)
    v, px, qty = await read_top_qty(dut, 0)
    assert v == 1 and px == 100 and qty == 5, (v, px, qty)

    ok, _ = await drive_event(
        dut, make_order(seq=4, oid=2, px=100, qty=5, ch=CH_TRADE, msg=3), CODE_HOT
    )
    assert ok
    await settle(dut)
    v, px, qty = await read_top_qty(dut, 0)
    assert v == 0, (v, px, qty)


@cocotb.test()
async def test_nonhot_bypass_l1_no_delta(dut):
    """Non-hot: no L0 delta; bypass has event; L1 stub count increments."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await hot_load(dut, 0, CODE_HOT)

    before_l1 = int(dut.l1_push_cnt.value)
    before_d = int(dut.delta_cnt.value)

    ev = make_order(seq=9, oid=99, px=50, qty=1)
    ok, byp = await drive_event(dut, ev, CODE_COLD, hold_bypass=True)
    assert ok
    assert byp is not None, "missing bypass event"
    u = unpack_event_t(byp)
    assert u["order_id"] == 99
    assert u["seq"] == 9

    await settle(dut, 5)
    assert int(dut.delta_cnt.value) == before_d
    assert int(dut.l1_push_cnt.value) == before_l1 + 1
    assert int(dut.hot_miss_cnt.value) >= 1


@cocotb.test()
async def test_upstream_never_backpressure(dut):
    """s_event_tready stays 1 across a burst."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await hot_load(dut, 0, CODE_HOT)
    dut.m_bypass_tready.value = 0
    dut.m_delta_ready.value = 0

    for i in range(8):
        dut.s_event_tdata.value = make_order(seq=i + 1, oid=i + 1, px=10 + i, qty=1)
        dut.s_code.value = CODE_HOT
        dut.s_event_tvalid.value = 1
        await RisingEdge(dut.clk)
        assert int(dut.s_event_tready.value) == 1
    dut.s_event_tvalid.value = 0
    dut.m_bypass_tready.value = 1
    dut.m_delta_ready.value = 1


@cocotb.test()
async def test_no_forge_11th_level(dut):
    """Worse px beyond Top-10 must not appear in view."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await hot_load(dut, 0, CODE_HOT)

    for i in range(10):
        px = 100 - i
        ok, _ = await drive_event(
            dut, make_order(seq=i + 1, oid=i + 1, px=px, qty=1), CODE_HOT
        )
        assert ok
    await settle(dut)

    ok, _ = await drive_event(dut, make_order(seq=20, oid=20, px=80, qty=7), CODE_HOT)
    assert ok
    await settle(dut)

    seen_px = set()
    for lvl in range(10):
        v, px, qty = await read_top_qty(dut, lvl)
        if v:
            seen_px.add(px)
    assert 80 not in seen_px, f"forged 11th level: {seen_px}"
    assert seen_px == set(range(91, 101)), seen_px

    ok, _ = await drive_event(dut, make_order(seq=21, oid=21, px=105, qty=3), CODE_HOT)
    assert ok
    await settle(dut)
    seen_px = set()
    for lvl in range(10):
        v, px, qty = await read_top_qty(dut, lvl)
        if v:
            seen_px.add(px)
    assert 105 in seen_px
    assert 91 not in seen_px
    assert 80 not in seen_px


@cocotb.test()
async def test_snap_bypass_no_l1(dut):
    """SNAP/other: bypass only, L1 not pushed."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await hot_load(dut, 0, CODE_HOT)
    before = int(dut.l1_push_cnt.value)
    ev = pack_event_t(
        ts_ns=1, seq=1, exch=EXCH_SZSE, ch=CH_SNAP, msg_type=1, px=1, qty=1
    )
    ok, _ = await drive_event(dut, ev, CODE_HOT)
    assert ok
    await settle(dut)
    assert int(dut.l1_push_cnt.value) == before
