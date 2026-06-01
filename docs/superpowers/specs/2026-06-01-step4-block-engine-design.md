# Step 4 — W4A8 Transformer Block Engine 设计 spec

> 状态：设计冻结（2026-06-01）。本 spec 的交付边界是 **XSIM bit-exact**；Vivado 综合实现与上板由用户手动完成。
>
> 上游文档：`project_goal.md`（目标/规格）、`tmp.md`（实时进展）。前置基线：Step 3b 已板上 `FULL BLOCK PASS (0/128)`，软件块 `w4a8_run_full_block` + Python golden `run_full_block_py` 为 bit-exact 参考。

## 1. 目标与范围

把 Step 3b 中仍在 CPU 软件执行的全部非 Linear 算子（LayerNorm、requant、attention 点积、softmax、weighted-sum、GELU、residual）硬件化，连同已在 FPGA 的 4 个 Linear 一起，由一个 **block controller FSM** 在 FPGA 内部串联，使 CPU 只需：写 `hidden_in[128]` → 启动 → 轮询 done → 读 `block_out[128]`。

### 唯一硬验收 gate

- XSIM 下新 testbench `tb_w4a8_block.v` 跑完整 block，`BLOCK_OUT[128]` 对 `block_out_golden[128]` **bit-exact PASS (0/128 mismatches)**。

### 非目标 / 顺带项

- 9 层 Linear TB（`tb_w4a8_engine.v`）：因复用同一 `w4a8_core`，跑一遍仅作"core 未被破坏"的回归 sanity，**不是本步目标**。
- 单层 Linear speedup 展示点（Step 1/2）是否保留到结课 UART，属展示内容取舍，不在本 spec 范围；block engine 做成 linear engine 超集后旧 Linear MMIO 顺带保留，留用与否结课时再定。
- TinyLM 文本生成：扩展项，不在本步。

## 2. 架构与模块划分（方案 A：模块化专用单元）

新顶层 `w4a8_block_engine` **drop-in 替换** `w4a8_linear_engine`：同 ICB 引脚、同基址 `0x1004_1000`，是现有 linear engine 的超集（旧 `0x000–0x7FC` 寄存器全保留）。

```
w4a8_block_engine
├── w4a8_icb              扩展寄存器文件（旧 Linear MMIO + 新 BLOCK_* + HIDDEN_IN/BLOCK_OUT 缓冲 + SCRATCH 调试口）
├── w4a8_resident_wmem    不变（resident INT4 权重，16 bank BRAM）
├── w4a8_resident_smem    不变（resident INT16 scale BRAM）
├── w4a8_core             不变（已验证的 16-row Linear FSM）
├── w4a8_block_ctrl  [新]  顶层 block FSM：串联 11 个 stage，内部触发 core 4 次
├── w4a8_ln_unit     [新]  LayerNorm（mean / var / isqrt / diff*gamma ÷ sigma + beta）
├── w4a8_attn_unit   [新]  Q·K 点积(2 pos) + 概率·V 加权和
├── w4a8_softmax_unit[新]  max / 减 / exp LUT / Σ / ÷ sum_exp → Q0.15
├── w4a8_gelu_unit   [新]  requant + 256-entry LUT 查表
├── w4a8_residual_unit[新] res1=(hidden<<lift)+proj；block_out=(res1>>trim)+ffn_dn
├── w4a8_requant     [新库] round_shift + sat8（多处复用）
├── w4a8_idiv        [新库] 多周期有符号整数除法（round-to-nearest ties-up，64-bit）
├── w4a8_isqrt       [新库] 多周期整数开方 floor（64-bit 输入）
└── block_scratch    [新]  中间向量存储（res1 INT32[128] + 注意力 Q/K/V/attn 工作区）
```

### 2.1 关键结构决策

1. **`act_buf` / `y_buf` 访问 mux**：现状只有 CPU 经 ICB 读写。block 运行时由 `w4a8_block_ctrl` 接管——向量单元把 INT8 结果写进 `act_buf` 喂 core，从 `y_buf` 读 core 的 INT32 输出；block 空闲时归 CPU 调试口。`w4a8_core` 自身的 act/y 端口不动，mux 在 icb 与 ctrl 之间。

2. **常量预初始化**（沿用 `$readmemh` 套路，不占 ILM）：LN1/LN2 gamma(INT8[128])/beta(INT16[128])、`gelu_lut`(INT8[256])、`exp_lut`(INT16[17])、假 KV `kv_prev_k/v`(INT8[128])、10 个 shift 常量。Python 生成器同时吐出 firmware header（已有）+ RTL init 文件，保证 tb/板子常量与 Python golden 完全一致。

3. **shift 常量**烧成 `w4a8_block_consts.vh` 里的 localparam（不走 MMIO；retune 则重生成 + 重综合，与权重同套路）。

### 2.2 共享库模块

- `w4a8_idiv`：有符号整数除法，输出 round-to-nearest ties-up，语义严格匹配 Python `round_div_signed`（`den>0`；`num>=0: (num+den/2)/den`；`num<0: -((-num+den/2)/den)`）。多周期串行（非恢复或恢复式），位宽 ≥ 48-bit numerator / 32-bit denominator。`w4a8_ln_unit`、`w4a8_softmax_unit` 各实例化一份（单元顺序激活，无需仲裁）。
- `w4a8_isqrt`：floor(sqrt(n))，匹配 Python `isqrt_floor`（结果与 `math.isqrt` 一致）。多周期串行，输入位宽 ≥ 64-bit，输出 ≥ 32-bit。
- `w4a8_requant`：`round_shift(v, s)` 后 `sat8`，匹配 Python `round_shift`（`s<=0: v<<(-s)`；`s>0, v>=0: (v+half)>>s`；`v<0: -((-v+half)>>s)`，`half=1<<(s-1)`）。组合或 1-cycle，shift 为常量参数。

## 3. 数据流（`w4a8_block_ctrl` 的 stage 序列）

严格对齐 `tools/w4a8_block_full.py::run_full_block_py`。向量单元一次只激活一个；core 复用，每次按对应 layer descriptor 触发。

| # | stage | 单元 | 运算 | 落点 |
|---|---|---|---|---|
| 1 | LN1 | ln_unit | HIDDEN_IN INT8[128] 符号扩展→ln1_out INT32[128]，`>>S_LN1_OUT` sat8 | act_buf(32w) |
| 2 | qkv | core(id0, M=384 N=128) | act_buf→y_buf INT32[384] | y_buf |
| 3 | split+requant | requant | y_buf 拆 Q[0:128]/K[128:256]/V[256:384]，各 `>>S_Q/K/V_REQUANT` sat8 | scratch Q/K/V INT8[128]×3 |
| 4 | attention | attn_unit + softmax_unit | K_seq=[kv_prev_k, K1_q8]，V_seq=[kv_prev_v, V1_q8]；scores[t]=Σ_d Q[d]·K_seq[t][d]，`>>S_SCORES` sat8；softmax→probs_q15[2]；attn[d]=Σ_t probs[t]·V_seq[t][d]，`round_shift(·,15)` 再 `>>S_ATTN_OUT` sat8 | act_buf(32w) |
| 5 | proj | core(id1, M=128 N=128) | act_buf→y_buf INT32[128] | y_buf |
| 6 | residual1 | residual_unit | `(hidden_in[i]<<S_LIFT)+proj_out[i]` | **scratch res1 INT32[128]（持久）** |
| 7 | LN2 | ln_unit | res1 INT32[128]→ln2_out，`>>S_LN2_OUT` sat8 | act_buf(32w) |
| 8 | ffn_up | core(id2, M=256 N=128) | act_buf→y_buf INT32[256] | y_buf |
| 9 | GELU | gelu_unit | `>>S_FFN_UP_OUT` sat8 → 256-entry LUT 查表 | act_buf(64w) |
| 10 | ffn_down | core(id3, M=128 N=256) | act_buf→y_buf INT32[128] | y_buf |
| 11 | residual2 | residual_unit | `(res1[i]>>S_BLK_TRIM)+ffn_dn_out[i]` | BLOCK_OUT INT32[128] |
| — | done | ctrl | latch BLOCK_CNT，置 BLOCK_STATUS.done | — |

### 3.1 scratch 需求

- 唯一跨 stage 持久量：`res1 INT32[128]`（stage6 写，stage7 与 stage11 读）。
- 注意力工作区：`Q_q8 / K1_q8 / V1_q8 / attn_q8` INT8[128]×4；`scores_q8[2]`、`probs_q15[2]` 小寄存器。
- 每个 Linear 复用 `act_buf`(256 INT8) / `y_buf`(384 INT32) 暂存——容量均足够（qkv 输出 384 = y_buf 容量；ffn_down 输入 256 ≤ act_buf 容量）。
- `block_scratch` 按可推断 BRAM 的数组写，避免大 FF 阵列。

### 3.2 LayerNorm bit-exact 约束（最高风险点）

Python 参考：
```
mean  = round_shift(sum(x), 7)          # log2N=7, N=128
diff  = x - mean
var   = round_shift(sum(diff*diff), 7)
sigma = isqrt_floor(max(var, 1))
y[i]  = round_div_signed(diff[i]*gamma_q[i], sigma) + beta_q[i]
```
硬件位宽要求（保证与任意精度 Python 一致、无中间溢出）：
- `sum(x)`：x 可为 INT32（res1），128 项求和 → 累加器 ≥ 40-bit，且 `round_shift` 走有符号分支。
- `diff[i]`：INT32 量级。`diff*diff` → ~62-bit；128 项求和 → `sum(diff*diff)` 累加器 ≥ 64-bit。
- `var` → `isqrt` 输入 ≥ 64-bit；`sigma` ≤ 32-bit。
- `diff[i]*gamma_q[i]`：INT32×INT8 → ≤ 40-bit，作 `w4a8_idiv` 的 numerator。
- `+ beta_q[i]`（INT16）后即 `ln_out[i]` INT32。

softmax 的 `÷sum_exp`（`(e<<15 + sum_exp/2)/sum_exp`，双正）用同一 `w4a8_idiv` 的无符号/正路径，结果 `min(32767, q)`，与 Python `int_softmax_py` 一致；退化分支（`sum_exp<=0`）按 Python 走 uniform fallback。

## 4. 寄存器映射（扩展 `w4a8_icb`，旧 `0x000–0x7FC` 全保留）

Y_BUF 用到 `0x7FC`，新寄存器从 `0x800` 起（仍在 `addr[11:0]`）：

| offset | name | R/W | 说明 |
|---|---|---|---|
| `0x800` | `BLOCK_CTRL` | W | bit0 = start（自动脉冲） |
| `0x804` | `BLOCK_STATUS` | R | bit0 = done, bit1 = busy |
| `0x808` | `BLOCK_CNT` | R | block 总周期（start→done） |
| `0x80C` | `BLOCK_STAGE` | R | 调试：当前/最后完成 stage id |
| `0x810` | `CNT_BLK_LINEAR` | R | 4 次 core 累计周期 |
| `0x814` | `CNT_BLK_VECTOR` | R | 向量单元累计周期 |
| `0x880` | `SCRATCH_ADDR` | W | 调试：选中间向量地址（编码 stage+index） |
| `0x884` | `SCRATCH_DATA` | R | 调试：读 res1 / Q / K / V / 各中间量（上板逐 stage 定位） |
| `0x900–0x97C` | `HIDDEN_IN` | W | 128 INT8 packed = 32 words |
| `0xA00–0xBFC` | `BLOCK_OUT` | R | 128 INT32 = 128 words |

- block 运行中（busy）对旧 Linear MMIO 与 SCRATCH 的行为：写忽略/读返回当前值即可（CPU 在 poll done 前不应访问）。
- `BLOCK_CTRL.start` 在 `BLOCK_STATUS.busy` 时被忽略（与旧 CTRL 一致语义）。

## 5. Python 生成器扩展

扩展 `tools/w4a8_block_full.py`（或新增 `tools/w4a8_block_export.py` 复用其函数），在现有 firmware header 之外新增产出：

1. `lecture2_0420_release/bram_init/` 下：`ln1_gamma.hex`、`ln1_beta.hex`、`ln2_gamma.hex`、`ln2_beta.hex`、`gelu_lut.hex`、`exp_lut.hex`、`kv_prev_k.hex`、`kv_prev_v.hex`（`$readmemh` 格式，位宽与 RTL 端口匹配）。
2. `lecture2_0420_release/trans/trans.srcs/sources_1/new/w4a8_block_consts.vh`：10 个 shift `localparam` + `GAMMA_LOG2` 等。
3. `tb_w4a8_block_vectors.vh`（或 `.hex`）：`hidden_in`、`block_out_golden`，以及各 stage 中间量 `ln1_q8 / Q_q8 / K1_q8 / V1_q8 / scores_q8 / probs_q15 / attn_q8 / res1 / ln2_q8 / ffn_up_q8 / gelu_out`，供 tb 逐 stage 断言。

所有产出与 Python golden 同一次计算导出，保证一致。

## 6. RTL Testbench

### 6.1 `tb_w4a8_block.v`（本步唯一硬 gate）

- `$readmemh` 初始化 wmem/smem（现有）+ §5 新增全部常量。
- 经 ICB 写 `HIDDEN_IN` = golden `hidden_in`。
- 脉冲 `BLOCK_CTRL.start` → 等 `BLOCK_STATUS.done`（带 timeout 上限，超时报 FAIL）。
- 读 `BLOCK_OUT[128]`，与 `block_out_golden` 逐 word **bit-exact** 比对；打印 `BLOCK TB PASS/FAIL (n/128)` + `BLOCK_CNT` + `CNT_BLK_LINEAR/VECTOR`。
- **逐 stage 断言**：每个 stage 结束后经 `SCRATCH` peek（或层次化引用）比对该 stage 中间量与 golden，任一 bit 不符立即定位到具体 stage 后再 `$finish`。

### 6.2 回归 sanity

- `tb_w4a8_engine.v`（9 层 Linear）仍 PASS（core 未改，预期自动通过）。
- pytest：现有 31 项仍 PASS；新增"RTL init 文件内容与 firmware header / Python golden 一致性"测试（读 `.hex`/`.vh` 与内存中 golden 数组比对）。

## 7. Firmware 胶水（写好，但非本步 gate）

- 新增 `w4a8_run_block_fpga(const int8_t *hidden_in, int32_t *block_out, uint32_t timeout, uint32_t *cycles_out)`：写 HIDDEN_IN → 写 BLOCK_CTRL.start → poll BLOCK_STATUS.done → 读 BLOCK_OUT → 返回 BLOCK_CNT。
- `main.c` Step 4 段：调 FPGA block 与软件 `w4a8_run_full_block`（CPU reference）比对 bit-exact，打印 `block_out PASS (n/128)` + CPU/FPGA cycles + block speedup（call 口径 + engine 口径）。
- 软件 `w4a8_run_full_block`、`w4a8_ops.{c,h}` 保留为 CPU reference。

### ILM 风险（标注，不挡 XSIM 交付）

CPU reference 仍需 `gelu_lut/exp_lut/gamma/beta/kv`，ILM 当前仅剩 ~772B。加 FPGA block 驱动可能溢出 64KB。缓解（tmp.md 已记）：删重复 `block_out_golden`（~512B）、cpu_ref act/y 去重（~2.7KB）、必要时 LN beta INT16→INT8。此为上板前的固件瘦身，与 RTL/XSIM 解耦。

## 8. Vivado / 集成（用户手动，spec 提供步骤）

- `e203_subsys_perips.v`：实例 `w4a8_linear_engine` → `w4a8_block_engine`（同引脚，drop-in）。
- 新 `.v` / `.vh` / `.hex` 加入工程 sources。
- 重新综合实现 + write bitstream（resident 权重/scale 不变，新增常量 BRAM init）。
- 上板 UART 目标：Step 4 block PASS + cycles + speedup。

## 9. 交付清单

| 类别 | 文件 |
|---|---|
| RTL 顶层/控制 | `w4a8_block_engine.v`、`w4a8_block_ctrl.v` |
| RTL 向量单元 | `w4a8_ln_unit.v`、`w4a8_attn_unit.v`、`w4a8_softmax_unit.v`、`w4a8_gelu_unit.v`、`w4a8_residual_unit.v` |
| RTL 库 | `w4a8_requant.v`、`w4a8_idiv.v`、`w4a8_isqrt.v` |
| RTL 修改 | `w4a8_icb.v`（扩展寄存器 + act/y mux 接口）、`block_scratch`（可并入 ctrl 或独立） |
| RTL 常量 | `w4a8_block_consts.vh`（生成） |
| TB | `tb_w4a8_block.v`、`tb_w4a8_block_vectors.vh`（生成） |
| Python | `w4a8_block_full.py` 扩展导出；新增一致性 pytest |
| BRAM init | `bram_init/{ln1,ln2}_{gamma,beta}.hex`、`gelu_lut.hex`、`exp_lut.hex`、`kv_prev_{k,v}.hex` |
| Firmware | `w4a8_block_fpga.{c,h}`、`main.c` Step 4 段（写好，XSIM 非 gate） |

## 10. 实施顺序（建议，细化交由 writing-plans）

1. Python 生成器扩展 + 一致性 pytest（先有 golden 与 init/常量产出）。
2. 库模块 `w4a8_requant` / `w4a8_idiv` / `w4a8_isqrt` + 各自单测 tb（bit-exact 风险先收敛）。
3. 向量单元逐个：ln_unit → attn_unit + softmax_unit → gelu_unit → residual_unit，每个对 golden 中间量单测。
4. `w4a8_icb` 扩展 + act/y mux + block_scratch。
5. `w4a8_block_ctrl` 串联 + `w4a8_block_engine` 顶层。
6. `tb_w4a8_block.v` 全块 bit-exact（**硬 gate**）+ 9 层回归 sanity。
7. Firmware 胶水 + main.c Step 4 段。
