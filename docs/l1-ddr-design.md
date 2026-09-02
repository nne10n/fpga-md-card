# L1 DDR 全量簿 — 详细设计（替换 l1_cmd_stub）

日期：2026-09-01  
现状：`l1_cmd_stub` 已吞 `l1_cmd_t` 并计数；L0 热门 Top-10 已绿  
目标：把桩换成 **可仿真、可综合** 的 L1：多 bank 调度 + AXI-MM（或行为模型）访 DDR  
板卡：Yusur NDPP X1100（**假定** User Logic 有 AXI-MM ↔ DDR；上板前用 FDK 核对）

相关：`book_pkg::l1_cmd_t`、`docs/book-engine-v1-szse.md`

---

## 1. 范围

| 做 | 不做（本细设阶段） |
|---|---|
| L1 命令队列、按 key 分 bank、保序 | 真板上调参（无 FDK 数字先行为模型） |
| DDR 上活单表 + 价位哈希档 | DDR 有序 B+/跳表全深遍历当热路径 |
| AXI-MM 读改写（RMW）状态机 | 改 L0 语义 |
| L1 完成后可选 `repair` 脉冲回 L0（接口预留） | SNAP 全市场重载工程 |
| `make sim-l1` 用 DDR 行为模型 | 一上来就综合进加密壳 |

**替换点：** `book_engine` 里实例从 `l1_cmd_stub` → `l1_ddr_engine`；`l1_cmd_t` 字段保持不变。

---

## 2. 顶层接口

```
module l1_ddr_engine
  import book_pkg::*;
#(
  parameter int N_BANK       = 4,
  parameter int CMD_FIFO_D   = 256,
  parameter int BANK_FIFO_D  = 64,
  parameter int AXI_ADDR_W   = 33,   // 按 FDK 改
  parameter int AXI_DATA_W   = 512,  // 64B 一行；按 FDK 改 256/512
  parameter int MAX_OUTSTAND = 4
)(
  input  logic clk, rst_n,         // 可与热路径同域，或独立 ddr_clk + 异步 FIFO
  input  logic clear,

  // 从 book_engine 来（同现 stub）
  input  l1_cmd_t s_cmd,
  input  logic    s_valid,
  output logic    s_ready,         // FIFO 将满时拉低；**book_engine 必须仍保证对解码不反压**
                                   // → 上层：s_ready=0 时丢 cmd 并 drop_cnt++（与「宁丢 L1」一致）

  // 遥测
  output logic [31:0] push_cnt, drop_cnt, done_cnt, err_cnt, high_watermark,

  // 可选：完成后通知 L0 纠偏（v1 可先接空）
  output logic        repair_valid,
  output book_delta_t repair_delta,

  // AXI4-MM master（上板）；仿真接 axi_ddr_model
  // ... aw/w/b/ar/r 标准口
);
```

**反压策略（冻结）：**

```
book_engine 推 L1:
  if (!l1.ready) begin
      drop_cnt++;          // 丢掉这条全量更新
      // L0 若已改，保持 L0；靠 SNAP/对账修全量
  end
```

绝不把 `l1.ready` 传到 `udp_strip`。

---

## 3. DDR 物理布局（逻辑地址图）

基址 `BASE` 由 CSR 配置（仿真默认 0）。

### 3.1 活单表 `OrderTable`

- 槽数 `N_ORDER_L1 = 1<<20`（约 100 万，参数；可 2^18）  
- 槽字节：64B 对齐（一拍 AXI 一行）

```
offset 0x00: valid:1 | side:2 | pad
offset 0x08: order_id[63:0]
offset 0x10: code[47:0] 或 symbol_hash[31:0] + flags
offset 0x18: px[63:0]
offset 0x20: qty[31:0] | seq[31:0]
offset 0x28: next_slot[31:0]   // 同 hash 链，0xFFFF_FFFF=空
offset 0x30: reserved
```

地址：

```
slot_addr = BASE_ORDER + hash_l1(order_id) * 64
```

`hash_l1`：取 oid 折到 `log2(N_ORDER_L1)` 位（可与 L0 12 位哈希不同）。  
开放寻址：冲突沿 `next_slot` 链；探深上限 `MAX_CHAIN=8`，超限 `err_cnt` 且丢该 cmd。

### 3.2 价位表 `LevelTable`

```
key = hash(code/symbol, side, px)
slot 32B/64B: valid, side, px, qty, code/sym, seq
addr = BASE_LEVEL + key * 64
```

RMW：`qty +=/- delta`，至 0 则 valid=0。  
**不做** Top-N 有序链在 DDR 热路径；全深有序由主机旁路或离线 walk。

### 3.3 Symbol 目录（可选 v1.1）

`BASE_SYM + compact_id * 32` → 统计、挂单数；首版可不做。

---

## 4. 命令到 bank 的映射

```
bank_id = hash_l1(order_id)[1:0]   // N_BANK=4；无 order_id 的异常 cmd → bank0 串行
```

同 `order_id` 永远进同一 bank → **单 bank 内 FIFO 严格保序**。  
不同 bank 并行发 AXI，提升吞吐。

每 bank：

```
bank_fifo[depth=64] → bank_fsm (RMW 状态机) → 共享 axi_arbiter
```

`axi_arbiter`：RR 选 bank；限制 `MAX_OUTSTAND`；写完成/读完成按 id 回 bank。

---

## 5. 每条 `l1_cmd_t` 的访存序列

沿用现有 op：`OP_ADD / OP_CXL / OP_TRADE`（`book_pkg`）。

### 5.1 OP_ADD

1. 读 Order 槽链，找空槽或同 `order_id`  
2. 若已存在：按重复 Add 策略（**忽略或覆盖 qty**——v1 选 **覆盖** 并打标）  
3. 写 Order 槽  
4. 读 Level(key)；`qty += cmd.qty`；写回  

AXI：典型 **2R + 2W**（有链则更多）。  
合并优化（v1.1）：Level 写缓冲。

### 5.2 OP_CXL

1. 探链找 `order_id`；找不到 → `err_orphan++`，结束  
2. 记 `px,qty,side,code`；清 Order 槽（valid=0，修链）  
3. Level `qty -=`；到 0 删档  

### 5.3 OP_TRADE

1. 找 Order；找不到 → orphan  
2. `qty -= trade_qty`；若 ≤0 清槽  
3. Level 同步减  

### 5.4 非热门（hot_id=0）

照常更新 DDR（全量意义在此）。`code[47:0]` 必须有效——解码侧带 sideband；若目前 event 只有 symbol_id，L1 用 `code` 字段（`l1_cmd_t` 已有），book_engine 推桩时已填的要核对。

---

## 6. 时钟与 CDC

| 方案 | 何时 |
|---|---|
| **A. 同 322MHz** | AXI 能跑同域（少见）或只用行为模型 |
| **B. ddr_clk 独立**（推荐上板） | `l1_cmd` 过异步 FIFO → ddr 域调度；完成计数回写用灰码/双时钟 FIFO |

细设默认：**RTL 参数 `ASYNC=1`**，仿真可 `ASYNC=0` 单时钟。

---

## 7. 与 L0 的关系

```
事件 ──┬── L0（已实现，不等 L1）
       └── L1（本模块）
```

| 情况 | 行为 |
|---|---|
| 热门 Add | L0 已改；L1 最终写 DDR |
| CXL 未命中 L0 cache | L0 可能没改；L1 找到后可发 `repair_delta`（可选，阶段 2） |
| L1 drop | 全量缺口；主机吃 bypass；置 `L1_HEALTH=degraded` |

v1 交付：**repair 口存在但可恒 0**；先保证 DDR RMW 功能正确。

---

## 8. 仿真结构

```
tb_l1/
  axi_ddr_model.sv   # 稀疏关联数组 mem[addr]=data；可配 RTT=20~100 cycles
  test_l1_add_cxl_trade.py
  test_l1_bank_parallel.py
  test_l1_drop_when_full.py
```

`make sim-l1`：不依赖真板。  
模型要能统计：平均 RMW 周期、最大 FIFO 水位。

---

## 9. 吞吐粗算（设计目标，非承诺）

假设：DDR RTT 有效 40 cycle @300MHz ≈ 133ns；每 cmd 平均 4 次往返 ≈ 0.5µs 串行。  
4 bank 理想并行 → 约 **8M cmd/s** 量级上限（理想）。  
深市开盘突发若高于此：靠 FIFO 吸收；FIFO 满则 drop。  

上板后用录包回放标定 `N_BANK / FIFO / OUTSTAND`。

---

## 10. 编码阶段（细设后的实现序，**未下令前不执行**）

**L1.0** `axi_ddr_model` + 空 `l1_ddr_engine` 接上能推 cmd  
**L1.1** 单 bank：ADD/CXL/TRADE RMW 正确  
**L1.2** 4 bank + arbiter + outstanding  
**L1.3** 替换 stub；`book_engine` 满则 drop  
**L1.4** 高水位遥测 + `make sim-l1`  
**L1.5**（可选）repair 回 L0  

---

## 11. FDK 核对清单（上板前）

1. User Logic AXI-MM 数据宽、地址宽、时钟  
2. DDR 缓存一致性 / 是否需 flush  
3. 可分配的物理地址窗与对齐  
4. 与 LightningDMA 主机口是否争用同一控制器  

任一项「无」→ L1 停在模型，产品降级仅 L0+主机旁路。

---

## 12. 一句话

**用现有 `l1_cmd_t` 喂多 bank 队列；DDR 上只做哈希活单 + 哈希档位 RMW；L1 可丢不可堵；先 `sim-l1` 行为模型，FDK 确认后再挂真 AXI。**
