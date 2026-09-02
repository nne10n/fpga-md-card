# X1100 适配契约 v1（假设开工）

日期：2026-09-01  
板卡假设（用户确认，待 FDK 实测替换）：

| 项 | 假设 |
|---|---|
| 光口 | **2×10G**（口0=A，口1=B） |
| User AXIS | **32-bit**，首字节 `tdata[7:0]`，`tkeep[3:0]` |
| 时钟 | **322.265625 MHz** 单域热路径 |
| 市场 | **一张卡一个市场**；本分支默认 **深市 Binary** |
| MAC/NOE | 厂商黑盒；TB/适配层送/收 eth 或 payload AXIS |
| 建簿 | 本刀不做；仍停在 `event_t` + arb + CAM + DMA/mcast |

`event_t` / `md_pkg.sv` **逻辑字段布局保持不变**（512b 事件）。只改线侧位宽与 top 口数。

---

## 1. 目录

```
fpga-md-card/
  rtl/                 # 现有 64b 仿真金模，尽量少动
  rtl/x1100/
    ndpp_pkg.sv        # AXIS_W=32, N_INGRESS=2, MARKET=SZSE
    axis_w64_to_w32.sv # 可选：复用旧模块时的桥（优先直接改参数）
    axis_w32_to_w64.sv
    md_rx_top_x1100.sv # 2 口深市 top
  tb_x1100/            # 32b TB，或 tb/ 加参数
  docs/x1100-adapt-v1.md
```

原则：**能参数化就参数化**（`udp_strip`/`dec_bin_generic` 的 DATA_W）。改不动的桥接，不要复制整份解码器。

---

## 2. `ndpp_pkg.sv`

```systemverilog
package ndpp_pkg;
  import md_pkg::*;
  localparam int NDPP_AXIS_W      = 32;
  localparam int NDPP_AXIS_KEEP_W = 4;
  localparam int NDPP_N_PORT      = 2;   // A/B
  localparam int NDPP_P_A         = 0;
  localparam int NDPP_P_B         = 1;
  // 深市固定
  localparam exch_e NDPP_EXCH     = EXCH_SZSE;
endpackage
```

线侧 `eth_tuser_t.port_id` 只用 1 bit 有效（0/1）。

---

## 3. `md_rx_top_x1100`

```
s_axis_a / s_axis_b   # 32b eth 帧（TB 或 MAC 后）
        ↓
   udp_strip #(.W(32)) ×2
        ↓
   dec_szse_bin #(.W(32)) ×2   // 不要沪解码实例
        ↓
   arb_nway（2 路，无 TCP 第三源 stub=0）
        ↓
   sym_cam
        ↓
   mcast_eng N=1（可选）+ dma_pack
```

相对 `md_rx_top` 删除：沪口、FAST、期货 swallow、event_merge 三路（只剩 arb 后一路）。

---

## 4. 编码顺序（顶级码农）

**X0** `ndpp_pkg.sv` + 空 `md_rx_top_x1100` 能编译  
**X1** 把 `udp_strip` 参数化 `DATA_W=32/64`（默认 64 保持原 TB 45/45）  
**X2** `dec_bin_generic` / `dec_szse_bin` 同样参数化；32b TB 合成深包  
**X3** `md_rx_top_x1100`：A/B → strip → dec → arb → cam → dma  
**X4** `make sim-x1100`（或 `SIM=x1100`）全绿；**原 `make sim` 64b 仍须 45/45**

不做：真 LightningMAC、NOE、簿、N=16、沪市 bitstream。

---

## 5. 拍数提醒

10G @32b：线速一拍 32 bit，以太网头 14B ≈ 4 拍，比 64b 多一倍头拍数。解码 SAF 预算按消息长度/4 重算；深市短消息通常仍在百 ns 级。

---

## 6. 假设作废条件

FDK 实测若为 64b 或口数≠2：只改 `ndpp_pkg` 与 top 绑定，逻辑模块保留参数。
