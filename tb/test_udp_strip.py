#!/usr/bin/env python3
"""cocotb tests for udp_strip (M1)."""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from axis_bfm import (
    axis_expect_idle,
    axis_recv_frame,
    axis_send_frame,
    pack_tuser,
    reset_dut,
    unpack_pay_tuser,
)

# Multicast example from design doc
DST_MAC_MCAST = bytes.fromhex("01005e000001")
SRC_MAC = bytes.fromhex("001122334455")
DST_IP = bytes.fromhex("ef010101")  # 239.1.1.1
SRC_IP = bytes.fromhex("0a000001")  # 10.0.0.1
UDP_DPORT = 0x1F40
UDP_SPORT = 0xC000

CFG_MAC = int.from_bytes(DST_MAC_MCAST, "big")
CFG_IP = int.from_bytes(DST_IP, "big")


def _checksum_ipv4(hdr: bytes) -> int:
    """IPv4 header checksum (optional; DUT does not check)."""
    assert len(hdr) % 2 == 0
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_udp_frame(
    payload: bytes,
    *,
    dst_mac: bytes = DST_MAC_MCAST,
    src_mac: bytes = SRC_MAC,
    dst_ip: bytes = DST_IP,
    src_ip: bytes = SRC_IP,
    udp_dport: int = UDP_DPORT,
    udp_sport: int = UDP_SPORT,
    proto: int = 17,
    ihl: int = 5,
    ethertype: int = 0x0800,
) -> bytes:
    """Build Ethernet + IPv4 (+options) + UDP + payload. No FCS."""
    assert 5 <= ihl <= 15
    ip_hdr_len = ihl * 4
    udp_len = 8 + len(payload)
    ip_total = ip_hdr_len + udp_len

    eth = dst_mac + src_mac + struct.pack("!H", ethertype)

    ver_ihl = (0x4 << 4) | (ihl & 0xF)
    ip_hdr = bytearray(
        struct.pack(
            "!BBHHHBBH4s4s",
            ver_ihl,
            0,  # DSCP
            ip_total,
            0x1234,  # id
            0,  # flags/frag
            64,  # ttl
            proto,
            0,  # checksum placeholder
            src_ip,
            dst_ip,
        )
    )
    # IP options (pad to ihl)
    opt_len = ip_hdr_len - 20
    if opt_len:
        ip_hdr.extend(b"\x00" * opt_len)
    csum = _checksum_ipv4(bytes(ip_hdr))
    struct.pack_into("!H", ip_hdr, 10, csum)

    udp = struct.pack("!HHHH", udp_sport, udp_dport, udp_len, 0)  # csum=0
    return bytes(eth) + bytes(ip_hdr) + udp + payload


async def _init(dut, cfg_dport: int = UDP_DPORT):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.i_cfg_dst_mac.value = CFG_MAC
    dut.i_cfg_dst_ip.value = CFG_IP
    dut.i_cfg_udp_dport.value = cfg_dport
    await reset_dut(dut)
    await RisingEdge(dut.clk)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


@cocotb.test()
async def test_happy_multicast(dut):
    """IPv4 UDP multicast → payload exact, tuser, frames_ok==1."""
    await _init(dut)
    payload = b"HELLOMD" * 4  # 28 bytes
    frame = build_udp_frame(payload)
    tuser_in = pack_tuser(port_id=2, sop_ts=0x1111_2222_3333_4444)

    ok0 = _ctr(dut, "o_frames_ok")
    send_task = cocotb.start_soon(axis_send_frame(dut, frame, tuser=tuser_in))
    # Small delay so first beats arrive, then collect
    await Timer(1, unit="ns")
    out, tuser_raw = await axis_recv_frame(dut, timeout_cycles=200)
    await send_task

    assert out == payload, f"payload mismatch: {out!r} vs {payload!r}"
    tu = unpack_pay_tuser(tuser_raw)
    assert tu["l4_prot"] == 17, tu
    assert tu["udp_dport"] == UDP_DPORT, tu
    assert tu["from_tcp"] == 0, tu
    assert tu["port_id"] == 2, tu
    assert tu["sop_ts"] == 0x1111_2222_3333_4444, tu
    assert _ctr(dut, "o_frames_ok") == ok0 + 1


@cocotb.test()
async def test_filter_miss_dst_ip(dut):
    """Wrong dest IP → no payload, frames_ok unchanged, drop_filter++."""
    await _init(dut)
    payload = b"HELLOMD" * 2
    bad_ip = bytes.fromhex("ef010102")  # 239.1.1.2
    frame = build_udp_frame(payload, dst_ip=bad_ip)

    ok0 = _ctr(dut, "o_frames_ok")
    f0 = _ctr(dut, "o_drop_filter")
    await axis_send_frame(dut, frame, tuser=pack_tuser())
    idle = await axis_expect_idle(dut, 30)
    assert idle, "unexpected payload on filter miss"
    assert _ctr(dut, "o_frames_ok") == ok0
    assert _ctr(dut, "o_drop_filter") == f0 + 1


@cocotb.test()
async def test_non_udp_tcp(dut):
    """IP proto=6 (TCP) → drop_not_udp++."""
    await _init(dut)
    frame = build_udp_frame(b"HELLOMD" * 2, proto=6)
    n0 = _ctr(dut, "o_drop_not_udp")
    ok0 = _ctr(dut, "o_frames_ok")
    await axis_send_frame(dut, frame, tuser=pack_tuser())
    idle = await axis_expect_idle(dut, 30)
    assert idle
    assert _ctr(dut, "o_drop_not_udp") == n0 + 1
    assert _ctr(dut, "o_frames_ok") == ok0


@cocotb.test()
async def test_ip_options(dut):
    """IHL=6 → drop_opt++."""
    await _init(dut)
    frame = build_udp_frame(b"HELLOMD" * 2, ihl=6)
    o0 = _ctr(dut, "o_drop_opt")
    ok0 = _ctr(dut, "o_frames_ok")
    await axis_send_frame(dut, frame, tuser=pack_tuser())
    idle = await axis_expect_idle(dut, 30)
    assert idle
    assert _ctr(dut, "o_drop_opt") == o0 + 1
    assert _ctr(dut, "o_frames_ok") == ok0


@cocotb.test()
async def test_cfg_udp_dport_zero_and_mismatch(dut):
    """cfg_udp_dport=0 accepts any port; nonzero drops mismatch."""
    # Part A: cfg=0 accepts different port
    await _init(dut, cfg_dport=0)
    other = 0xABCD
    payload = b"HELLOMD" * 3
    frame = build_udp_frame(payload, udp_dport=other)
    ok0 = _ctr(dut, "o_frames_ok")
    send = cocotb.start_soon(axis_send_frame(dut, frame, tuser=pack_tuser()))
    await Timer(1, unit="ns")
    out, tuser_raw = await axis_recv_frame(dut, timeout_cycles=200)
    await send
    assert out == payload
    assert unpack_pay_tuser(tuser_raw)["udp_dport"] == other
    assert _ctr(dut, "o_frames_ok") == ok0 + 1

    # Part B: cfg=0x1F40 drops other port
    dut.i_cfg_udp_dport.value = UDP_DPORT
    await RisingEdge(dut.clk)
    f0 = _ctr(dut, "o_drop_filter")
    ok1 = _ctr(dut, "o_frames_ok")
    frame2 = build_udp_frame(payload, udp_dport=other)
    await axis_send_frame(dut, frame2, tuser=pack_tuser())
    idle = await axis_expect_idle(dut, 30)
    assert idle
    assert _ctr(dut, "o_drop_filter") == f0 + 1
    assert _ctr(dut, "o_frames_ok") == ok1


@cocotb.test()
async def test_s_axis_tready_always_1(dut):
    """Probe s_axis_tready == 1 on every beat of a frame."""
    await _init(dut)
    payload = b"HELLOMD" * 8
    frame = build_udp_frame(payload)
    probes: list[int] = []
    send = cocotb.start_soon(
        axis_send_frame(dut, frame, tuser=pack_tuser(), probe_tready=probes)
    )
    await Timer(1, unit="ns")
    out, _ = await axis_recv_frame(dut, timeout_cycles=300)
    await send
    assert out == payload
    assert len(probes) > 0
    assert all(r == 1 for r in probes), f"tready not always 1: {probes}"
