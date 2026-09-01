#!/usr/bin/env python3
"""cocotb tests for dec_szse_bin / dec_bin_generic (M2).

Synthetic Binary layout (§6 module-design-v1.md) — NOT exchange PDF offsets.
event_t packing mirrors md_pkg.sv (pad at MSBs).
"""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from axis_bfm import axis_send_frame
from event_util import (
    CH_ORDER,
    CH_OTHER,
    CH_SNAP,
    CH_TRADE,
    EXCH_SZSE,
    pack_event_t,
    unpack_event_t,
)

# Default SZSE TB offsets
OFF_TYPE = 0
OFF_SEQ = 4
OFF_CODE = 8
OFF_PX = 14
OFF_QTY = 22
OFF_SIDE = 26
OFF_OID = 27
OFF_CH_HINT = 35
LEN_HDR = 36


def default_type_lut() -> int:
    """16 x 4-bit: 1→SNAP, 2→ORDER, 3→TRADE, else CH_OTHER."""
    lut = 0
    for i in range(16):
        if i == 1:
            ch = CH_SNAP
        elif i == 2:
            ch = CH_ORDER
        elif i == 3:
            ch = CH_TRADE
        else:
            ch = CH_OTHER
        lut |= (ch & 0xF) << (i * 4)
    return lut


def pack_pay_tuser(
    port_id: int = 2,
    sop_ts: int = 0,
    udp_dport: int = 0x1F40,
    l4_prot: int = 17,
    from_tcp: int = 0,
) -> int:
    """pay_tuser_t: {port_id[2:0], sop_ts[63:0], udp_dport[15:0], l4_prot[7:0], from_tcp}."""
    return (
        ((port_id & 0x7) << 89)
        | ((sop_ts & ((1 << 64) - 1)) << 25)
        | ((udp_dport & 0xFFFF) << 9)
        | ((l4_prot & 0xFF) << 1)
        | (from_tcp & 0x1)
    )




def build_synth_bin(
    msg_type: int,
    seq: int,
    code: str,
    px: int,
    qty: int,
    side: int,
    order_id: int,
    ch_hint: int | None = None,
) -> bytes:
    """§6 synthetic Binary message (network byte order)."""
    code_b = code.encode("ascii")[:6].ljust(6, b" ")
    if ch_hint is None:
        if msg_type == 1:
            ch_hint = CH_SNAP
        elif msg_type == 2:
            ch_hint = CH_ORDER
        elif msg_type == 3:
            ch_hint = CH_TRADE
        else:
            ch_hint = CH_OTHER
    # body after 4-byte header (type + body_len)
    body = (
        struct.pack("!I", seq)
        + code_b
        + struct.pack("!Q", px)
        + struct.pack("!I", qty)
        + struct.pack("!B", side)
        + struct.pack("!Q", order_id)
        + struct.pack("!B", ch_hint)
    )
    body_len = len(body)  # documented; DUT ignores for extraction
    return struct.pack("!HH", msg_type & 0xFFFF, body_len & 0xFFFF) + body


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
    dut.cfg_off_type.value = OFF_TYPE
    dut.cfg_off_seq.value = OFF_SEQ
    dut.cfg_off_code.value = OFF_CODE
    dut.cfg_off_px.value = OFF_PX
    dut.cfg_off_qty.value = OFF_QTY
    dut.cfg_off_side.value = OFF_SIDE
    dut.cfg_off_oid.value = OFF_OID
    dut.cfg_len_hdr.value = LEN_HDR
    dut.cfg_type_lut.value = default_type_lut()
    dut.cfg_off_ch_hint.value = OFF_CH_HINT
    await reset_dec(dut)
    await RisingEdge(dut.clk)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


async def recv_event(dut, timeout_cycles: int = 500) -> tuple[int, int]:
    """Wait for one event beat. Returns (tdata_int, tlast)."""
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


async def _check_msg(dut, msg_type: int, expect_ch: int):
    seq = 0xA1B2C3D4
    px = 123456789  # already 1e-4 yuan
    qty = 1000
    side = 1  # buy
    oid = 0x1122334455667788
    ts = 0xAAAABBBBCCCCDDDD
    payload = build_synth_bin(msg_type, seq, "000001", px, qty, side, oid)
    assert len(payload) >= LEN_HDR

    ok0 = _ctr(dut, "msg_ok")
    bad0 = _ctr(dut, "msg_bad")
    tuser = pack_pay_tuser(port_id=2, sop_ts=ts)

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
        exch=EXCH_SZSE,
        ch=expect_ch,
        msg_type=msg_type & 0xFF,
        flags=0,
        px=px,
        qty=qty,
        side=side & 0x3,
        order_id=oid,
    )
    assert raw == exp, f"packed mismatch\n got={raw:#x}\n exp={exp:#x}\n fields={ev}"
    assert ev["ch"] == expect_ch, ev
    assert ev["exch"] == EXCH_SZSE, ev
    assert ev["seq"] == seq, ev
    assert ev["px"] == px, ev
    assert ev["qty"] == qty, ev
    assert ev["side"] == (side & 3), ev
    assert ev["order_id"] == oid, ev
    assert ev["ts_ns"] == ts, ev
    assert ev["msg_type"] == (msg_type & 0xFF), ev
    assert ev["symbol_id"] == 0, ev
    assert ev["flags"] == 0, ev
    # msg_ok increments on the emit cycle via NBA → visible next edge
    await RisingEdge(dut.clk)
    assert _ctr(dut, "msg_ok") == ok0 + 1
    assert _ctr(dut, "msg_bad") == bad0


@cocotb.test()
async def test_order_msg(dut):
    """ORDER msg_type=2 → CH_ORDER, fields match, exch=SZSE."""
    await _init(dut)
    await _check_msg(dut, msg_type=2, expect_ch=CH_ORDER)


@cocotb.test()
async def test_trade_msg(dut):
    """TRADE msg_type=3 → CH_TRADE."""
    await _init(dut)
    await _check_msg(dut, msg_type=3, expect_ch=CH_TRADE)


@cocotb.test()
async def test_snap_msg(dut):
    """SNAP msg_type=1 → CH_SNAP."""
    await _init(dut)
    await _check_msg(dut, msg_type=1, expect_ch=CH_SNAP)


@cocotb.test()
async def test_short_frame_bad(dut):
    """Frame shorter than cfg_len_hdr → no event, msg_bad++."""
    await _init(dut)
    short = build_synth_bin(2, 1, "000001", 100, 10, 1, 99)[:20]
    assert len(short) < LEN_HDR

    ok0 = _ctr(dut, "msg_ok")
    bad0 = _ctr(dut, "msg_bad")
    await axis_send_frame(dut, short, tuser=pack_pay_tuser(sop_ts=1))
    await RisingEdge(dut.clk)  # allow msg_bad NBA
    idle = await expect_no_event(dut, 40)
    assert idle, "unexpected event on short frame"
    assert _ctr(dut, "msg_ok") == ok0
    assert _ctr(dut, "msg_bad") == bad0 + 1


@cocotb.test()
async def test_two_back_to_back(dut):
    """Two messages back-to-back → two events in order."""
    await _init(dut)
    ts1 = 0x1000
    ts2 = 0x2000
    m1 = build_synth_bin(2, 10, "000001", 111, 5, 1, 0xAAAA)
    m2 = build_synth_bin(3, 11, "000002", 222, 6, 2, 0xBBBB)

    ok0 = _ctr(dut, "msg_ok")
    send1 = cocotb.start_soon(
        axis_send_frame(dut, m1, tuser=pack_pay_tuser(sop_ts=ts1))
    )
    await Timer(1, unit="ns")
    # Wait until first message is fully sent, then send second
    await send1
    send2 = cocotb.start_soon(
        axis_send_frame(dut, m2, tuser=pack_pay_tuser(sop_ts=ts2))
    )

    raw1, _ = await recv_event(dut, timeout_cycles=200)
    raw2, _ = await recv_event(dut, timeout_cycles=200)
    await send2

    e1 = unpack_event_t(raw1)
    e2 = unpack_event_t(raw2)
    assert e1["seq"] == 10 and e1["ch"] == CH_ORDER and e1["ts_ns"] == ts1, e1
    assert e2["seq"] == 11 and e2["ch"] == CH_TRADE and e2["ts_ns"] == ts2, e2
    assert e1["px"] == 111 and e2["px"] == 222
    await RisingEdge(dut.clk)
    assert _ctr(dut, "msg_ok") == ok0 + 2
