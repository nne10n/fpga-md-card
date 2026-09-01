#!/usr/bin/env python3
"""cocotb tests for dma_pack (M6)."""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from event_util import (
    CH_ORDER,
    EXCH_SZSE,
    pack_event_t,
    unpack_event_t,
)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


def beats_to_event(beats: list[int]) -> int:
    """8×64b LE beats → 512-bit event_t (beat0 = event[63:0])."""
    assert len(beats) == 8
    v = 0
    for i, w in enumerate(beats):
        v |= (w & ((1 << 64) - 1)) << (64 * i)
    return v


def event_to_beats(ev: int) -> list[int]:
    return [(ev >> (64 * i)) & ((1 << 64) - 1) for i in range(8)]


async def reset_dut(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.s_event_tdata.value = 0
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0
    dut.m_axis_tready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_event(dut, data: int, probe_tready=None):
    """Drive one event beat; optionally record s_event_tready."""
    dut.s_event_tdata.value = data
    dut.s_event_tvalid.value = 1
    dut.s_event_tlast.value = 1
    await RisingEdge(dut.clk)
    if probe_tready is not None:
        probe_tready.append(int(dut.s_event_tready.value))
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0


async def recv_event_frame(dut, timeout_cycles: int = 200) -> list[int]:
    """Collect 8 beats until tlast; return list of 64b words."""
    beats: list[int] = []
    cycles = 0
    while cycles < timeout_cycles:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
            data = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            last = int(dut.m_axis_tlast.value)
            assert keep == 0xFF, f"tkeep={keep:#x}"
            beats.append(data)
            if last:
                assert len(beats) == 8, f"tlast after {len(beats)} beats"
                return beats
    raise TimeoutError(f"frame RX timeout, got {len(beats)} beats")


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)


def _make_ev(seq: int = 1, symbol_id: int = 5, ts_ns: int | None = None) -> int:
    if ts_ns is None:
        ts_ns = 0x0123456789ABCDEF ^ (seq << 8)
    return pack_event_t(
        ts_ns=ts_ns,
        seq=seq,
        symbol_id=symbol_id,
        exch=EXCH_SZSE,
        ch=CH_ORDER,
        msg_type=0x42,
        flags=0x07,
        px=0x1111222233334444 + seq,
        qty=1000 + seq,
        side=1,
        order_id=0xAABBCCDDEEFF0000 + seq,
        level=2,
        queue_pos=3,
        raw_ptr=0x55AA,
    )


@cocotb.test()
async def test_one_event_eight_beats(dut):
    """One event → 8 beats; unpack matches; tlast on beat7."""
    await _init(dut)
    ev = _make_ev(seq=7)
    ok0 = _ctr(dut, "tx_ok")

    send = cocotb.start_soon(send_event(dut, ev))
    beats = await recv_event_frame(dut, timeout_cycles=40)
    await send

    got = beats_to_event(beats)
    assert got == ev, (
        f"unpack mismatch\n got={unpack_event_t(got)}\n exp={unpack_event_t(ev)}"
    )
    assert beats == event_to_beats(ev)
    # beat0 must be ts_ns
    assert beats[0] == (ev & ((1 << 64) - 1))
    await RisingEdge(dut.clk)  # allow tx_ok NBA from last-beat handshake
    assert _ctr(dut, "tx_ok") == ok0 + 1
    assert _ctr(dut, "drop_full") == 0


@cocotb.test()
async def test_back_to_back_three(dut):
    """Back-to-back 3 events → 3 frames, order preserved."""
    await _init(dut)
    evs = [_make_ev(seq=i + 1) for i in range(3)]
    ok0 = _ctr(dut, "tx_ok")

    async def send_all():
        for e in evs:
            await send_event(dut, e)

    send = cocotb.start_soon(send_all())
    got_list = []
    for _ in range(3):
        beats = await recv_event_frame(dut, timeout_cycles=80)
        got_list.append(beats_to_event(beats))
    await send

    assert got_list == evs
    await RisingEdge(dut.clk)
    assert _ctr(dut, "tx_ok") == ok0 + 3
    assert _ctr(dut, "drop_full") == 0


@cocotb.test()
async def test_fifo_fill_drop(dut):
    """Hold m_axis_tready=0, send 33 → drop_full>=1; release and drain stored."""
    await _init(dut)
    dut.m_axis_tready.value = 0

    evs = [_make_ev(seq=i + 1) for i in range(33)]
    d0 = _ctr(dut, "drop_full")
    probes: list[int] = []

    for e in evs:
        await send_event(dut, e, probe_tready=probes)

    # A few idle cycles while still paused
    for _ in range(5):
        await RisingEdge(dut.clk)

    drops = _ctr(dut, "drop_full") - d0
    assert drops >= 1, f"expected drop_full>=1, got {drops}"
    assert all(p == 1 for p in probes), f"tready not always 1: {probes}"

    # Release and collect whatever was stored (capacity 32)
    dut.m_axis_tready.value = 1
    stored: list[int] = []
    # Up to 32 frames; stop when idle for a while
    idle = 0
    while len(stored) < 32 and idle < 20:
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
            # Start of a frame — gather remaining beats including this one
            beats = [int(dut.m_axis_tdata.value)]
            assert int(dut.m_axis_tkeep.value) == 0xFF
            last = int(dut.m_axis_tlast.value)
            while not last:
                await RisingEdge(dut.clk)
                if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
                    beats.append(int(dut.m_axis_tdata.value))
                    last = int(dut.m_axis_tlast.value)
            assert len(beats) == 8
            stored.append(beats_to_event(beats))
            idle = 0
        else:
            idle += 1

    assert len(stored) == 32, f"expected 32 stored frames, got {len(stored)}"
    assert stored == evs[:32], "stored events should be the first 32"
    assert drops == 1, f"exactly one drop expected for 33 into depth-32, got {drops}"
    await RisingEdge(dut.clk)
    assert _ctr(dut, "tx_ok") == 32


@cocotb.test()
async def test_tready_always_one_flood(dut):
    """s_event_tready stays 1 during flood with downstream pause."""
    await _init(dut)
    dut.m_axis_tready.value = 0
    probes: list[int] = []

    for i in range(40):
        await send_event(dut, _make_ev(seq=i + 1), probe_tready=probes)

    assert len(probes) == 40
    assert all(p == 1 for p in probes), f"s_event_tready dipped: {probes}"
    assert int(dut.s_event_tready.value) == 1

    # Drain so sim ends cleanly
    dut.m_axis_tready.value = 1
    for _ in range(32 * 8 + 40):
        await RisingEdge(dut.clk)
