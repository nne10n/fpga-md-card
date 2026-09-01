#!/usr/bin/env python3
"""cocotb tests for dec_sse_fast (M9) — synthetic FAST template.

Wire layout (network/big-endian; AXIS byte0 = tdata[7:0]):
  [0]     PMap / msg_type (1B)
  [1..6]  code ASCII (6B)
  [7..10] seq u32
  [11..18] px u64  (design said u32; u64 to match event_t.px / Binary TB)
  [19..22] qty u32
MIN_LEN=23. ch=CH_SNAP, exch=EXCH_SSE.
"""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from axis_bfm import axis_send_frame
from event_util import (
    CH_SNAP,
    EXCH_SSE,
    pack_event_t,
    unpack_event_t,
)

MIN_LEN = 23


def pack_pay_tuser(
    port_id: int = 0,
    sop_ts: int = 0,
    udp_dport: int = 0x1F40,
    l4_prot: int = 17,
    from_tcp: int = 0,
) -> int:
    return (
        ((port_id & 0x7) << 89)
        | ((sop_ts & ((1 << 64) - 1)) << 25)
        | ((udp_dport & 0xFFFF) << 9)
        | ((l4_prot & 0xFF) << 1)
        | (from_tcp & 0x1)
    )


def build_synth_fast(
    pmap: int,
    code: str,
    seq: int,
    px: int,
    qty: int,
) -> bytes:
    """Synthetic FAST template message (network byte order)."""
    code_b = code.encode("ascii")[:6].ljust(6, b" ")
    return (
        struct.pack("!B", pmap & 0xFF)
        + code_b
        + struct.pack("!I", seq & 0xFFFFFFFF)
        + struct.pack("!Q", px & ((1 << 64) - 1))
        + struct.pack("!I", qty & 0xFFFFFFFF)
    )


def code_from_ascii6(s: str) -> int:
    v = 0
    for i, ch in enumerate(s.encode("ascii")[:6].ljust(6, b" ")):
        v |= ch << (8 * i)
    return v


async def reset_dec(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_event_tready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dec(dut)
    await RisingEdge(dut.clk)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


async def recv_event(dut, timeout_cycles: int = 500) -> tuple[int, int]:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1 and int(dut.m_event_tready.value) == 1:
            return int(dut.m_event_tdata.value), int(dut.m_event_tlast.value)
    raise TimeoutError("no event received")


async def expect_no_event(dut, cycles: int = 40) -> bool:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1:
            return False
    return True


@cocotb.test()
async def test_fast_happy_path(dut):
    """PMap+code+seq+px+qty → event fields + m_code match; ch=CH_SNAP."""
    await _init(dut)
    pmap = 0xA5
    seq = 0x11223344
    px = 0x0102030405060708
    qty = 0xAABBCCDD
    ts = 0xDEADBEEFCAFEBABE
    code = "600000"
    payload = build_synth_fast(pmap, code, seq, px, qty)
    assert len(payload) == MIN_LEN

    ok0 = _ctr(dut, "msg_ok")
    bad0 = _ctr(dut, "msg_bad")
    tuser = pack_pay_tuser(port_id=0, sop_ts=ts)

    send = cocotb.start_soon(axis_send_frame(dut, payload, tuser=tuser))
    await Timer(1, unit="ns")
    raw, tlast = await recv_event(dut, timeout_cycles=200)
    await send

    assert tlast == 1
    ev = unpack_event_t(raw)
    exp = pack_event_t(
        ts_ns=ts,
        seq=seq,
        symbol_id=0,
        exch=EXCH_SSE,
        ch=CH_SNAP,
        msg_type=pmap & 0xFF,
        flags=0,
        px=px,
        qty=qty,
        side=0,
        order_id=0,
    )
    assert raw == exp, f"packed mismatch\n got={raw:#x}\n exp={exp:#x}\n fields={ev}"
    assert ev["ch"] == CH_SNAP, ev
    assert ev["exch"] == EXCH_SSE, ev
    assert ev["seq"] == seq, ev
    assert ev["px"] == px, ev
    assert ev["qty"] == qty, ev
    assert ev["msg_type"] == (pmap & 0xFF), ev
    assert ev["ts_ns"] == ts, ev
    assert ev["symbol_id"] == 0, ev
    assert ev["flags"] == 0, ev
    assert ev["side"] == 0, ev
    assert ev["order_id"] == 0, ev
    assert int(dut.m_code.value) == code_from_ascii6(code), hex(int(dut.m_code.value))
    await RisingEdge(dut.clk)
    assert _ctr(dut, "msg_ok") == ok0 + 1
    assert _ctr(dut, "msg_bad") == bad0


@cocotb.test()
async def test_fast_short_bad(dut):
    """Frame shorter than MIN_LEN → no event, msg_bad++."""
    await _init(dut)
    short = build_synth_fast(1, "000001", 1, 100, 10)[:10]
    assert len(short) < MIN_LEN

    ok0 = _ctr(dut, "msg_ok")
    bad0 = _ctr(dut, "msg_bad")
    await axis_send_frame(dut, short, tuser=pack_pay_tuser(sop_ts=1))
    await RisingEdge(dut.clk)
    idle = await expect_no_event(dut, 40)
    assert idle, "unexpected event on short frame"
    assert _ctr(dut, "msg_ok") == ok0
    assert _ctr(dut, "msg_bad") == bad0 + 1


@cocotb.test()
async def test_fast_garbage_partial_keep(dut):
    """Garbage 5-byte single-beat → msg_bad++."""
    await _init(dut)
    garbage = bytes([0xFF, 0x00, 0x11, 0x22, 0x33])
    ok0 = _ctr(dut, "msg_ok")
    bad0 = _ctr(dut, "msg_bad")
    await axis_send_frame(dut, garbage, tuser=pack_pay_tuser(sop_ts=2))
    await RisingEdge(dut.clk)
    idle = await expect_no_event(dut, 40)
    assert idle, "unexpected event on garbage"
    assert _ctr(dut, "msg_ok") == ok0
    assert _ctr(dut, "msg_bad") == bad0 + 1
