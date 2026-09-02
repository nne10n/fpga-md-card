#!/usr/bin/env python3
"""x1100 top integration with ENABLE_BOOK=1: hot path book + L1 stub."""

from __future__ import annotations

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tb"))
from event_util import CH_ORDER, CH_OTHER, CH_SNAP, CH_TRADE, EXCH_SZSE, unpack_event_t

DATA_W = 32
KEEP_W = 4
DST_MAC_MCAST = bytes.fromhex("01005e000001")
SRC_MAC = bytes.fromhex("001122334455")
DST_IP = bytes.fromhex("ef010101")
SRC_IP = bytes.fromhex("0a000001")
UDP_DPORT = 0x1F40
UDP_SPORT = 0xC000
CFG_MAC = int.from_bytes(DST_MAC_MCAST, "big")
CFG_IP = int.from_bytes(DST_IP, "big")
CODE_STR = "000001"
CODE_COLD = "999999"


def default_type_lut() -> int:
    lut = 0
    for i in range(16):
        if i == 1:
            ch = CH_SNAP
        elif i == 2:
            ch = CH_ORDER
        elif i == 3:
            ch = CH_TRADE
        elif i == 4:
            ch = CH_ORDER  # CXL still ORDER channel
        else:
            ch = CH_OTHER
        lut |= (ch & 0xF) << (i * 4)
    return lut


def _checksum_ipv4(hdr: bytes) -> int:
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
            0x45, 0, ip_total, 0x1234, 0, 64, 17, 0, SRC_IP, DST_IP,
        )
    )
    struct.pack_into("!H", ip_hdr, 10, _checksum_ipv4(bytes(ip_hdr)))
    udp = struct.pack("!HHHH", UDP_SPORT, UDP_DPORT, udp_len, 0)
    return bytes(eth) + bytes(ip_hdr) + udp + payload


def build_synth_bin(msg_type, seq, code, px, qty, side, order_id) -> bytes:
    code_b = code.encode("ascii")[:6].ljust(6, b" ")
    if msg_type == 1:
        ch_hint = CH_SNAP
    elif msg_type in (2, 4):
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


def pack_eth_tuser(port_id=0, sop_ts=0) -> int:
    return ((port_id & 0x7) << 64) | (sop_ts & ((1 << 64) - 1))


def code_from_ascii6(s: str) -> int:
    v = 0
    for i, ch in enumerate(s.encode("ascii")):
        v |= ch << (8 * i)
    return v


async def axis_send_port32(dut, port: str, frame: bytes, tuser: int = 0):
    prefix = f"s_axis_{port}"
    tdata = getattr(dut, f"{prefix}_tdata")
    tkeep = getattr(dut, f"{prefix}_tkeep")
    tvalid = getattr(dut, f"{prefix}_tvalid")
    tlast = getattr(dut, f"{prefix}_tlast")
    tready = getattr(dut, f"{prefix}_tready")
    tuser_p = getattr(dut, f"{prefix}_tuser")
    i = 0
    n = len(frame)
    first = True
    while i < n:
        chunk = frame[i : i + KEEP_W]
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
            assert int(tready.value) == 1, "ingress backpressure"
            break
        i += len(chunk)
    tvalid.value = 0
    tlast.value = 0


async def reset_top(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for port in ("a", "b"):
        getattr(dut, f"s_axis_{port}_tdata").value = 0
        getattr(dut, f"s_axis_{port}_tkeep").value = 0
        getattr(dut, f"s_axis_{port}_tvalid").value = 0
        getattr(dut, f"s_axis_{port}_tlast").value = 0
        getattr(dut, f"s_axis_{port}_tuser").value = 0
    dut.m_mcast_tready.value = 1
    dut.m_dma_tready.value = 1
    dut.m_book_tready.value = 1
    dut.cam_we.value = 0
    dut.cam_swap.value = 0
    dut.cam_addr.value = 0
    dut.cam_key.value = 0
    dut.cam_id.value = 0
    dut.cam_entry_valid.value = 0
    dut.hot_we.value = 0
    dut.hot_addr.value = 0
    dut.hot_code.value = 0
    dut.hot_entry_valid.value = 0
    dut.book_clear.value = 0
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
    dut.cfg_szse_off_type.value = 0
    dut.cfg_szse_off_seq.value = 4
    dut.cfg_szse_off_code.value = 8
    dut.cfg_szse_off_px.value = 14
    dut.cfg_szse_off_qty.value = 22
    dut.cfg_szse_off_side.value = 26
    dut.cfg_szse_off_oid.value = 27
    dut.cfg_szse_len_hdr.value = 36
    dut.cfg_szse_type_lut.value = lut
    dut.cfg_szse_off_ch_hint.value = 35
    dut.cfg_pass_miss.value = 1  # book path: allow miss through
    dut.cfg_mcast_src_mac.value = 0x001122334455
    dut.cfg_mcast_dst_mac.value = CFG_MAC
    dut.cfg_mcast_src_ip.value = 0x0A000001
    dut.cfg_mcast_dst_ip.value = CFG_IP
    dut.cfg_mcast_udp_sport.value = 0xC000
    dut.cfg_mcast_udp_dport.value = UDP_DPORT
    dut.cfg_ch_mask.value = 0xFF
    dut.cfg_mcast_period.value = 0
    dut.cfg_mcast_refill.value = 1


async def hot_load(dut, addr: int, code: str):
    dut.hot_addr.value = addr & 0x3F
    dut.hot_code.value = code_from_ascii6(code)
    dut.hot_entry_valid.value = 1
    dut.hot_we.value = 1
    await RisingEdge(dut.clk)
    dut.hot_we.value = 0
    await RisingEdge(dut.clk)


async def enable_filt_all(dut):
    # With ENABLE_BOOK, symbol_id may be 0 — enable filt bit 0
    dut.filt_addr.value = 0
    dut.filt_bit.value = 1
    dut.filt_we.value = 1
    await RisingEdge(dut.clk)
    dut.filt_we.value = 0


@cocotb.test()
async def test_x1100_book_hot_add_l1(dut):
    """ENABLE_BOOK=1: hot ORDER increments L1 + delta; cold ORDER only L1."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _apply_cfg(dut)
    await reset_top(dut)
    await hot_load(dut, 0, CODE_STR)
    await enable_filt_all(dut)

    # Hot add
    frame = build_udp_frame(build_synth_bin(2, 1, CODE_STR, 100, 10, 1, 0x11))
    await axis_send_port32(dut, "a", frame, pack_eth_tuser(0, 0x100))
    for _ in range(80):
        await RisingEdge(dut.clk)

    assert int(dut.book_l1_push_cnt.value) >= 1
    assert int(dut.book_hot_hit_cnt.value) >= 1
    assert int(dut.book_delta_cnt.value) >= 1

    l1_after_hot = int(dut.book_l1_push_cnt.value)
    d_after_hot = int(dut.book_delta_cnt.value)

    # Cold add
    frame2 = build_udp_frame(build_synth_bin(2, 2, CODE_COLD, 50, 1, 1, 0x22))
    await axis_send_port32(dut, "a", frame2, pack_eth_tuser(0, 0x200))
    for _ in range(80):
        await RisingEdge(dut.clk)

    assert int(dut.book_l1_push_cnt.value) == l1_after_hot + 1
    assert int(dut.book_delta_cnt.value) == d_after_hot
    assert int(dut.book_hot_miss_cnt.value) >= 1
