#!/usr/bin/env python3
"""Shared event_t pack/unpack helpers mirroring md_pkg.sv (pad at MSBs)."""

from __future__ import annotations

# ch_e / exch_e from md_pkg
CH_SNAP = 0
CH_ORDER = 1
CH_TRADE = 2
CH_INDEX = 3
CH_QUEUE = 4
CH_STATE = 5
CH_OTHER = 15

EXCH_SSE = 0
EXCH_SZSE = 1

F_WINNER_B = 0x01
F_GAP = 0x02
F_FCS_LATE = 0x04
F_CAM_MISS = 0x08
F_FROM_TCP = 0x10


def pack_event_t(
    *,
    ts_ns: int = 0,
    seq: int = 0,
    symbol_id: int = 0,
    exch: int = EXCH_SZSE,
    ch: int = 0,
    msg_type: int = 0,
    flags: int = 0,
    px: int = 0,
    qty: int = 0,
    side: int = 0,
    order_id: int = 0,
    level: int = 0,
    queue_pos: int = 0,
    raw_ptr: int = 0,
    pad: int = 0,
) -> int:
    """Pack event_t matching md_pkg field order (pad = MSBs).

    High → low: pad[183:0], raw_ptr[15:0], queue_pos[7:0], level[7:0],
    order_id[63:0], side[1:0], qty[31:0], px[63:0], flags[7:0], msg_type[7:0],
    ch[3:0], exch[1:0], symbol_id[15:0], seq[31:0], ts_ns[63:0]
    """
    v = 0
    v |= (pad & ((1 << 184) - 1)) << 328
    v |= (raw_ptr & 0xFFFF) << 312
    v |= (queue_pos & 0xFF) << 304
    v |= (level & 0xFF) << 296
    v |= (order_id & ((1 << 64) - 1)) << 232
    v |= (side & 0x3) << 230
    v |= (qty & 0xFFFFFFFF) << 198
    v |= (px & ((1 << 64) - 1)) << 134
    v |= (flags & 0xFF) << 126
    v |= (msg_type & 0xFF) << 118
    v |= (ch & 0xF) << 114
    v |= (exch & 0x3) << 112
    v |= (symbol_id & 0xFFFF) << 96
    v |= (seq & 0xFFFFFFFF) << 64
    v |= ts_ns & ((1 << 64) - 1)
    return v


def unpack_event_t(v: int) -> dict:
    """Slice individual fields from a 512-bit event_t value."""
    return {
        "ts_ns": v & ((1 << 64) - 1),
        "seq": (v >> 64) & 0xFFFFFFFF,
        "symbol_id": (v >> 96) & 0xFFFF,
        "exch": (v >> 112) & 0x3,
        "ch": (v >> 114) & 0xF,
        "msg_type": (v >> 118) & 0xFF,
        "flags": (v >> 126) & 0xFF,
        "px": (v >> 134) & ((1 << 64) - 1),
        "qty": (v >> 198) & 0xFFFFFFFF,
        "side": (v >> 230) & 0x3,
        "order_id": (v >> 232) & ((1 << 64) - 1),
        "level": (v >> 296) & 0xFF,
        "queue_pos": (v >> 304) & 0xFF,
        "raw_ptr": (v >> 312) & 0xFFFF,
    }
