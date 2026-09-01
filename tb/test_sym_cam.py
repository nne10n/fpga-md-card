#!/usr/bin/env python3
"""cocotb tests for sym_cam (M4)."""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from event_util import (
    CH_ORDER,
    EXCH_SSE,
    EXCH_SZSE,
    F_CAM_MISS,
    pack_event_t,
    unpack_event_t,
)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


def make_key(exch: int, code48: int) -> int:
    """key = {exch[1:0], code_ascii[47:0]}"""
    return ((exch & 3) << 48) | (code48 & ((1 << 48) - 1))


def hash13(key: int) -> int:
    return (key & 0x1FFF) ^ ((key >> 13) & 0x1FFF) ^ ((key >> 26) & 0x1FFF)


def code_from_ascii6(s: str) -> int:
    """Pack up to 6 chars into 48-bit little-endian-ish code (char0 in [7:0])."""
    assert len(s) <= 6
    v = 0
    for i, ch in enumerate(s.encode("ascii")):
        v |= ch << (8 * i)
    return v


async def reset_cam(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.s_event_tdata.value = 0
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0
    dut.s_code.value = 0
    dut.m_event_tready.value = 1
    dut.cfg_pass_miss.value = 0
    dut.swap.value = 0
    dut.cam_we.value = 0
    dut.cam_addr.value = 0
    dut.cam_key.value = 0
    dut.cam_id.value = 0
    dut.cam_entry_valid.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    # Large mem clear on reset — give it a few cycles after release
    for _ in range(3):
        await RisingEdge(dut.clk)


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_cam(dut)


async def cam_write(dut, addr: int, key: int, sym_id: int, valid: int = 1):
    """Write one entry into the inactive bank."""
    dut.cam_addr.value = addr & 0x1FFF
    dut.cam_key.value = key & ((1 << 56) - 1)
    dut.cam_id.value = sym_id & 0xFFFF
    dut.cam_entry_valid.value = valid & 1
    dut.cam_we.value = 1
    await RisingEdge(dut.clk)
    dut.cam_we.value = 0


async def cam_swap(dut):
    """Pulse swap; wait through the 1-cycle switch."""
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    # switch happens on the following edge while old bank still used this cycle
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def send_event(dut, data: int, code48: int):
    """Drive one event + s_code sideband; tready is always 1."""
    dut.s_event_tdata.value = data
    dut.s_code.value = code48 & ((1 << 48) - 1)
    dut.s_event_tvalid.value = 1
    dut.s_event_tlast.value = 1
    await RisingEdge(dut.clk)
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0
    dut.s_code.value = 0


async def recv_event(dut, timeout_cycles: int = 80) -> int:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1 and int(dut.m_event_tready.value) == 1:
            return int(dut.m_event_tdata.value)
    raise TimeoutError("no event")


async def expect_no_event(dut, cycles: int = 30) -> bool:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1:
            return False
    return True


def _make_ev(exch: int = EXCH_SZSE, seq: int = 1, flags: int = 0, sym: int = 0) -> int:
    return pack_event_t(
        ts_ns=0xABC,
        seq=seq,
        symbol_id=sym,
        exch=exch,
        ch=CH_ORDER,
        msg_type=2,
        flags=flags,
        px=100,
        qty=10,
        side=1,
    )


async def insert_and_activate(dut, exch: int, code48: int, sym_id: int, addr: int | None = None):
    """Write key at hash (or given addr) into inactive bank and swap in."""
    key = make_key(exch, code48)
    if addr is None:
        addr = hash13(key)
    await cam_write(dut, addr, key, sym_id, valid=1)
    await cam_swap(dut)
    return key, addr


@cocotb.test()
async def test_hit_fills_symbol_id(dut):
    """Insert key via write+swap; matching s_code → hit, symbol_id correct."""
    await _init(dut)
    exch = EXCH_SZSE
    code = code_from_ascii6("000001")
    sym = 0x1234

    hit0, miss0, drop0 = _ctr(dut, "hit"), _ctr(dut, "miss"), _ctr(dut, "drop_miss")
    await insert_and_activate(dut, exch, code, sym)

    ev = _make_ev(exch=exch, seq=7, flags=F_CAM_MISS, sym=0xFFFF)
    await send_event(dut, ev, code)
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["symbol_id"] == sym, e
    assert e["seq"] == 7, e
    assert (e["flags"] & F_CAM_MISS) == 0, e
    assert _ctr(dut, "hit") == hit0 + 1
    assert _ctr(dut, "miss") == miss0
    assert _ctr(dut, "drop_miss") == drop0


@cocotb.test()
async def test_miss_drop(dut):
    """Unknown code → drop when cfg_pass_miss=0."""
    await _init(dut)
    dut.cfg_pass_miss.value = 0

    # Activate an unrelated entry so bank is live
    await insert_and_activate(dut, EXCH_SZSE, code_from_ascii6("999999"), 1)

    hit0, miss0, drop0 = _ctr(dut, "hit"), _ctr(dut, "miss"), _ctr(dut, "drop_miss")
    ev = _make_ev(exch=EXCH_SZSE, seq=3)
    await send_event(dut, ev, code_from_ascii6("000002"))
    idle = await expect_no_event(dut, 40)
    assert idle, "miss must drop when cfg_pass_miss=0"
    assert _ctr(dut, "hit") == hit0
    assert _ctr(dut, "miss") == miss0 + 1
    assert _ctr(dut, "drop_miss") == drop0 + 1


@cocotb.test()
async def test_miss_pass(dut):
    """cfg_pass_miss=1 → forward symbol_id=0 with F_CAM_MISS."""
    await _init(dut)
    dut.cfg_pass_miss.value = 1
    await insert_and_activate(dut, EXCH_SSE, code_from_ascii6("600000"), 99)

    hit0, miss0, drop0 = _ctr(dut, "hit"), _ctr(dut, "miss"), _ctr(dut, "drop_miss")
    ev = _make_ev(exch=EXCH_SSE, seq=5, flags=0, sym=0xBEEF)
    await send_event(dut, ev, code_from_ascii6("600001"))
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["symbol_id"] == 0, e
    assert (e["flags"] & F_CAM_MISS) == F_CAM_MISS, e
    assert e["seq"] == 5, e
    assert _ctr(dut, "hit") == hit0
    assert _ctr(dut, "miss") == miss0 + 1
    assert _ctr(dut, "drop_miss") == drop0


@cocotb.test()
async def test_dual_bank_swap(dut):
    """Write inactive mapping; before swap still old; after swap new."""
    await _init(dut)
    exch = EXCH_SZSE
    code = code_from_ascii6("000010")
    key = make_key(exch, code)
    addr = hash13(key)

    # Bank0 active after reset; write old id into inactive (bank1), swap → active
    await cam_write(dut, addr, key, 0x1111, valid=1)
    await cam_swap(dut)
    assert int(dut.bank_sel.value) == 1

    ev = _make_ev(exch=exch, seq=1)
    await send_event(dut, ev, code)
    e = unpack_event_t(await recv_event(dut))
    assert e["symbol_id"] == 0x1111, e

    # Write new id into inactive (bank0); before swap still old
    await cam_write(dut, addr, key, 0x2222, valid=1)
    await send_event(dut, _make_ev(exch=exch, seq=2), code)
    e = unpack_event_t(await recv_event(dut))
    assert e["symbol_id"] == 0x1111, f"pre-swap must stay old, got {e}"

    await cam_swap(dut)
    assert int(dut.bank_sel.value) == 0
    await send_event(dut, _make_ev(exch=exch, seq=3), code)
    e = unpack_event_t(await recv_event(dut))
    assert e["symbol_id"] == 0x2222, e


@cocotb.test()
async def test_collision_probe(dut):
    """Two keys with same hash resolved by open-address probe."""
    await _init(dut)
    exch = EXCH_SZSE
    # code_a: all-zero → hash 0
    code_a = 0
    # code_b: [12:0]=1, [25:13]=1 → 1^1^0 = 0
    code_b = (1 << 0) | (1 << 13)
    key_a = make_key(exch, code_a)
    key_b = make_key(exch, code_b)
    h = hash13(key_a)
    assert hash13(key_b) == h
    assert key_a != key_b

    # Place A at base, B at base+1 (host open-address insert)
    await cam_write(dut, h, key_a, 0xA001, valid=1)
    await cam_write(dut, (h + 1) & 0x1FFF, key_b, 0xB002, valid=1)
    await cam_swap(dut)

    await send_event(dut, _make_ev(exch=exch, seq=10), code_a)
    e = unpack_event_t(await recv_event(dut))
    assert e["symbol_id"] == 0xA001, e

    await send_event(dut, _make_ev(exch=exch, seq=11), code_b)
    e = unpack_event_t(await recv_event(dut))
    assert e["symbol_id"] == 0xB002, e
