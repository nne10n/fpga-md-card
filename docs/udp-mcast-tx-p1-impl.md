# UDP 组播 TX P1 实现备忘（参考）

**参考 only。** 与 `docs/udp-mcast-tx-design.md`（FROZEN）或 `docs/udp-mcast-tx-stream-contract.md` 冲突时，那两份胜。

P1：在现有 `mcast_eng` 上演进，保持 event AXIS + 符号过滤 + token bucket，让 `make sim-mcast` / `sim-top` / `sim-x1100` 继续绿。

---

## 已选路径

薄适配：`s_event_*`（64B `event_t`）→ 内部 UDP payload + SOP meta，再走 lock → gate → fill → TX。不拆第二套外部 `s_udp` AXIS（避免双流与未接端口 X）。

同钟，不例化 `tx_afifo`。`rtl/ip-catalog/` 只是 CDC 骨架。

Top 端口名保持 `clk`/`rst_n`/`cfg_mcast_*`；新 CSR/meta 用默认值，旧例化不用改接线。

---

## 端口默认（P1）

| 输入 | 默认 | 说明 |
|---|---|---|
| `cfg_ttl_default` | 1 | 0 也当 1 |
| `cfg_map_en` | **1** | 正式路径：DA 总是 RFC1112；`0` 也不把用户 MAC 当 DA、不因 MAC 不一致丢包 |
| `cfg_mtu_pay` | 1472 | 0 → 1472 |
| `i_s_udp_meta_valid` | 0 | 全走 CSR |

`cfg_dst_mac` 仍接在 top 上（CSR 兼容脚）。任何 `map_en` 值都不进 DA，也不作为丢包条件。

---

## FSM

两态 `ST_IDLE` / `ST_TX`，三段式 `cs_state` / `ns_state`。单 beat event 在 IDLE 完成 lock+gate+填缓冲，下一拍 TX。

MAX_PAY=64，帧 ≤ 106B。

---

## 不要做（P1）

N>1、IGMP、loopback、十档内容、用户 MAC 上线、把 mcast/dma ready AND 回 CAM。
