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
# Formal DA is RFC1112(DIP), not a user-supplied MAC.
SRC_MAC = bytes.fromhex("001122334455")
DST_IP = bytes.fromhex("ef010101")  # 239.1.1.1
SRC_IP = bytes.fromhex("0a000001")  # 10.0.0.1
UDP_SPORT = 0xC000
UDP_DPORT = 0x1F40


def rfc1112_da(dip: bytes) -> bytes:
    """01-00-5E + (IPv4 & 0x7FFFFF)."""
    ip = int.from_bytes(dip, "big")
    return bytes.fromhex("01005e") + (ip & 0x7FFFFF).to_bytes(3, "big")


DST_MAC = rfc1112_da(DST_IP)  # 01:00:5e:01:01:01
# Deliberately *not* RFC1112(DIP) — formal path must ignore this pin.
CFG_DST_MAC_BOGUS = int.from_bytes(bytes.fromhex("aabbccddeeff"), "big")
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


def _drive_meta(dut, *, valid: int = 0, **fields):
    dut.i_s_udp_meta_valid.value = valid & 1
    dut.i_s_udp_dst_ip.value = fields.get("dst_ip", 0)
    dut.i_s_udp_src_ip.value = fields.get("src_ip", 0)
    dut.i_s_udp_sport.value = fields.get("sport", 0)
    dut.i_s_udp_dport.value = fields.get("dport", 0)
    dut.i_s_udp_ttl.value = fields.get("ttl", 0)
    dut.i_s_udp_payload_len.value = fields.get("payload_len", 0)
    dut.i_s_udp_is_mcast.value = fields.get("is_mcast", 0)


async def reset_dut(dut, cycles: int = 5):
    dut.sys_rst_n.value = 0
    dut.i_s_event_tdata.value = 0
    dut.i_s_event_tvalid.value = 0
    dut.i_s_event_tlast.value = 0
    dut.i_m_axis_tready.value = 1
    dut.i_filt_we.value = 0
    dut.i_filt_addr.value = 0
    dut.i_filt_bit.value = 0
    _drive_meta(dut, valid=0)
    for _ in range(cycles):
        await RisingEdge(dut.sys_clk)
    dut.sys_rst_n.value = 1
    # Bitmap clear is large — a few extra cycles after release
    for _ in range(3):
        await RisingEdge(dut.sys_clk)


async def apply_cfg(
    dut,
    *,
    ch_mask: int = 0xFF,
    period: int = 0,
    refill: int = 0,
    ttl_default: int = 1,
    map_en: int = 1,
    mtu_pay: int = 1472,
    dst_mac: int | None = None,
):
    dut.i_cfg_src_mac.value = CFG_SRC_MAC
    dut.i_cfg_dst_mac.value = CFG_DST_MAC_BOGUS if dst_mac is None else (dst_mac & ((1 << 48) - 1))
    dut.i_cfg_src_ip.value = CFG_SRC_IP
    dut.i_cfg_dst_ip.value = CFG_DST_IP
    dut.i_cfg_udp_sport.value = UDP_SPORT
    dut.i_cfg_udp_dport.value = UDP_DPORT
    dut.i_cfg_ch_mask.value = ch_mask & 0xFF
    dut.i_cfg_period.value = period & 0xFFFF
    dut.i_cfg_refill.value = refill & 0xFFFF
    dut.i_cfg_ttl_default.value = ttl_default & 0xFF
    dut.i_cfg_map_en.value = map_en & 1
    dut.i_cfg_mtu_pay.value = mtu_pay & 0xFFFF
    _drive_meta(dut, valid=0)
    await RisingEdge(dut.sys_clk)


async def filt_set(dut, symbol_id: int, enable: int = 1):
    dut.i_filt_addr.value = symbol_id & 0x1FFF
    dut.i_filt_bit.value = enable & 1
    dut.i_filt_we.value = 1
    await RisingEdge(dut.sys_clk)
    dut.i_filt_we.value = 0
    await RisingEdge(dut.sys_clk)


async def send_event(dut, data: int, probe_tready=None):
    """Drive one event beat; record tready if requested."""
    dut.i_s_event_tdata.value = data
    dut.i_s_event_tvalid.value = 1
    dut.i_s_event_tlast.value = 1
    await RisingEdge(dut.sys_clk)
    if probe_tready is not None:
        probe_tready.append(int(dut.o_s_event_tready.value))
    dut.i_s_event_tvalid.value = 0
    dut.i_s_event_tlast.value = 0


async def recv_frame(dut, timeout_cycles: int = 200) -> bytes:
    buf = bytearray()
    cycles = 0
    got = False
    while cycles < timeout_cycles:
        await RisingEdge(dut.sys_clk)
        cycles += 1
        if int(dut.o_m_axis_tvalid.value) == 1 and int(dut.i_m_axis_tready.value) == 1:
            data = int(dut.o_m_axis_tdata.value)
            keep = int(dut.o_m_axis_tkeep.value)
            last = int(dut.o_m_axis_tlast.value)
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
        await RisingEdge(dut.sys_clk)
        if int(dut.o_m_axis_tvalid.value) == 1:
            return False
    return True


async def _init(
    dut,
    *,
    ch_mask: int = 0xFF,
    period: int = 0,
    refill: int = 0,
    ttl_default: int = 1,
    map_en: int = 1,
    mtu_pay: int = 1472,
    dst_mac: int | None = None,
):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await apply_cfg(
        dut,
        ch_mask=ch_mask,
        period=period,
        refill=refill,
        ttl_default=ttl_default,
        map_en=map_en,
        mtu_pay=mtu_pay,
        dst_mac=dst_mac,
    )
    await reset_dut(dut)
    # Re-apply cfg after reset (rst does not clear cfg inputs, but be explicit)
    await apply_cfg(
        dut,
        ch_mask=ch_mask,
        period=period,
        refill=refill,
        ttl_default=ttl_default,
        map_en=map_en,
        mtu_pay=mtu_pay,
        dst_mac=dst_mac,
    )


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
    ok0 = _ctr(dut, "o_tx_ok")

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
    assert parsed["ttl"] == 1
    assert len(parsed["payload"]) == 64
    assert _ctr(dut, "o_stat_dst_mac") == int.from_bytes(DST_MAC, "big")

    got = payload_to_event(parsed["payload"])
    assert got == ev, (
        f"payload mismatch\n"
        f" got={unpack_event_t(got)}\n"
        f" exp={unpack_event_t(ev)}"
    )
    assert _ctr(dut, "o_tx_ok") == ok0 + 1
    assert _ctr(dut, "o_drop_filt") == 0
    assert _ctr(dut, "o_drop_rate") == 0


@cocotb.test()
async def test_drop_filt_symbol(dut):
    """Symbol not enabled → drop_filt, no TX."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)  # enable 5, send 6

    f0 = _ctr(dut, "o_drop_filt")
    ok0 = _ctr(dut, "o_tx_ok")
    await send_event(dut, _make_ev(symbol_id=6, ch=CH_ORDER))
    idle = await expect_idle(dut, 40)
    assert idle, "unexpected TX on symbol filter miss"
    assert _ctr(dut, "o_drop_filt") == f0 + 1
    assert _ctr(dut, "o_tx_ok") == ok0


@cocotb.test()
async def test_drop_filt_ch_mask(dut):
    """Channel not in ch_mask → drop_filt."""
    await _init(dut, ch_mask=(1 << CH_SNAP), period=0)  # only SNAP
    await filt_set(dut, 5, 1)

    f0 = _ctr(dut, "o_drop_filt")
    ok0 = _ctr(dut, "o_tx_ok")
    await send_event(dut, _make_ev(symbol_id=5, ch=CH_TRADE))
    idle = await expect_idle(dut, 40)
    assert idle
    assert _ctr(dut, "o_drop_filt") == f0 + 1
    assert _ctr(dut, "o_tx_ok") == ok0


@cocotb.test()
async def test_token_bucket_drop_rate(dut):
    """Tiny refill + burst → some drop_rate; s_event_tready always 1."""
    # period=100, refill=1 → very slow refill; start with period!=0 so tokens
    # begin at 0 after reset. Give one refill cycle first so we can TX a few.
    await _init(dut, ch_mask=0xFF, period=4, refill=1)
    await filt_set(dut, 5, 1)

    # Wait for a few refill ticks to accumulate ~3 tokens
    for _ in range(16):
        await RisingEdge(dut.sys_clk)

    probes: list[int] = []
    r0 = _ctr(dut, "o_drop_rate")
    ok0 = _ctr(dut, "o_tx_ok")

    # Burst many events back-to-back; some TX, rest drop_rate; never stall
    n_burst = 20
    for i in range(n_burst):
        await send_event(dut, _make_ev(symbol_id=5, ch=CH_ORDER, seq=i + 1), probe_tready=probes)

    # Drain any in-flight TX
    for _ in range(400):
        await RisingEdge(dut.sys_clk)

    assert all(p == 1 for p in probes), f"tready not stuck at 1: {probes}"
    tx = _ctr(dut, "o_tx_ok") - ok0
    dr = _ctr(dut, "o_drop_rate") - r0
    assert tx >= 1, "expected at least one TX"
    assert dr >= 1, f"expected drop_rate, tx={tx} drop_rate={dr}"
    assert tx + dr == n_burst, f"tx({tx})+drop_rate({dr}) != burst({n_burst})"
    assert _ctr(dut, "o_drop_filt") == 0


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
    assert parsed["ttl"] == 1
    assert parsed["dst_mac"] == DST_MAC


async def _expect_gate_drop(dut, **meta):
    g0 = _ctr(dut, "o_drop_gate")
    n0 = _ctr(dut, "o_nosend")
    ok0 = _ctr(dut, "o_tx_ok")
    sticky0 = int(dut.o_dbg_err_sticky.value)
    _drive_meta(dut, valid=1, **meta)
    await send_event(dut, _make_ev(symbol_id=5, ch=CH_ORDER))
    idle = await expect_idle(dut, 40)
    assert idle, "unexpected TX on contract gate fail"
    assert _ctr(dut, "o_drop_gate") == g0 + 1
    assert _ctr(dut, "o_nosend") == n0 + 1
    assert _ctr(dut, "o_tx_ok") == ok0
    assert int(dut.o_dbg_err_sticky.value) == 1
    assert sticky0 in (0, 1)
    _drive_meta(dut, valid=0)


@cocotb.test()
async def test_rfc1112_ignores_user_mac(dut):
    """cfg_dst_mac is not the on-wire DA; DA = RFC1112(cfg_dst_ip)."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["dst_mac"] == DST_MAC
    assert parsed["dst_mac"] != bytes.fromhex("aabbccddeeff")


@cocotb.test()
async def test_ttl_zero_becomes_one(dut):
    """CSR ttl_default=0 is treated as 1 on the wire."""
    await _init(dut, ch_mask=0xFF, period=0, ttl_default=0)
    await filt_set(dut, 5, 1)
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["ttl"] == 1
    hdr = bytearray(parsed["ip_hdr"])
    hdr[10] = 0
    hdr[11] = 0
    assert parsed["ip_csum"] == ipv4_checksum(bytes(hdr))


@cocotb.test()
async def test_meta_overrides_csr(dut):
    """SOP meta DIP/ports/TTL override CSR; DA follows the locked DIP."""
    await _init(dut, ch_mask=0xFF, period=0, ttl_default=4)
    await filt_set(dut, 5, 1)
    meta_dip = bytes.fromhex("e1000001")  # 225.0.0.1
    _drive_meta(
        dut,
        valid=1,
        dst_ip=int.from_bytes(meta_dip, "big"),
        src_ip=0x0A000002,
        sport=0x1111,
        dport=0x2222,
        ttl=7,
        payload_len=64,
        is_mcast=1,
    )
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["dst_ip"] == meta_dip
    assert parsed["src_ip"] == bytes.fromhex("0a000002")
    assert parsed["sport"] == 0x1111
    assert parsed["dport"] == 0x2222
    assert parsed["ttl"] == 7
    assert parsed["dst_mac"] == rfc1112_da(meta_dip)


@cocotb.test()
async def test_gate_not_224(dut):
    """DIP outside 224/4 → drop_gate, sticky, no TX."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)
    await _expect_gate_drop(
        dut,
        dst_ip=0x0A000009,
        src_ip=CFG_SRC_IP,
        sport=UDP_SPORT,
        dport=UDP_DPORT,
        ttl=1,
        payload_len=64,
        is_mcast=1,
    )


@cocotb.test()
async def test_gate_sa_is_group(dut):
    """Source IP in 224/4 → drop_gate."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)
    await _expect_gate_drop(
        dut,
        dst_ip=CFG_DST_IP,
        src_ip=0xE1000001,
        sport=UDP_SPORT,
        dport=UDP_DPORT,
        ttl=1,
        payload_len=64,
        is_mcast=1,
    )


@cocotb.test()
async def test_gate_len_mismatch(dut):
    """payload_len != actual 64B event → drop_gate."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)
    await _expect_gate_drop(
        dut,
        dst_ip=CFG_DST_IP,
        src_ip=CFG_SRC_IP,
        sport=UDP_SPORT,
        dport=UDP_DPORT,
        ttl=1,
        payload_len=32,
        is_mcast=1,
    )


@cocotb.test()
async def test_gate_map_en0_bogus_mac_still_tx(dut):
    """map_en=0 + CSR dst_mac != RFC1112: still TX; on-wire DA is RFC1112, not user MAC."""
    await _init(dut, ch_mask=0xFF, period=0, map_en=0, dst_mac=CFG_DST_MAC_BOGUS)
    await filt_set(dut, 5, 1)
    g0 = _ctr(dut, "o_drop_gate")
    ok0 = _ctr(dut, "o_tx_ok")
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["dst_mac"] == DST_MAC
    assert parsed["dst_mac"] != bytes.fromhex("aabbccddeeff")
    assert parsed["dst_ip"] == DST_IP
    assert _ctr(dut, "o_tx_ok") == ok0 + 1
    assert _ctr(dut, "o_drop_gate") == g0
    assert int(dut.o_dbg_err_sticky.value) == 0


@cocotb.test()
async def test_gate_map_en0_mac_match(dut):
    """map_en=0 and CSR dst_mac == RFC1112(dip) → TX; on-wire DA still RFC1112."""
    await _init(
        dut,
        ch_mask=0xFF,
        period=0,
        map_en=0,
        dst_mac=int.from_bytes(DST_MAC, "big"),
    )
    await filt_set(dut, 5, 1)
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["dst_mac"] == DST_MAC
    assert parsed["dst_ip"] == DST_IP


@cocotb.test()
async def test_map_en1_meta_dip_still_tx(dut):
    """map_en=1: locked DIP need not equal CSR DIP; DA = RFC1112(locked DIP)."""
    await _init(dut, ch_mask=0xFF, period=0, map_en=1)
    await filt_set(dut, 5, 1)
    meta_dip = bytes.fromhex("e1000001")
    _drive_meta(
        dut,
        valid=1,
        dst_ip=int.from_bytes(meta_dip, "big"),
        src_ip=CFG_SRC_IP,
        sport=UDP_SPORT,
        dport=UDP_DPORT,
        ttl=1,
        payload_len=64,
        is_mcast=1,
    )
    send = cocotb.start_soon(send_event(dut, _make_ev()))
    frame = await recv_frame(dut)
    await send
    parsed = parse_eth_udp(frame)
    assert parsed["dst_ip"] == meta_dip
    assert parsed["dst_mac"] == rfc1112_da(meta_dip)


@cocotb.test()
async def test_ready_always_one_on_gate_fail(dut):
    """Role A: tready stays 1 through a gate drop."""
    await _init(dut, ch_mask=0xFF, period=0)
    await filt_set(dut, 5, 1)
    probes: list[int] = []
    _drive_meta(
        dut,
        valid=1,
        dst_ip=0x0A000009,
        src_ip=CFG_SRC_IP,
        sport=UDP_SPORT,
        dport=UDP_DPORT,
        ttl=1,
        payload_len=64,
        is_mcast=1,
    )
    await send_event(dut, _make_ev(), probe_tready=probes)
    assert probes == [1]
