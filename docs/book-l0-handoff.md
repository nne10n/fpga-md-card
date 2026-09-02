# L0 实现下达 — 热门 Top-10（L1 留桩）

日期：2026-09-01  
依据：`docs/book-engine-v1-szse.md`（Top-10 片上 + DDR 全量）  
板卡：X1100 假设；深市单卡；`md_rx_top_x1100`

## 做

**L0（必须仿真绿）**

1. `hot_cam`：`N_HOT=64`（参数），主机可写代码表  
2. `order_cache`：`N_ORDER=4096`，order_id 哈希，仅热门  
3. `top10`：每 hot_id 两侧各 10 档；Add/Cancel/Trade 增量修  
4. miss 热门 CAM → 事件 bypass，不改 L0  
5. 挂到 `sym_cam` 之后或 **取代大 CAM**：热门路径用 `hot_cam`；与现 `sym_cam` 关系：  
   - 简法：`ENABLE_BOOK` 时 event 先 `hot_cam`；hit 带 `hot_id` 进 book；miss bypass  
   - 现 8k `sym_cam` 可旁路关掉省资源  

**L1 桩（必须有接口，行为为空）**

```systemverilog
// 与 L0 并行：每个 ORDER/TRADE 动作推一条
l1_cmd_fifo: { op, order_id, symbol/hot_id, side, px, qty, seq, ts }
l1_cmd_ready = 1   // 桩：永远吞掉，只计数 push/drop
// 禁止真实 AXI-MM / DDR
```

## 不做

- 真 DDR / AXI-MM  
- 全市场网格  
- 沪市  
- Top-10 从 DDR 补第 11 档  

## 编码序

**L0.0** `book_pkg.sv`：op 枚举、order_slot、top level、l1_cmd_t、book_delta_t  
**L0.1** `hot_cam.sv`  
**L0.2** `order_cache` + top10 更新 + delta  
**L0.3** `l1_cmd_stub.sv`（FIFO+计数）  
**L0.4** `book_engine.sv` 顶层：fork L0/L1_stub  
**L0.5** 接入 `md_rx_top_x1100`，`ENABLE_BOOK=1`；`make sim-x1100` 加 book 用例  
**L0.6** `ENABLE_BOOK=0` 时原 45/45 与 x1100 基础测例仍绿  

## 验收

1. 热门 Add 同价累加；Cancel 回落；Trade 减至 0 删槽  
2. 非热门：L0 无 delta，bypass 有事件；L1 stub 计数仍增加（若你选择非热门也推 L1——**是，非热门只推 L1 桩**）  
3. 不反压上游  
4. 挤出第 10 档后不伪造补档  

合入 `/workspace/fpga-md-card/`。做完回 PASS 数与文件列表。
