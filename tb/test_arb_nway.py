#!/usr/bin/env python3
"""cocotb tests for arb_nway (M3)."""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from event_util import (
    CH_ORDER,
    CH_TRADE,
    EXCH_SZSE,
    F_FROM_TCP,
    F_GAP,
    F_WINNER_B,
    pack_event_t,
    unpack_event_t,
)


def _ctr(dut, name: str) -> int:
    return int(getattr(dut, name).value)


async def reset_arb(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for prefix in ("s_a", "s_b", "s_tcp"):
        getattr(dut, f"{prefix}_tdata").value = 0
        getattr(dut, f"{prefix}_tvalid").value = 0
        getattr(dut, f"{prefix}_tlast").value = 0
        getattr(dut, f"{prefix}_code").value = 0
    dut.m_event_tready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_arb(dut)
    await RisingEdge(dut.clk)


def _make_ev(seq: int, ch: int = CH_ORDER, flags: int = 0, ts: int = 0, px: int = 0) -> int:
    return pack_event_t(
        ts_ns=ts,
        seq=seq,
        exch=EXCH_SZSE,
        ch=ch,
        msg_type=2 if ch == CH_ORDER else 3,
        flags=flags,
        px=px,
        qty=1,
        side=1,
        order_id=seq,
    )


async def drive_port(dut, port: str, data: int, cycles_hold: int = 1):
    """Drive one event beat on s_{port}_*. Waits for tready handshake."""
    tdata = getattr(dut, f"s_{port}_tdata")
    tvalid = getattr(dut, f"s_{port}_tvalid")
    tlast = getattr(dut, f"s_{port}_tlast")
    tready = getattr(dut, f"s_{port}_tready")
    tdata.value = data
    getattr(dut, f"s_{port}_code").value = 0
    tvalid.value = 1
    tlast.value = 1
    for _ in range(1000):
        await RisingEdge(dut.clk)
        if int(tready.value) == 1:
            break
    else:
        raise TimeoutError(f"{port} never ready")
    tvalid.value = 0
    tlast.value = 0


async def drive_two_same_cycle(dut, port_a: str, data_a: int, port_b: str, data_b: int):
    """Assert two ports valid on the same cycle (A-first arb test)."""
    for port, data in ((port_a, data_a), (port_b, data_b)):
        getattr(dut, f"s_{port}_tdata").value = data
        getattr(dut, f"s_{port}_code").value = 0
        getattr(dut, f"s_{port}_tvalid").value = 1
        getattr(dut, f"s_{port}_tlast").value = 1
    # Hold until both accepted (may be sequential across cycles via skid)
    pending = {port_a, port_b}
    for _ in range(1000):
        await RisingEdge(dut.clk)
        done = set()
        for port in pending:
            if int(getattr(dut, f"s_{port}_tready").value) == 1 and int(
                getattr(dut, f"s_{port}_tvalid").value
            ) == 1:
                done.add(port)
        for port in done:
            getattr(dut, f"s_{port}_tvalid").value = 0
            getattr(dut, f"s_{port}_tlast").value = 0
            pending.discard(port)
        if not pending:
            return
    raise TimeoutError(f"ports not accepted: {pending}")


async def recv_event(dut, timeout_cycles: int = 200) -> int:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1 and int(dut.m_event_tready.value) == 1:
            return int(dut.m_event_tdata.value)
    raise TimeoutError("no event")


async def expect_no_event(dut, cycles: int = 20) -> bool:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_event_tvalid.value) == 1:
            return False
    return True


async def wait_idle(dut, cycles: int = 4):
    for _ in range(cycles):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_a_then_b_dup(dut):
    """A then B same seq → one forward, F_WINNER_B=0, dup++ on B."""
    await _init(dut)
    ev = _make_ev(seq=1, ch=CH_ORDER, ts=0x11, px=100)

    fwd0, dup0, tcp0, gap0 = _ctr(dut, "fwd"), _ctr(dut, "drop_dup"), _ctr(dut, "drop_tcp"), _ctr(dut, "gap")

    await drive_port(dut, "a", ev)
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["seq"] == 1 and e["ch"] == CH_ORDER, e
    assert (e["flags"] & F_WINNER_B) == 0, e
    assert (e["flags"] & F_FROM_TCP) == 0, e
    assert (e["flags"] & F_GAP) == 0, e

    await drive_port(dut, "b", ev)
    idle = await expect_no_event(dut, 15)
    assert idle, "B duplicate must not forward"
    await wait_idle(dut)
    assert _ctr(dut, "fwd") == fwd0 + 1
    assert _ctr(dut, "drop_dup") == dup0 + 1
    assert _ctr(dut, "drop_tcp") == tcp0
    assert _ctr(dut, "gap") == gap0


@cocotb.test()
async def test_b_first_winner_b(dut):
    """B arrives first then A same seq → forward with F_WINNER_B, A dropped."""
    await _init(dut)
    ev = _make_ev(seq=1, ch=CH_ORDER, ts=0x22, px=200)

    fwd0, dup0 = _ctr(dut, "fwd"), _ctr(dut, "drop_dup")

    await drive_port(dut, "b", ev)
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["seq"] == 1, e
    assert (e["flags"] & F_WINNER_B) == F_WINNER_B, e
    assert (e["flags"] & F_FROM_TCP) == 0, e

    await drive_port(dut, "a", ev)
    idle = await expect_no_event(dut, 15)
    assert idle, "A duplicate must not forward"
    await wait_idle(dut)
    assert _ctr(dut, "fwd") == fwd0 + 1
    assert _ctr(dut, "drop_dup") == dup0 + 1


@cocotb.test()
async def test_gap_forward(dut):
    """expect 1, inject seq 3 → forward with F_GAP, expect becomes 4."""
    await _init(dut)
    # reset leaves expect_seq[*]=1
    fwd0, gap0, dup0 = _ctr(dut, "fwd"), _ctr(dut, "gap"), _ctr(dut, "drop_dup")

    ev = _make_ev(seq=3, ch=CH_ORDER, ts=0x33, px=300)
    await drive_port(dut, "a", ev)
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["seq"] == 3, e
    assert (e["flags"] & F_GAP) == F_GAP, e
    assert (e["flags"] & F_WINNER_B) == 0, e
    await wait_idle(dut)
    assert _ctr(dut, "fwd") == fwd0 + 1
    assert _ctr(dut, "gap") == gap0 + 1
    assert _ctr(dut, "drop_dup") == dup0

    # seq 4 should match new expect (no gap)
    ev4 = _make_ev(seq=4, ch=CH_ORDER, ts=0x34, px=301)
    await drive_port(dut, "a", ev4)
    raw4 = await recv_event(dut)
    e4 = unpack_event_t(raw4)
    assert e4["seq"] == 4, e4
    assert (e4["flags"] & F_GAP) == 0, e4
    await wait_idle(dut)
    assert _ctr(dut, "gap") == gap0 + 1


@cocotb.test()
async def test_tcp_after_a_dropped(dut):
    """TCP after A already forwarded same seq → TCP dropped (drop_tcp++)."""
    await _init(dut)
    ev = _make_ev(seq=1, ch=CH_ORDER, ts=0x44, px=400)
    tcp0, dup0, fwd0 = _ctr(dut, "drop_tcp"), _ctr(dut, "drop_dup"), _ctr(dut, "fwd")

    await drive_port(dut, "a", ev)
    _ = await recv_event(dut)

    await drive_port(dut, "tcp", ev)
    idle = await expect_no_event(dut, 15)
    assert idle, "TCP duplicate must not forward"
    await wait_idle(dut)
    assert _ctr(dut, "fwd") == fwd0 + 1
    assert _ctr(dut, "drop_tcp") == tcp0 + 1
    assert _ctr(dut, "drop_dup") == dup0  # TCP uses drop_tcp, not drop_dup


@cocotb.test()
async def test_tcp_late_after_gap_dropped(dut):
    """Gap jumps expect over 2; late TCP seq=2 → seq < expect → drop."""
    await _init(dut)
    # expect=1; A seq=3 → gap, expect=4
    await drive_port(dut, "a", _make_ev(seq=3, ch=CH_ORDER, ts=1, px=1))
    raw = await recv_event(dut)
    assert (unpack_event_t(raw)["flags"] & F_GAP) == F_GAP

    tcp0 = _ctr(dut, "drop_tcp")
    await drive_port(dut, "tcp", _make_ev(seq=2, ch=CH_ORDER, ts=2, px=2))
    idle = await expect_no_event(dut, 15)
    assert idle, "late TCP into gapped hole must drop"
    await wait_idle(dut)
    assert _ctr(dut, "drop_tcp") == tcp0 + 1


@cocotb.test()
async def test_two_channels_independent(dut):
    """ch=ORDER and ch=TRADE have independent expect_seq."""
    await _init(dut)

    # ORDER seq1, TRADE seq1 both forward (separate expect)
    await drive_port(dut, "a", _make_ev(seq=1, ch=CH_ORDER, ts=10, px=10))
    r1 = await recv_event(dut)
    e1 = unpack_event_t(r1)
    assert e1["ch"] == CH_ORDER and e1["seq"] == 1, e1

    await drive_port(dut, "a", _make_ev(seq=1, ch=CH_TRADE, ts=11, px=11))
    r2 = await recv_event(dut)
    e2 = unpack_event_t(r2)
    assert e2["ch"] == CH_TRADE and e2["seq"] == 1, e2

    # ORDER seq1 again → dup; TRADE seq2 → ok
    dup0 = _ctr(dut, "drop_dup")
    await drive_port(dut, "b", _make_ev(seq=1, ch=CH_ORDER, ts=12, px=12))
    idle = await expect_no_event(dut, 15)
    assert idle
    await wait_idle(dut)
    assert _ctr(dut, "drop_dup") == dup0 + 1

    await drive_port(dut, "a", _make_ev(seq=2, ch=CH_TRADE, ts=13, px=13))
    r3 = await recv_event(dut)
    e3 = unpack_event_t(r3)
    assert e3["ch"] == CH_TRADE and e3["seq"] == 2, e3
    assert (e3["flags"] & F_GAP) == 0, e3


@cocotb.test()
async def test_same_cycle_a_wins_tie(dut):
    """A and B valid same cycle, same seq → A wins, B dup (A-first)."""
    await _init(dut)
    ev = _make_ev(seq=1, ch=CH_ORDER, ts=0x55, px=500)
    fwd0, dup0 = _ctr(dut, "fwd"), _ctr(dut, "drop_dup")

    await drive_two_same_cycle(dut, "a", ev, "b", ev)
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["seq"] == 1, e
    assert (e["flags"] & F_WINNER_B) == 0, "A must win tie"
    # allow B to be drained as dup
    await wait_idle(dut, 10)
    idle = await expect_no_event(dut, 10)
    assert idle
    assert _ctr(dut, "fwd") == fwd0 + 1
    assert _ctr(dut, "drop_dup") == dup0 + 1


@cocotb.test()
async def test_tcp_fill_in_order(dut):
    """TCP can forward when it arrives as the expected seq (with F_FROM_TCP)."""
    await _init(dut)
    # leave expect=1; TCP brings seq=1
    await drive_port(dut, "tcp", _make_ev(seq=1, ch=CH_ORDER, ts=0x66, px=600))
    raw = await recv_event(dut)
    e = unpack_event_t(raw)
    assert e["seq"] == 1, e
    assert (e["flags"] & F_FROM_TCP) == F_FROM_TCP, e
    assert (e["flags"] & F_WINNER_B) == 0, e
