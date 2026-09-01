# 行情卡 §2 模块划分与模块设计 v1

日期：2026-09-01  
读者：顶级码农（编码）  
板卡：Alveo UL3524，热路径 322.265625 MHz 单域  
线侧约定：**与 `fpga-order-tcp-tx` 相同** — AXI-Stream 64-bit，首字节 `tdata[7:0]`，有 `tkeep/tvalid/tready/tlast`。  
本工程是**新仓库**，不要改 TCP 发单核。TCP 发单是报单/风控卡的事。

契约源文件：`/workspace/fpga-md-card/rtl/md_pkg.sv`  
产品规格：`/workspace/fpga-md-card/spec-v1.md`

仿真栈：Verilator ≥ 5.036 + cocotb，`make sim` 零交互。

---

## 0. 你写什么 / 不写什么

| 写（RTL） | 不写（stub 或买 IP） |
|---|---|
| `udp_strip` | 真实 MAC/PCS/GTF（TB 直接打 AXIS 帧） |
| `arb_nway` | 真实 TCP TOE（v1 回补口可从 TB 注入已剥 TCP 的 payload） |
| `dec_szse_bin` | 真实 QDMA / 板级 BSP |
| `dec_sse_bin` | 期货解码 |
| `dec_sse_fast`（第二优先级） | 全深订单簿 |
| `sym_cam` | L1 矩阵 |
| `event_merge` + `event_bus` | 16 份 `mcast_eng` 复制（先做 N=1，参数化 N） |
| `mcast_eng` | |
| `dma_pack`（AXIS 到 TB，不是真 PCIe） | |
| `telem` 计数器 | |
| `md_rx_top` | |

内部预算（含 stub MAC 1 拍对齐，不含客户口排队）：深 SOP→`event_t` < 300 ns（≈96 拍 @322），沪 Binary 同档；沪 FAST < 500 ns（≈160 拍）。对账用软件金模型，**禁止 STAC-T0**。

---

## 1. 层次

```
md_rx_top
├─ ts_counter            # 1PPS 清零的 ns 计数，给 SOP 打戳
├─ udp_strip  x4         # Q0.0–Q0.3 组播入
├─ tcp_pay_stub x2       # Q0.4/Q0.5：TB 已是 TCP payload AXIS，只打 tuser
├─ swallow x2            # Q0.6/Q0.7 期货，计数后丢
├─ arb_nway  sse         # 沪 A/B（+ TCP 作为第三源，from_tcp=1）
├─ arb_nway  szse        # 深 A/B（+ TCP 回补）
├─ dec_szse_bin
├─ dec_sse_fast          # 可 `ifdef` 关掉，先合 Binary
├─ dec_sse_bin
├─ event_merge           # 三路 event → 一路，RR，不堵任何一路超过 2 拍
├─ sym_cam
├─ event_bus             # 广播：硬核 + 软核，ready 是 AND；硬核不得反压（见下）
│    ├─ mcast_eng x N    # 参数 N_CLIENT，v1 仿真 N=1 再 16
│    └─ dma_pack
└─ telem
```

**反压规则（必须遵守）：**  
热路径 `event_bus` 对解码器 **永不反压**。`mcast_eng` 限速丢包；`dma_pack` 用浅 FIFO，满则丢并计数。`udp_strip` 对 TB/MAC `tready=1`（切穿）。只有 CSR 写口可以停。

---

## 2. 公共接口

### 2.1 线侧 eth AXIS（每口）

```
s_axis_tdata[63:0]
s_axis_tkeep[7:0]
s_axis_tvalid
s_axis_tlast
s_axis_tready      // 生产=1；仿真允许 TB 随机 pause 但模块不得依赖 pause 做正确性
s_axis_tuser       // eth_tuser_t：port_id 在 top 绑死；sop_ts 由 ts_counter 在 SOP 采样
```

无 MAC：TB 送 Ethernet 帧，FCS 可省略（tlast 即帧结束）。`F_FCS_LATE` v1 恒 0，留位。

### 2.2 payload AXIS（剥头后）

`tdata/tkeep/tvalid/tready/tlast` 同 64b。  
`tuser = pay_tuser_t`。payload 从 UDP/TCP 数据第一字节开始。

### 2.3 event AXIS

```
m_event_tdata[511:0]   // event_t 位布局见 md_pkg.sv
m_event_tvalid
m_event_tready         // 见反压规则：下行必须常 1 或模块内丢
m_event_tlast          // 单 beat 事件恒 1
```

快照 10 档：**一条 packed beat**，`level=0`，`px/qty` 放买一；其余 9 档暂不展开（v1.1 用 10 beat 模式，参数 `SNAP_BEATS`）。先把切穿跑通。

### 2.4 时钟复位

```
clk     // 热路径
rst_n   // 同步释放，异步断言
```

v1 无 250 MHz PCIe 域。`dma_pack` 出 AXIS 仍在 `clk`，TB 当「假主机」。

---

## 3. 逐模块

### 3.1 `udp_strip`

**功能：** 切穿解析 Eth/IPv4/UDP，输出 payload AXIS。  
**拍数预算：** 识别 Ethertype+IP+UDP 头 ≤ 6 拍（14+20+8 字节 @8B/拍 ≈ 6），之后 SOP 即可向下游吐 payload。  
**过滤：** `cfg_dst_mac`（可广播/组播）、`cfg_dst_ip`、`cfg_udp_dport`（0=不过滤端口）。不匹配整帧丢。  
**不做：** IPv4 校验和（v1 可选关）、UDP 校验和（组播常为 0）、IP options（有 options 丢帧并计数）。  
**输出：** payload `tuser.l4_prot=17`。

端口：1× eth AXIS in，1× pay AXIS out，cfg 静态，计数 `drop_not_udp/drop_opt/frames_ok`。

### 3.2 `arb_nway`

**实例：** `u_arb_sse`、`u_arb_szse`。  
**输入：** 2 路必选（A/B）+ 1 路可选 TCP 回补。  
**键：** `{channel_id, seq}`。`channel_id` v1 用 `tuser.udp_dport` 低 8 位；seq 在 **解码之后** 才有 —— 因此 arb 放在解码**之前**只能做「先到先过 + 端到端帧哈希去重」，放在解码**之后**才能按交易所序号。

**决定：arb 放在解码之后、CAM 之前。** 层次改成：

```
udp_strip → dec_* → arb_nway → event_merge → sym_cam → bus
```

A/B 两路各自完整解码（资源换正确性）。arb 看 `event_t.seq` + `event_t.ch` + `exch`。

**状态：** 每 `ch` 一个 `expect_seq`（RAM 深度 16 足够）。  
**规则：**

1. `seq == expect` → 转发，`expect++`，`F_WINNER_B` 按源置位  
2. `seq < expect` → 丢（重复）  
3. `seq > expect` → **仍转发**，置 `F_GAP`，`expect = seq+1`（切穿不堵；回补流若稍后到达且 seq 已过则丢）  
4. TCP 源置 `F_FROM_TCP`；若该 seq 已从组播赢过，丢 TCP

**延迟：** 1–2 拍。BRAM 读 1 拍则转发延迟 2。

参数：`N_CH=16`。

### 3.3 `dec_szse_bin`  **第一优先实现**

深 Binary 是定长切穿。交易所字段偏移 **禁止写死官方 PDF**（版权/版本）。做成 **可配字段表**：

```
cfg_off_type   // msg_type 字节偏移
cfg_off_seq
cfg_off_code   // 6 字节证券代码 ASCII
cfg_off_px
cfg_off_qty
cfg_off_side
cfg_off_oid
cfg_len_hdr    // 最小头长度，小于此不切
```

TB 用**合成格式**（文档化，见 §6），默认偏移写在 TB/参数里。上线再换成 V5 表。

**切穿：** 字节计数 ≥ `max(cfg_len_hdr, type+seq 结束)` 即可出 `event_t`（后续字段随 beat 填，未到的字段 0，`tvalid` 等到需要的最后字段或 `tlast`）。v1 允许 **store-and-forward 单消息**（深市单条通常几百 B，@8B/拍几十拍，仍在 300 ns 预算内若消息 < 240B）。优先正确：消息 `tlast` 后 1 拍出 event。若超预算再改切穿。

**映射：** `exch=EXCH_SZSE`；`ch` 由 `msg_type` 查 16 项 LUT（CSR）。`px` 按 10⁻⁴ 元，TB 合成已是该单位。

### 3.4 `dec_sse_bin`

同 `dec_szse_bin` 结构，默认 `exch=EXCH_SSE`。独立字段表。可复用同一 `dec_bin_generic` 参数化实例。

建议 RTL：`dec_bin_generic.sv` + 两个 wrapper。

### 3.5 `dec_sse_fast`

第二优先。v1.0：**一个写死的模板**（合成 FAST：PMap 1 字节 + 6 字节代码 + seq u32 + px u32 + qty u32），能出 `event_t` 即可。  
v1.1：主机加载模板。  
未实现前 top 里 `ifdef MD_HAS_FAST` 绑 0。

### 3.6 `event_merge`

3 路 `event_t` RR。每路 2 深 FIFO。下游 `tready` 在 CAM 常 1。  
公平：连续同一源最多 4 拍，避免深市突发饿死沪市。

### 3.7 `sym_cam`

8192× `{valid, key[55:0], symbol_id[15:0]}`。  
`key = {exch[1:0], code_ascii[47:0]}`（6 字符）。  
查找：哈希 `key[12:0] ^ key[25:13] ^ key[38:26]` 开放寻址，最多探 4；探失败 = miss。

双缓冲：`bank_sel` CSR，写非活跃 bank，`swap` 脉冲后 1 拍切。切时查找用旧 bank。

miss：`cfg_pass_miss=0`（默认）丢；=1 则 `symbol_id=0` 且 `F_CAM_MISS` 转发（仅软核调试）。

端口：event in/out；写口 `cam_we/addr/key/id/valid`。

### 3.8 `mcast_eng`

参数 `CLIENT_ID`。  
查每户过滤：1024×16b ID 表（或 bit RAM 8192）。v1 用 **8192-bit 使能向量**，下标=`symbol_id`，最简单。  
再与 `ch_mask[7:0]` 与。  
Token bucket：`rate_tokens` 每 `cfg_period` 拍加 `cfg_refill`，每发一 event 减 1，0 则丢。  
出站：把 `event_t` 打成 UDP 载荷（64b AXIS 以太网帧）。模板头 CSR：src/dst MAC、VLAN 可选、IPv4、UDP。v1 **预计算 IP/UDP 长度以外的头**；长度和 checksum 可简化：UDP csum=0，IP csum 组合逻辑算。  
store-and-forward 一帧（64B payload + 头 < 128B）可接受。

`tready` 对 event_bus：**恒 1**（内部丢）。

### 3.9 `dma_pack`

把 `event_t` 再打成 64b AXIS（8 beat）给 TB。FIFO 32 深，满丢。这是软核模型，不是 QDMA。

### 3.10 `telem`

32-bit 饱和计数，CSR 只读：每口帧、arb 转发/重复/缺口、解码 ok/bad、CAM hit/miss、mcast 发/丢、dma 发/丢。

### 3.11 `md_rx_top`

绑 Q0.0–0.3 → strip → 按口进对应 decoder：  
- 0.0/0.1 → `dec_sse_*`（CSR `sse_is_fast` 选 fast 或 bin，默认 bin）  
- 0.2/0.3 → `dec_szse_bin`  
两路沪解码实例，两路深解码实例（A/B 独立），然后 arb。

期货口 swallow。

出：`m_mcast_axis`（N=1 仿真）、`m_dma_axis`。

---

## 4. 编码顺序（必须按此合入）

**M0** `md_pkg.sv`（已给）+ 空 `md_rx_top` 能 `make sim` 出 0-test skip  
**M1** `udp_strip` + TB 合成 UDP 帧  
**M2** `dec_bin_generic` + `dec_szse_bin` wrapper，单口无 arb  
**M3** `arb_nway` A/B 乱序/重复/缺口  
**M4** `sym_cam` + miss 丢  
**M5** `mcast_eng` N=1，TB 收 UDP 对拍 `event_t`  
**M6** `dma_pack`  
**M7** `dec_sse_bin` 复用 generic  
**M8** `md_rx_top` 四口串联  
**M9** `dec_sse_fast` 合成模板（可平行，不挡 M8）

每步 `make sim` 全绿才能下一步。

---

## 5. 目录

```
fpga-md-card/
  rtl/md_pkg.sv          # 已有，勿改位布局除非和架构师说
  rtl/udp_strip.sv
  rtl/dec_bin_generic.sv
  rtl/arb_nway.sv
  rtl/sym_cam.sv
  rtl/event_merge.sv
  rtl/mcast_eng.sv
  rtl/dma_pack.sv
  rtl/telem.sv
  rtl/md_rx_top.sv
  tb/                    # cocotb
  docs/module-design-v1.md
  Makefile
```

风格对齐 `fpga-order-tcp-tx`：`timescale 1ns/1ps`，`import md_pkg::*`，参数大写，不写 MAC。

---

## 6. TB 合成 Binary（深）

网络序。一消息：

| off | len | 字段 |
|---|---|---|
| 0 | 2 | `msg_type` |
| 2 | 2 | `body_len`（后续字节数） |
| 4 | 4 | `seq` |
| 8 | 6 | 证券代码 ASCII，右空格 |
| 14 | 8 | `px` u64，10⁻⁴ 元 |
| 22 | 4 | `qty` u32 |
| 26 | 1 | `side` 1买 2卖 |
| 27 | 8 | `order_id` |
| 35 | 1 | `ch_hint` 对应 `ch_e` |

`msg_type` LUT 默认：1→SNAP 2→ORDER 3→TRADE。  
UDP：任意合法 IPv4 组播，dport=0x1F40。A/B 两帧相同 seq 只应出一 event。

---

## 7. 给综合的备注（现在不用跑 Vivado）

- 目标器件 `xcvu2p-fsvj2104-3-e`，但 v1 以仿真为准  
- `sym_cam` 用 BRAM，不要 LUTRAM 8192  
- 热路径不加跨时钟 FIFO
