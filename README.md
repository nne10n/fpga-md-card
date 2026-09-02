# FPGA 行情卡（md-card）— M0–M9

热路径：`udp_strip` → Binary/`dec_sse_fast` → `arb_nway` → `event_merge` → `sym_cam` → `mcast_eng` + `dma_pack`。  
仿真：Verilator ≥ 5.036 + cocotb。**不要**改 `rtl/md_pkg.sv` 的 packed 布局。无 TCP。

## 仿真

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

make sim            # 全套（含 top）
make sim-dec-fast   # 仅 dec_sse_fast
make sim-top        # md_rx_top 集成
```

波形：`make sim WAVES=1`（FST）。

## SSE 口 Binary vs FAST

顶层口 `cfg_sse_is_fast`（默认 **0**）：
- `0` → 端口 0/1 用 `dec_sse_bin`（现有 top 测试保持绿）
- `1` → 端口 0/1 用 `dec_sse_fast`（合成 FAST 模板）

无 `MD_HAS_FAST` ifdef；FAST 始终例化，由 CSR 选择。

## Synthetic Binary 偏移（TB，非交易所 PDF）

| off | len | field |
|-----|-----|-------|
| 0 | 2 | msg_type |
| 2 | 2 | body_len（DUT 忽略，仅用固定偏移） |
| 4 | 4 | seq |
| 8 | 6 | code ASCII（不写入 event；走 `m_code`） |
| 14 | 8 | px u64 |
| 22 | 4 | qty u32 |
| 26 | 1 | side |
| 27 | 8 | order_id |
| 35 | 1 | ch_hint（DUT 用 type LUT，可忽略） |

## Synthetic FAST 模板（`dec_sse_fast`，v1.0 写死）

| off | len | field |
|-----|-----|-------|
| 0 | 1 | PMap → `msg_type` |
| 1 | 6 | code ASCII → `m_code` |
| 7 | 4 | seq u32 BE |
| 11 | 8 | **px u64 BE**（设计稿 §3.5 写 u32；此处用 u64 对齐 `event_t.px` / Binary TB） |
| 19 | 4 | qty u32 BE |

合计 23 字节。`exch=EXCH_SSE`，`ch=CH_SNAP`（固定），`symbol_id=0`，`flags=0`，`side/order_id=0`，`ts_ns=tuser.sop_ts`。  
多字节字段网络序；AXIS 首字节 `tdata[7:0]`。

## 计数

| 模块 | 计数器 | 含义 |
|------|--------|------|
| udp_strip | drop_not_udp / drop_opt / drop_filter / frames_ok | 见 M1 |
| dec_* | msg_ok / msg_bad | 成功事件 / 短帧·溢出·反压丢弃 |
