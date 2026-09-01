#!/usr/bin/env python3
"""cocotb integration tests for md_rx_top (M8)."""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from event_util import (
    CH_ORDER,
    CH_OTHER,
    CH_SNAP,
    CH_TRADE,
    EXCH_SSE,
    EXCH_SZSE,
    unpack_event_t,
)

# Multicast / strip defaults (match test_udp_strip)
DST_MAC_MCAST = bytes.fromhex("01005e000001")
SRC_MAC = bytes.fromhex("001122334455")
DST_IP = bytes.fromhex("ef010101")
SRC_IP = bytes.fromhex("0a000001")
UDP_DPORT = 0x1F40
UDP_SPORT = 0xC000
CFG_MAC = int.from_bytes(DST_MAC_MCAST, "big")
CFG_IP = int.from_bytes(DST_IP, "big")

# §6 synthetic offsets
OFF_TYPE = 0
OFF_SEQ = 4
OFF_CODE = 8
OFF_PX = 14
OFF_QTY = 22
OFF_SIDE = 26
OFF_OID = 27
OFF_CH_HINT = 35
LEN_HDR = 36

SYM_ID = 0x42
CODE_STR = "000001"


def default_type_lut() -> int:
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


def _checksum_ipv4(hdr: bytes) -> int:
    assert len(hdr) % 2 == 0
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_udp_frame(payload: bytes) -> bytes:
    eth = DST_MAC_MCAST + SRC_MAC + struct.pack("!H", 0x0800)
    udp_len = 8 + len(payload)
    ip_total = 20 + udp_len
    ip_hdr = bytearray(
        struct.pack(
            "!BBHHHBBH4s4s",
            0x45,
            0,
            ip_total,
            0x1234,
            0,
            64,
            17,
            0,
            SRC_IP,
            DST_IP,
        )
    )
    struct.pack_into("!H", ip_hdr, 10, _checksum_ipv4(bytes(ip_hdr)))
    udp = struct.pack("!HHHH", UDP_SPORT, UDP_DPORT, udp_len, 0)
    return bytes(eth) + bytes(ip_hdr) + udp + payload


def build_synth_bin(
    msg_type: int,
    seq: int,
    code: str,
    px: int,
    qty: int,
    side: int,
    order_id: int,
) -> bytes:
    code_b = code.encode("ascii")[:6].ljust(6, b" ")
    if msg_type == 1:
        ch_hint = CH_SNAP
    elif msg_type == 2:
        ch_hint = CH_ORDER
    elif msg_type == 3:
        ch_hint = CH_TRADE
    else:
        ch_hint = CH_OTHER
    body = (
        struct.pack("!I", seq)
        + code_b
        + struct.pack("!Q", px)
        + struct.pack("!I", qty)
        + struct.pack("!B", side)
        + struct.pack("!Q", order_id)
        + struct.pack("!B", ch_hint)
    )
    return struct.pack("!HH", msg_type & 0xFFFF, len(body) & 0xFFFF) + body


def pack_eth_tuser(port_id: int = 0, sop_ts: int = 0) -> int:
    return ((port_id & 0x7) << 64) | (sop_ts & ((1 << 64) - 1))


def code_from_ascii6(s: str) -> int:
    v = 0
    for i, ch in enumerate(s.encode("ascii")):
        v |= ch << (8 * i)
    return v


def make_key(exch: int, code48: int) -> int:
    return ((exch & 3) << 48) | (code48 & ((1 << 48) - 1))


def hash13(key: int) -> int:
    return (key & 0x1FFF) ^ ((key >> 13) & 0x1FFF) ^ ((key >> 26) & 0x1FFF)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


async def axis_send_port(dut, port: int, frame: bytes, tuser: int = 0):
    i = 0
    n = len(frame)
    first = True
    tdata = getattr(dut, f"s{port}_tdata")
    tkeep = getattr(dut, f"s{port}_tkeep")
    tvalid = getattr(dut, f"s{port}_tvalid")
    tlast = getattr(dut, f"s{port}_tlast")
    tready = getattr(dut, f"s{port}_tready")
    tuser_p = getattr(dut, f"s{port}_tuser")
    while i < n:
        chunk = frame[i : i + 8]
        data = 0
        keep = 0
        for b_i, b in enumerate(chunk):
            data |= (b & 0xFF) << (8 * b_i)
            keep |= 1 << b_i
        tdata.value = data
        tkeep.value = keep
        tvalid.value = 1
        tlast.value = 1 if (i + len(chunk) >= n) else 0
        if first:
            tuser_p.value = tuser
            first = False
        while True:
            await RisingEdge(dut.clk)
            if int(tready.value) == 1:
                break
        i += len(chunk)
    tvalid.value = 0
    tlast.value = 0
    tkeep.value = 0


async def recv_dma_event(dut, timeout_cycles: int = 2000) -> int:
    beats = []
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_dma_tvalid.value) == 1 and int(dut.m_dma_tready.value) == 1:
            beats.append(int(dut.m_dma_tdata.value) & ((1 << 64) - 1))
            if int(dut.m_dma_tlast.value):
                assert len(beats) == 8, f"expected 8 beats, got {len(beats)}"
                ev = 0
                for i, b in enumerate(beats):
                    ev |= b << (64 * i)
                return ev
    raise TimeoutError("no dma event")


async def expect_no_dma(dut, cycles: int = 80) -> bool:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_dma_tvalid.value) == 1:
            return False
    return True


async def cam_write(dut, addr: int, key: int, sym_id: int, valid: int = 1):
    dut.cam_addr.value = addr & 0x1FFF
    dut.cam_key.value = key & ((1 << 56) - 1)
    dut.cam_id.value = sym_id & 0xFFFF
    dut.cam_entry_valid.value = valid & 1
    dut.cam_we.value = 1
    await RisingEdge(dut.clk)
    dut.cam_we.value = 0


async def cam_swap(dut):
    dut.cam_swap.value = 1
    await RisingEdge(dut.clk)
    dut.cam_swap.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def reset_top(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for p in range(4):
        getattr(dut, f"s{p}_tdata").value = 0
        getattr(dut, f"s{p}_tkeep").value = 0
        getattr(dut, f"s{p}_tvalid").value = 0
        getattr(dut, f"s{p}_tlast").value = 0
        getattr(dut, f"s{p}_tuser").value = 0
    dut.m_mcast_tready.value = 1
    dut.m_dma_tready.value = 1
    dut.cam_we.value = 0
    dut.cam_swap.value = 0
    dut.cam_addr.value = 0
    dut.cam_key.value = 0
    dut.cam_id.value = 0
    dut.cam_entry_valid.value = 0
    dut.filt_we.value = 0
    dut.filt_addr.value = 0
    dut.filt_bit.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


async def _apply_cfg(dut):
    dut.cfg_dst_mac.value = CFG_MAC
    dut.cfg_dst_ip.value = CFG_IP
    dut.cfg_udp_dport.value = UDP_DPORT

    lut = default_type_lut()
    for prefix in ("cfg_szse", "cfg_sse"):
        getattr(dut, f"{prefix}_off_type").value = OFF_TYPE
        getattr(dut, f"{prefix}_off_seq").value = OFF_SEQ
        getattr(dut, f"{prefix}_off_code").value = OFF_CODE
        getattr(dut, f"{prefix}_off_px").value = OFF_PX
        getattr(dut, f"{prefix}_off_qty").value = OFF_QTY
        getattr(dut, f"{prefix}_off_side").value = OFF_SIDE
        getattr(dut, f"{prefix}_off_oid").value = OFF_OID
        getattr(dut, f"{prefix}_len_hdr").value = LEN_HDR
        getattr(dut, f"{prefix}_type_lut").value = lut
        getattr(dut, f"{prefix}_off_ch_hint").value = OFF_CH_HINT

    dut.cfg_sse_is_fast.value = 0  # Binary default; FAST via dedicated test
    dut.cfg_pass_miss.value = 0
    dut.cfg_mcast_src_mac.value = 0x001122334455
    dut.cfg_mcast_dst_mac.value = CFG_MAC
    dut.cfg_mcast_src_ip.value = 0x0A000001
    dut.cfg_mcast_dst_ip.value = CFG_IP
    dut.cfg_mcast_udp_sport.value = 0xC000
    dut.cfg_mcast_udp_dport.value = UDP_DPORT
    dut.cfg_ch_mask.value = 0xFF
    dut.cfg_mcast_period.value = 0
    dut.cfg_mcast_refill.value = 1


async def preload_cam(dut, exch: int, code: str, sym_id: int = SYM_ID):
    code48 = code_from_ascii6(code)
    key = make_key(exch, code48)
    addr = hash13(key)
    await cam_write(dut, addr, key, sym_id, valid=1)
    await cam_swap(dut)


async def enable_filt(dut, sym_id: int = SYM_ID):
    dut.filt_addr.value = sym_id & 0x1FFF
    dut.filt_bit.value = 1
    dut.filt_we.value = 1
    await RisingEdge(dut.clk)
    dut.filt_we.value = 0


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _apply_cfg(dut)
    await reset_top(dut)


@cocotb.test()
async def test_szse_ab_dedup_one_dma(dut):
    """Identical SZSE ORDER on port2 and port3 → exactly one DMA event; B dropped."""
    await _init(dut)
    await preload_cam(dut, EXCH_SZSE, CODE_STR, SYM_ID)
    await enable_filt(dut, SYM_ID)

    seq = 1
    px = 12345
    qty = 100
    side = 1
    oid = 0xAABBCCDDEEFF0011
    payload = build_synth_bin(2, seq, CODE_STR, px, qty, side, oid)
    frame = build_udp_frame(payload)
    ts = 0x1111

    # CAM lookup is 2 cycles: DMA may start during the second ingress frame.
    recv = cocotb.start_soon(recv_dma_event(dut, timeout_cycles=3000))
    await axis_send_port(dut, 2, frame, pack_eth_tuser(2, ts))
    await axis_send_port(dut, 3, frame, pack_eth_tuser(3, ts + 1))

    ev_raw = await recv
    ev = unpack_event_t(ev_raw)
    assert ev["exch"] == EXCH_SZSE, ev
    assert ev["ch"] == CH_ORDER, ev
    assert ev["seq"] == seq, ev
    assert ev["px"] == px, ev
    assert ev["qty"] == qty, ev
    assert ev["symbol_id"] == SYM_ID, ev
    assert ev["ts_ns"] == ts, ev

    idle = await expect_no_dma(dut, 120)
    assert idle, "duplicate B leaked to DMA"

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert _ctr(dut, "telem_arb_fwd") >= 1
    assert _ctr(dut, "telem_arb_dup") >= 1
    assert _ctr(dut, "telem_cam_hit") >= 1
    assert _ctr(dut, "telem_dma_tx") >= 1


@cocotb.test()
async def test_sse_port0_dma_exch(dut):
    """SSE port0 alone → one DMA event with EXCH_SSE and CAM hit."""
    await _init(dut)
    await preload_cam(dut, EXCH_SSE, CODE_STR, SYM_ID)
    await enable_filt(dut, SYM_ID)

    seq = 7
    px = 999
    qty = 50
    payload = build_synth_bin(2, seq, CODE_STR, px, qty, 2, 0x55)
    frame = build_udp_frame(payload)
    ts = 0x2222

    recv = cocotb.start_soon(recv_dma_event(dut, timeout_cycles=3000))
    await axis_send_port(dut, 0, frame, pack_eth_tuser(0, ts))
    ev_raw = await recv
    ev = unpack_event_t(ev_raw)
    assert ev["exch"] == EXCH_SSE, ev
    assert ev["ch"] == CH_ORDER, ev
    assert ev["seq"] == seq, ev
    assert ev["px"] == px, ev
    assert ev["symbol_id"] == SYM_ID, ev
    assert ev["ts_ns"] == ts, ev

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert _ctr(dut, "telem_dma_tx") >= 1
    assert _ctr(dut, "telem_cam_hit") >= 1


@cocotb.test()
async def test_szse_cam_miss_drop(dut):
    """SZSE ORDER without CAM preload → no DMA (cfg_pass_miss=0)."""
    await _init(dut)
    await enable_filt(dut, SYM_ID)

    payload = build_synth_bin(2, 1, CODE_STR, 1, 1, 1, 1)
    frame = build_udp_frame(payload)
    await axis_send_port(dut, 2, frame, pack_eth_tuser(2, 0x3333))
    idle = await expect_no_dma(dut, 200)
    assert idle, "miss should drop"
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert _ctr(dut, "telem_cam_miss") >= 1


def build_synth_fast(pmap: int, code: str, seq: int, px: int, qty: int) -> bytes:
    code_b = code.encode("ascii")[:6].ljust(6, b" ")
    return (
        struct.pack("!B", pmap & 0xFF)
        + code_b
        + struct.pack("!I", seq & 0xFFFFFFFF)
        + struct.pack("!Q", px & ((1 << 64) - 1))
        + struct.pack("!I", qty & 0xFFFFFFFF)
    )


@cocotb.test()
async def test_sse_fast_port0_cfg(dut):
    """cfg_sse_is_fast=1 on port0 → FAST template → one DMA event EXCH_SSE/CH_SNAP."""
    await _init(dut)
    dut.cfg_sse_is_fast.value = 1
    await RisingEdge(dut.clk)

    await preload_cam(dut, EXCH_SSE, CODE_STR, SYM_ID)
    await enable_filt(dut, SYM_ID)

    pmap = 0x11
    seq = 42
    px = 0x123456789ABCDEF0
    qty = 777
    ts = 0xF001
    payload = build_synth_fast(pmap, CODE_STR, seq, px, qty)
    frame = build_udp_frame(payload)

    recv = cocotb.start_soon(recv_dma_event(dut, timeout_cycles=3000))
    await axis_send_port(dut, 0, frame, pack_eth_tuser(0, ts))
    ev_raw = await recv
    ev = unpack_event_t(ev_raw)
    assert ev["exch"] == EXCH_SSE, ev
    assert ev["ch"] == CH_SNAP, ev
    assert ev["seq"] == seq, ev
    assert ev["px"] == px, ev
    assert ev["qty"] == qty, ev
    assert ev["msg_type"] == (pmap & 0xFF), ev
    assert ev["symbol_id"] == SYM_ID, ev
    assert ev["ts_ns"] == ts, ev

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert _ctr(dut, "telem_dma_tx") >= 1
    assert _ctr(dut, "telem_cam_hit") >= 1
    assert _ctr(dut, "telem_msg_ok") >= 1
