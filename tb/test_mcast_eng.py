#!/usr/bin/env python3
"""cocotb tests for mcast_eng (M5)."""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from event_util import (
    CH_ORDER,
    CH_SNAP,
    CH_TRADE,
    EXCH_SZSE,
    pack_event_t,
    unpack_event_t,
)

# Header template (same byte-order convention as udp_strip TB: big-endian ints)
DST_MAC = bytes.fromhex("01005e000001")
SRC_MAC = bytes.fromhex("001122334455")
DST_IP = bytes.fromhex("ef010101")  # 239.1.1.1
SRC_IP = bytes.fromhex("0a000001")  # 10.0.0.1
UDP_SPORT = 0xC000
UDP_DPORT = 0x1F40

CFG_DST_MAC = int.from_bytes(DST_MAC, "big")
CFG_SRC_MAC = int.from_bytes(SRC_MAC, "big")
CFG_DST_IP = int.from_bytes(DST_IP, "big")
CFG_SRC_IP = int.from_bytes(SRC_IP, "big")


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


def ipv4_checksum(hdr: bytes) -> int:
    assert len(hdr) == 20
    s = 0
    for i in range(0, 20, 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def payload_to_event(payload: bytes) -> int:
    """64 LE payload bytes → 512-bit event_t (byte0 = event[7:0])."""
    assert len(payload) == 64
    v = 0
    for i in range(8):
        word = int.from_bytes(payload[i * 8 : (i + 1) * 8], "little")
        v |= word << (64 * i)
    return v


def event_to_payload(ev: int) -> bytes:
    out = bytearray()
    for i in range(8):
        word = (ev >> (64 * i)) & ((1 << 64) - 1)
        out.extend(word.to_bytes(8, "little"))
    return bytes(out)


def parse_eth_udp(frame: bytes) -> dict:
    """Parse Ethernet/IPv4/UDP (no FCS). Returns header fields + payload."""
    assert len(frame) >= 42
    dst_mac = frame[0:6]
    src_mac = frame[6:12]
    ethertype = struct.unpack("!H", frame[12:14])[0]
    ip = frame[14:34]
    ver_ihl, tos, total_len, ip_id, frag, ttl, proto, csum, sip, dip = struct.unpack(
        "!BBHHHBBH4s4s", ip
    )
    udp = frame[34:42]
    sport, dport, ulen, ucsum = struct.unpack("!HHHH", udp)
    payload = frame[42:]
    return {
        "dst_mac": dst_mac,
        "src_mac": src_mac,
        "ethertype": ethertype,
        "ver_ihl": ver_ihl,
        "tos": tos,
        "total_len": total_len,
        "ip_id": ip_id,
        "frag": frag,
        "ttl": ttl,
        "proto": proto,
        "ip_csum": csum,
        "src_ip": sip,
        "dst_ip": dip,
        "sport": sport,
        "dport": dport,
        "ulen": ulen,
        "ucsum": ucsum,
        "payload": payload,
        "ip_hdr": ip,
    }


async def reset_dut(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.s_event_tdata.value = 0
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0
    dut.m_axis_tready.value = 1
    dut.filt_we.value = 0
    dut.filt_addr.value = 0
    dut.filt_bit.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    # Bitmap clear is large — a few extra cycles after release
    for _ in range(3):
        await RisingEdge(dut.clk)


async def apply_cfg(
    dut,
    *,
    ch_mask: int = 0xFF,
    period: int = 0,
    refill: int = 0,
):
    dut.cfg_src_mac.value = CFG_SRC_MAC
    dut.cfg_dst_mac.value = CFG_DST_MAC
    dut.cfg_src_ip.value = CFG_SRC_IP
    dut.cfg_dst_ip.value = CFG_DST_IP
    dut.cfg_udp_sport.value = UDP_SPORT
    dut.cfg_udp_dport.value = UDP_DPORT
    dut.cfg_ch_mask.value = ch_mask & 0xFF
    dut.cfg_period.value = period & 0xFFFF
    dut.cfg_refill.value = refill & 0xFFFF
    await RisingEdge(dut.clk)


async def filt_set(dut, symbol_id: int, enable: int = 1):
    dut.filt_addr.value = symbol_id & 0x1FFF
    dut.filt_bit.value = enable & 1
    dut.filt_we.value = 1
    await RisingEdge(dut.clk)
    dut.filt_we.value = 0
    await RisingEdge(dut.clk)


async def send_event(dut, data: int, probe_tready=None):
    """Drive one event beat; record tready if requested."""
    dut.s_event_tdata.value = data
    dut.s_event_tvalid.value = 1
    dut.s_event_tlast.value = 1
    await RisingEdge(dut.clk)
    if probe_tready is not None:
        probe_tready.append(int(dut.s_event_tready.value))
    dut.s_event_tvalid.value = 0
    dut.s_event_tlast.value = 0


async def recv_frame(dut, timeout_cycles: int = 200) -> bytes:
    buf = bytearray()
    cycles = 0
    got = False
    while cycles < timeout_cycles:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
            data = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            last = int(dut.m_axis_tlast.value)
            for b_i in range(8):
                if keep & (1 << b_i):
                    buf.append((data >> (8 * b_i)) & 0xFF)
            got = True
            if last:
                return bytes(buf)
    if not got:
        return b""
    raise TimeoutError(f"frame RX timeout after {len(buf)} bytes")


async def expect_idle(dut, cycles: int = 30) -> bool:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) == 1:
            return False
    return True


async def _init(dut, *, ch_mask: int = 0xFF, period: int = 0, refill: int = 0):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await apply_cfg(dut, ch_mask=ch_mask, period=period, refill=refill)
    await reset_dut(dut)
    # Re-apply cfg after reset (rst does not clear cfg inputs, but be explicit)
    await apply_cfg(dut, ch_mask=ch_mask, period=period, refill=refill)


def _make_ev(symbol_id: int = 5, ch: int = CH_ORDER, seq: int = 1) -> int:
    return pack_event_t(
        ts_ns=0x0123456789ABCDEF,
        seq=seq,
        symbol_id=symbol_id,
        exch=EXCH_SZSE,
        ch=ch,
        msg_type=0x42,
        flags=0x07,
        px=0x1111222233334444,
        qty=1000,
        side=1,
        order_id=0xAABBCCDDEEFF0011,
        level=2,
        queue_pos=3,
        raw_ptr=0x55AA,
    )


@cocotb.test()
async def test_tx_roundtrip(dut):
    """Enable symbol=5 + matching ch_mask → one UDP frame; payload == event_t."""
    await _init(dut, ch_mask=(1 << CH_ORDER), period=0)
    await filt_set(dut, 5, 1)

    ev = _make_ev(symbol_id=5, ch=CH_ORDER, seq=7)
    ok0 = _ctr(dut, "tx_ok")

    send = cocotb.start_soon(send_event(dut, ev))
    frame = await recv_frame(dut, timeout_cycles=80)
    await send

    assert len(frame) == 106, f"frame len {len(frame)}"
    parsed = parse_eth_udp(frame)
    assert parsed["dst_mac"] == DST_MAC
    assert parsed["src_mac"] == SRC_MAC
    assert parsed["ethertype"] == 0x0800
    assert parsed["ver_ihl"] == 0x45
    assert parsed["proto"] == 17
    assert parsed["total_len"] == 92
    assert parsed["src_ip"] == SRC_IP
    assert parsed["dst_ip"] == DST_IP
    assert parsed["sport"] == UDP_SPORT
    assert parsed["dport"] == UDP_DPORT
    assert parsed["ulen"] == 72
    assert parsed["ucsum"] == 0
    assert len(parsed["payload"]) == 64

    got = payload_to_event(parsed["payload"])
    assert got == ev, (
        f"payload mismatch\n"
        f" got={unpack_event_t(got)}\n"
        f" exp={unpack_event_t(ev)}"
    )
    assert _ctr(dut, "tx_ok") == ok0 + 1
    assert _ctr(dut, "drop_filt") == 0
    assert _ctr(dut, "drop_rate") == 0


@cocotb.test()
async def test_drop_filt_symbol(dut):
    """Symbol not enabled → drop_filt, no TX."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)  # enable 5, send 6

    f0 = _ctr(dut, "drop_filt")
    ok0 = _ctr(dut, "tx_ok")
    await send_event(dut, _make_ev(symbol_id=6, ch=CH_ORDER))
    idle = await expect_idle(dut, 40)
    assert idle, "unexpected TX on symbol filter miss"
    assert _ctr(dut, "drop_filt") == f0 + 1
    assert _ctr(dut, "tx_ok") == ok0


@cocotb.test()
async def test_drop_filt_ch_mask(dut):
    """Channel not in ch_mask → drop_filt."""
    await _init(dut, ch_mask=(1 << CH_SNAP), period=0)  # only SNAP
    await filt_set(dut, 5, 1)

    f0 = _ctr(dut, "drop_filt")
    ok0 = _ctr(dut, "tx_ok")
    await send_event(dut, _make_ev(symbol_id=5, ch=CH_TRADE))
    idle = await expect_idle(dut, 40)
    assert idle
    assert _ctr(dut, "drop_filt") == f0 + 1
    assert _ctr(dut, "tx_ok") == ok0


@cocotb.test()
async def test_token_bucket_drop_rate(dut):
    """Tiny refill + burst → some drop_rate; s_event_tready always 1."""
    # period=100, refill=1 → very slow refill; start with period!=0 so tokens
    # begin at 0 after reset. Give one refill cycle first so we can TX a few.
    await _init(dut, ch_mask=0xFF, period=4, refill=1)
    await filt_set(dut, 5, 1)

    # Wait for a few refill ticks to accumulate ~3 tokens
    for _ in range(16):
        await RisingEdge(dut.clk)

    probes: list[int] = []
    r0 = _ctr(dut, "drop_rate")
    ok0 = _ctr(dut, "tx_ok")

    # Burst many events back-to-back; some TX, rest drop_rate; never stall
    n_burst = 20
    for i in range(n_burst):
        await send_event(dut, _make_ev(symbol_id=5, ch=CH_ORDER, seq=i + 1), probe_tready=probes)

    # Drain any in-flight TX
    for _ in range(400):
        await RisingEdge(dut.clk)

    assert all(p == 1 for p in probes), f"tready not stuck at 1: {probes}"
    tx = _ctr(dut, "tx_ok") - ok0
    dr = _ctr(dut, "drop_rate") - r0
    assert tx >= 1, "expected at least one TX"
    assert dr >= 1, f"expected drop_rate, tx={tx} drop_rate={dr}"
    assert tx + dr == n_burst, f"tx({tx})+drop_rate({dr}) != burst({n_burst})"
    assert _ctr(dut, "drop_filt") == 0


@cocotb.test()
async def test_ip_checksum(dut):
    """IPv4 header checksum on TX frame matches software golden."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)

    ev = _make_ev(symbol_id=5, ch=CH_ORDER, seq=99)
    send = cocotb.start_soon(send_event(dut, ev))
    frame = await recv_frame(dut)
    await send

    parsed = parse_eth_udp(frame)
    # Zero csum field and recompute
    hdr = bytearray(parsed["ip_hdr"])
    hdr[10] = 0
    hdr[11] = 0
    expect = ipv4_checksum(bytes(hdr))
    assert parsed["ip_csum"] == expect, f"csum {parsed['ip_csum']:04x} != {expect:04x}"
    # Also verify checksum validates to 0 when included
    assert ipv4_checksum(parsed["ip_hdr"]) == 0
