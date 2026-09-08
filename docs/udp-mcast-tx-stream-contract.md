# UDP 组播 TX 流契约

与 `docs/udp-mcast-tx-design.md`（FROZEN）配套。冲突时以 FROZEN 为准。

N=1。payload 仿真默认 64B（`event_t`）。无 VLAN / FCS / ARP。

---

## 1. 时钟复位

热路径单域。DUT 端口可继续用 `clk` / `rst_n`（与 top 一致），模块内按 `sys_clk` / `sys_rst_n` 语义：异步低有效复位。

---

## 2. 生产者（Role A）

现网 / 仿真入口仍是 event AXIS-512（单 beat `event_t`，`tlast=1`）：

```
s_event_tdata[511:0]
s_event_tvalid
s_event_tlast
s_event_tready      // ≡ 1
```

内部适配为 UDP payload + SOP meta。可选 SOP meta（默认 0 = 用 CSR）：

```
i_s_udp_meta_valid
i_s_udp_dst_ip / src_ip
i_s_udp_sport / dport
i_s_udp_ttl
i_s_udp_payload_len
i_s_udp_is_mcast
```

- meta 覆盖 CSR；字段 0 表示沿用 CSR（ttl 除外：0 一律当 1）。
- `s_udp` 语义：只含 UDP payload，不含 MAC/VLAN。
- 实际字节数必须等于 locked `payload_len`（event 路径 = 64）。

---

## 3. CSR 慢路径

| 端口 | 角色 |
|---|---|
| `cfg_src_mac` | 线侧 SA |
| `cfg_src_ip` | 默认 SIP |
| `cfg_dst_ip` | 默认 DIP |
| `cfg_udp_sport` / `cfg_udp_dport` | 默认端口 |
| `cfg_ttl_default` | 默认 TTL；写 0 → 1 |
| `cfg_map_en` | 默认 **1**。见 FROZEN map gate |
| `cfg_mtu_pay` | payload 上限；0 → 1472 |
| `cfg_dst_mac` | **不是** 线侧 DA。`map_en=0` 时必须等于 RFC1112(locked DIP) |
| `o_stat_dst_mac` | RFC1112(`cfg_dst_ip`) 只读镜像 |

过滤 / token bucket（`filt_*`、`cfg_ch_mask`、`cfg_period`/`cfg_refill`）仍在 lock 之前，属业务过滤，不是 UDP 契约 gate。

---

## 4. 出站 AXIS

64-bit，首字节 `tdata[7:0]`，`tkeep`/`tvalid`/`tready`/`tlast`。以太网 + IPv4 + UDP，无 VLAN/FCS。

派生：

- DA = RFC1112(locked DIP)，永不使用用户 MAC
- `IP total = 20 + 8 + payload_len`
- `UDP length = 8 + payload_len`
- UDP checksum = 0
- IPv4 header checksum 按实际 TTL/长度/地址计算

---

## 5. Gate 与计数

Lock 之后、组包之前：

1. 224/4 + `is_mcast`
2. SA 非组
3. `payload_len` 与实际长度一致，且 `0 < len ≤ mtu_pay`（且 ≤ 实现 MAX_PAY）
4. map（FROZEN：`map_en=1` 通过；`map_en=0` 要求 CSR MAC == RFC1112(dip)）

失败：`o_dbg_err_sticky`、`o_drop_gate++`、`o_nosend++`，不发帧，`tready` 仍为 1。

业务丢：`drop_filt` / `drop_rate`（忙或 token）。成功：`tx_ok`。

---

## 6. Top 扇出

`mcast_eng` 与 `dma_pack` 各自 `tready≡1`，内部满/忙则丢。

```
md_rx_top:          cam_tready  = 1'b1
md_rx_top_x1100:    post_tready = 1'b1
```

禁止把两路 ready AND 回去，也禁止把 dma ready 当作扇出 ready。
