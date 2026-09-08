# UDP 组播 TX 设计（FROZEN）

状态：**冻结**。与 `docs/udp-mcast-tx-stream-contract.md` 冲突时以二者为准；`docs/udp-mcast-tx-p1-impl.md` 只是实现备忘。

相对原 §4.3 迁移期，本修订废弃 mismatch sticky；线侧 DA 永远 RFC1112(dip)，cfg_map_en 仅作兼容/遥测保留（默认 1）。

修订（相对原 §4.3 迁移期）：废弃 map_en=0 时因 CSR MAC≠RFC1112(dip) 而 sticky 不发的路径；线侧 Eth DA 永远 RFC1112(dip)，用户 MAC 不上线；cfg_map_en 默认 1，仅作兼容/遥测保留。

范围：N=1 硬核 `mcast_eng` 出站。不做 N>1、IGMP、loopback、十档业务扩展。无 ARP。正式路径不接受用户提供的线侧 DA。

---

## 1. 三分法

| 层 | 内容 | 禁止 |
|---|---|---|
| **CSR 慢路径** | `cfg_src_mac` / `cfg_src_ip`；默认 DIP / UDP sport/dport；`ttl_default=1`；`map_en` 默认 **1**；`mtu_pay`。`cfg_dst_mac` 只读镜像，**不是** 组包 DA | CSR 写用户 MAC 当正式 DA；ARP；用用户 MAC 与线侧 DA 比对来丢包 |
| **AXIS + SOP meta** | `s_udp_*` 只带 UDP payload；meta = dst/src_ip、sport/dport、ttl、payload_len、`is_mcast` | meta 上带 MAC / VLAN |
| **核内派生** | DA = RFC1112(dip)；IPv4/UDP 长度；IPv4 header checksum；UDP checksum = 0 | 把 CSR `dst_mac` 打到线侧 |

P1 仿真可将 `event_t`（64B）适配成一帧 UDP payload；meta 未给时用 CSR 默认。

---

## 2. 处理顺序

1. **Lock meta**（SOP）：meta 覆盖 CSR 默认；`ttl==0`（含 CSR 写 0）当作 1。
2. **Gate**：224/4、SA 非组、长度匹配、**map**、MTU。失败 → sticky + drop/no-send，**不反压**。
3. **Fill headers**：Eth DA = RFC1112(locked DIP)；IP/UDP 长度与 IPv4 csum。
4. **Egress**：AXIS-64 以太网帧，无 VLAN、无 FCS。

---

## 3. map gate（FROZEN）

禁止 `!map_en || dip==cfg_dst_ip`。禁止把用户 `cfg_dst_mac` 当作 DA 来源。禁止 `map_en=0` 时因 `cfg_dst_mac != RFC1112(dip)` 而 sticky/丢包。

| `map_en` | 行为 |
|---|---|
| **1（默认）** | Eth DA **始终** RFC1112(dip)。CSR `dst_mac` 不进线侧。map 项通过。 |
| **0** | DA **仍然** RFC1112(dip)。用户 MAC 不上线。不因 CSR MAC 与派生 DA 不一致而 gate fail。 |

`o_stat_dst_mac` = RFC1112(CSR `cfg_dst_ip`)，只读镜像。

---

## 4. Role A（反压）

- 每个消费者 **ready ≡ 1**；忙则内部丢并计数。
- 事件总线扇出 **tready 恒 1**。
- **禁止** `mcast_ready && dma_ready`（或把 dma ready 回灌）去反压 CAM/解码。
- `md_rx_top`：`cam_tready = 1'b1`。
- `md_rx_top_x1100`：`post_tready = 1'b1`。

失败：sticky + drop / no-send 计数。不把 backpressure 打进生产者。

---

## 5. 其它硬规则

- RFC1112：`DA = {24'h01_00_5E, 1'b0, dip[22:0]}`。
- 224/4：DIP `[31:28]==4'hE` 且 `is_mcast`。
- SA 非组：SIP `[31:28]!=4'hE`。
- 家规：`sys_clk` / `sys_rst_n` 语义（本模块可 alias 到现有 `clk`/`rst_n`）、三段式 FSM、`i_`/`o_`/`w_`/`r_`。
- 同钟：不要例化 `tx_afifo`。`rtl/ip-catalog/tx_afifo` 只给真 CDC。
