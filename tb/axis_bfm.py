#!/usr/bin/env python3
"""AXIS-64 byte-stream helpers for cocotb (first wire byte in tdata[7:0])."""

from __future__ import annotations

from cocotb.triggers import RisingEdge


async def reset_dut(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_axis_tready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def pack_tuser(port_id: int = 0, sop_ts: int = 0) -> int:
    """eth_tuser_t packed: {port_id[2:0], sop_ts[63:0]} — MSB port_id."""
    return ((port_id & 0x7) << 64) | (sop_ts & ((1 << 64) - 1))


def unpack_pay_tuser(val: int) -> dict:
    """pay_tuser_t: {port_id[2:0], sop_ts[63:0], udp_dport[15:0], l4_prot[7:0], from_tcp}."""
    from_tcp = val & 0x1
    l4_prot = (val >> 1) & 0xFF
    udp_dport = (val >> 9) & 0xFFFF
    sop_ts = (val >> 25) & ((1 << 64) - 1)
    port_id = (val >> 89) & 0x7
    return {
        "port_id": port_id,
        "sop_ts": sop_ts,
        "udp_dport": udp_dport,
        "l4_prot": l4_prot,
        "from_tcp": from_tcp,
    }


async def axis_send_frame(dut, frame: bytes, tuser: int = 0, probe_tready=None):
    """Drive one Ethernet frame into s_axis_*. Optionally record s_axis_tready."""
    i = 0
    n = len(frame)
    first = True
    while i < n:
        chunk = frame[i : i + 8]
        data = 0
        keep = 0
        for b_i, b in enumerate(chunk):
            data |= (b & 0xFF) << (8 * b_i)
            keep |= 1 << b_i
        dut.s_axis_tdata.value = data
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if (i + len(chunk) >= n) else 0
        if first:
            dut.s_axis_tuser.value = tuser
            first = False
        while True:
            await RisingEdge(dut.clk)
            rdy = int(dut.s_axis_tready.value)
            if probe_tready is not None:
                probe_tready.append(rdy)
            if rdy == 1:
                break
        i += len(chunk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tkeep.value = 0


async def axis_recv_frame(dut, timeout_cycles: int = 5000) -> tuple[bytes, int]:
    """Collect one frame from m_axis_*. Returns (payload, tuser_int)."""
    buf = bytearray()
    tuser = 0
    cycles = 0
    got = False
    while cycles < timeout_cycles:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
            data = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            last = int(dut.m_axis_tlast.value)
            tuser = int(dut.m_axis_tuser.value)
            for b_i in range(8):
                if keep & (1 << b_i):
                    buf.append((data >> (8 * b_i)) & 0xFF)
            got = True
            if last:
                return bytes(buf), tuser
    if not got:
        return b"", 0
    raise TimeoutError(f"AXIS RX timeout after data, got {len(buf)} bytes")


async def axis_expect_idle(dut, cycles: int = 20) -> bool:
    """Return True if m_axis_tvalid stayed 0 for `cycles` clocks."""
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) == 1:
            return False
    return True
