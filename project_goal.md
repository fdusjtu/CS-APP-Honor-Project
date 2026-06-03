# CSAPP Honor 项目目标与路线

> 本文件是项目目标、架构规格和路线文档。实时进展、最新上板结果、当前下一步和临时注意事项以 `tmp.md` 为准。

## 最终目标

最终目标：在 ALINX AXU3EG FPGA 板上的蜂鸟 E203 RISC-V SoC 中，实现一个面向 LLM 核心算子的 W4A8 量化 Transformer Block 加速器，并在板上给出 bit-exact PASS 与 CPU/FPGA 加速比。

最终展示形态必须满足：

```text
E203 CPU 启动
FPGA W4A8 Linear/Transformer Block Engine 初始化
板上完成 Transformer block 输入输出比对
UART 115200 8N1 输出 PASS / mismatch / cycles / speedup
```

最低可接受输出：

```text
W4A8 Linear Engine
  CPU vs FPGA PASS
  speedup call=x...
  speedup engine=x...

Transformer Block Accelerator
  block_out bit-exact PASS (0 / 128 mismatches)
  CPU cycles = ...
  FPGA cycles = ...
  block speedup = x...
```

TinyLM UART 文本生成不再作为硬性结课要求，而作为扩展展示项。这样项目重点从“生成文本质量”转回课程更关心的 LLM 算子加速、硬件 datapath、memory hierarchy、MMIO 协同和可量化性能结果。

---

## 新项目定位

项目重新定位为：

```text
面向 LLM 算子加速的 W4A8 Transformer Block Accelerator
```

项目分两级交付。第一级已经完成：不再把 FPGA 端定义成简单的 `16x64 GEMV tile MMIO 外设`，而是由 FPGA 端承担完整 Linear layer 的执行：

- 常驻全部目标模型 Linear 权重和 scale
- 根据 `layer_id` 选择 qkv / proj / ffn_up / ffn_down / lm_head
- 自动遍历 row tile / col tile
- 流水执行 INT4 x INT8 MAC
- 在一个 row tile 内跨所有 col groups 保持 INT32 accumulator
- row tile 结束后做 per-row rescale
- 输出完整 layer 的 INT32 result
- 记录性能计数器

第二级作为新的结课核心目标：把一个完整 Transformer block 的非 Linear 算子也纳入 FPGA block engine，使板上展示从单个 Linear/GEMV 算子加速升级为端到端 block 算子链加速：

- LayerNorm / RMSNorm 定点实现
- QKV Linear / Projection / FFN Up / FFN Down
- attention score
- softmax LUT
- value weighted sum
- GELU LUT
- residual add
- block output writeback
- performance counter

---

## 为什么从 tile 加速改成 Linear 层加速

原路线已经证明了 W4A8 tile accelerator 在 RTL 仿真中正确，但课程设计展示上 FPGA 参与度偏低。

原路线：

```text
CPU 拆 tile
CPU 写 W/X/SCALE
CPU 每 tile start/wait
FPGA 只算一个 16x64 tile
```

新路线：

```text
CPU 写 activation + layer_id
FPGA 自己完成整个 Linear layer
CPU 读完整 y
```

这样更符合 CSAPP/体系结构课程设计关注点：

- memory hierarchy
- MMIO interface
- datapath
- controller FSM
- pipeline
- stall/cycle counter
- quantized arithmetic
- CPU/FPGA co-design

---

## Linear 层加速原理

Transformer 中的 Linear 层本质上仍然是矩阵-向量乘法：

```text
y[row] = sum_col W[row][col] * x[col]
```

本项目的量化格式为：

```text
W: INT4
x: INT8
accumulator: INT32
scale: INT16
output: INT32
```

原来的 `gemv_accel` 只加速一个固定 `16x64` tile。CPU 需要把完整 Linear 层拆成多个 tile，反复写入当前 tile 的权重、activation、scale，然后 start/wait/read。FPGA 主要承担一个小 tile 的 MAC 计算。

新的 `w4a8_linear_engine` 仍然使用 16 行并行 MAC 作为计算核心，但它把完整 Linear 层的执行流程也放进 FPGA：

```text
CPU:
  写 ACT_BUF
  写 LAYER_ID
  写 CTRL.start
  poll STATUS.done
  读完整 Y_BUF

FPGA:
  根据 LAYER_ID 读取 descriptor
  自动遍历 row_tile
  自动遍历 col_word / col_tile
  从 resident_wmem 读取 INT4 packed weight
  从 ACT_BUF 读取 INT8 activation
  16 行并行执行 INT4 x INT8 MAC
  在 FPGA 内部保持 INT32 accumulator
  跨所有 col group 累加
  读取 resident_smem 中的 per-row scale
  做 rescale
  写回完整 Y_BUF
  更新 performance counter
```

因此，区别不是数学公式变了，而是加速粒度变了：

| 对比项 | 旧 tile accelerator | 新 Linear Engine |
|---|---|---|
| 加速粒度 | 一个 `16x64` GEMV tile | 一个完整 Linear layer |
| CPU 职责 | 拆 tile、搬权重、循环 start/wait、合并结果 | 写 activation 和 `layer_id`，等待完整输出 |
| FPGA 职责 | 主要执行 tile MAC | 执行 descriptor 选择、tile 遍历、权重读取、累加、rescale、写回 |
| 权重使用 | 每个 tile 由 CPU 写入 | 常驻 BRAM，当前板级默认由 bitstream 预初始化，MMIO load 接口保留 |
| 中间累加 | 容易暴露给 CPU 或 runtime | 保留在 FPGA 内部的 INT32 accumulator |
| 展示重点 | 并行 MAC | memory hierarchy、MMIO、FSM、datapath、performance counter |

一句话总结：旧设计是 **tile-level compute accelerator**，新设计是 **layer-level task accelerator**。

---

## 当前已知状态（摘要）

截至 2026-06-01，最新详细进展记录见 `tmp.md`。摘要如下：

- Phase 1 INT8 GEMV PoC 已板上验证。
- 旧 W4A8 tile accelerator 已完成并验证，随后已被新的 `w4a8_linear_engine` 路线替代。
- 新 W4A8 Linear Engine 已完成 RTL、Python golden、XSIM 9 层 bit-exact 验证和真实 FPGA 9 层 self-test 上板验证。
- CPU baseline + 加速比已经板上 PASS。
- Step 3b 完整 Transformer block 软件调度版已经板上 `FULL BLOCK PASS (0 / 128 mismatches)`；结课下一步改为将 block 内非 Linear 算子继续硬件化，形成 `w4a8_block_engine`。
- 旧 trap loop 根因已查清并修复；当前上板 self-test 已证明 E203 可以正常从 ILM 启动并访问 W4A8 MMIO。

### 历史已完成：旧 tile accelerator

旧 `gemv_accel` 路线曾通过：

```text
tile_random PASS
tile_boundary PASS
linear_random_32x128 PASS
linear_boundary_32x128 PASS
linear_awq_like_32x128 PASS
```

该路线现已废弃，后续开发以 `w4a8_linear_engine` 为准。

### 历史问题：trap loop（已解决）

旧 firmware 板上曾进入 trap loop：

```text
0x80000698 -> 0x00000000 -> 0x00000002 -> 0x80000364
```

这说明旧版本发生了早期异常，并且默认 trap handler 返回后继续重复异常。

已加入临时 debug 插桩：

- `core_trap_handler()` 保存第一次异常：

```text
0x900001f0 = magic = 0x54524150
0x900001f4 = mcause
0x900001f8 = mepc
0x900001fc = mtval
0x90000200 = trap sp
```

- 新 trap handler 会停在：

```text
PC = 0x80000678
```

- 系统 ILA 新增 `u_ila_trap_store`：

```text
probe0 = mem_icb_cmd_addr
probe1 = mem_icb_cmd_wdata
```

后续如果仍需调试旧启动问题，trigger：

```text
probe0 == 0x900001f0
```

该问题已解决：旧 trap 根因是 `verilog_to_hex64.py` 曾忽略 `.verilog` 中的 `@ADDR`，丢掉段间 padding，导致 ITCM 镜像整体错位 2 字节。转换逻辑已修复，后续上板 self-test 已证明 E203 可以正常启动并访问 W4A8 MMIO。

以下 trap 诊断信息保留为历史调试方法，供未来出现新启动异常时参考。

前置判定目标：

```text
读出或抓到 mcause / mepc / mtval
判断异常属于哪一类
```

判断规则：

| mepc range | likely source | action |
|---|---|---|
| `_start` / `SystemInit` / `__libc_init_array` | startup / memory init / SDK | 先修启动路径 |
| `_premain_init` / UART functions | UART / SDK init | 先修 UART/init |
| `0x100410xx` MMIO access | PPI/O14/accelerator decode | 新 engine 集成时重点验证 MMIO |
| old `w4a8_linear` | old runtime / old gemv protocol | 可由新 engine 替换后再验证 |
| `tiny_lm_step` | TinyLM runtime | 新 engine 通过 TV 后再查 |

如果未来再次出现早期异常，不要人工寻找第一次 `0x80000364` 波形；优先使用 trap CSR capture 或 JTAG 读 DTCM。

---

## 目标模型规格

第一版目标规格固定为：

| 参数 | 值 |
|---|---:|
| vocab | 64 |
| hidden | 128 |
| ffn | 256 |
| layers | 2 |
| heads | 1 |
| seq_len | 64 |

vocab 取 64（不是 128）的原因：训练语料 `data/input.txt` 只有 65 个唯一字符，无法支撑 vocab=128，且 vocab 必须是 16 的倍数；vocab=64 是唯一既匹配数据又合法的值。这只影响 lm_head 输出维度，对字符级莎士比亚已足够。

Linear 层 shape：

| Linear 层 | M x N | weight words | scale words |
|---|---:|---:|---:|
| layer0_qkv | 384 x 128 | 6144 | 192 |
| layer0_proj | 128 x 128 | 2048 | 64 |
| layer0_ffn_up | 256 x 128 | 4096 | 128 |
| layer0_ffn_down | 128 x 256 | 4096 | 64 |
| layer1_qkv | 384 x 128 | 6144 | 192 |
| layer1_proj | 128 x 128 | 2048 | 64 |
| layer1_ffn_up | 256 x 128 | 4096 | 128 |
| layer1_ffn_down | 128 x 256 | 4096 | 64 |
| lm_head | 64 x 128 | 1024 | 32 |

总权重：

```text
resident_wmem used = 33792 x 32-bit = 132 KB
resident_smem used = 928 x 32-bit = 3.625 KB

WMEM_BANK_DEPTH = 4096
WMEM_ADDR_W     = 12

resident_wmem capacity = 16 banks x 4096 x 32-bit = 256 KB
```

这些权重和 scale 第一版全部放 FPGA resident BRAM。`WMEM_BANK_DEPTH=4096` 是 RTL 固定目标；导出脚本必须检查 `max_bank_addr < 4096`，超过则报错。

---

## 系统总览图

### 系统总览（结课目标：Transformer Block Accelerator）

```text
 离线 (PC): train/checkpoint
      │
      ├─ quantize W4A8 Linear weights + INT16 scales
      ├─ export block constants: LN params / LUT / test vectors / golden output
      └─ generate BRAM init + firmware headers
                                      │
                                      ▼
 ┌────────────────────────── ALINX AXU3EG / E203 SoC ──────────────────────────┐
 │                                                                              │
 │  ┌────────────── E203 CPU (control + benchmark) ──────────────┐             │
 │  │ boot / UART / mcycle                                       │             │
 │  │ write hidden_in or test_id                                 │             │
 │  │ write CTRL.start                                           │             │
 │  │ poll STATUS.done                                           │             │
 │  │ read block_out / counters                                  │             │
 │  │ compare Python/CPU golden                                  │             │
 │  │ print PASS / mismatch / cycles / speedup                   │             │
 │  └───────────────────────┬────────────────────────────────────┘             │
 │                          │ MMIO / ICB                                        │
 │                          ▼                                                   │
 │  ┌──────────── W4A8 Transformer Block Accelerator ─────────────┐             │
 │  │ icb_slave + register file                                   │             │
 │  │ block_controller_fsm                                        │             │
 │  │                                                             │             │
 │  │  ┌────────────── reusable W4A8 Linear Engine ────────────┐  │             │
 │  │  │ QKV / PROJ / FFN_UP / FFN_DOWN                        │  │             │
 │  │  │ resident_wmem: INT4 packed weights, 16 banks           │  │             │
 │  │  │ resident_smem: INT16 per-row scales                    │  │             │
 │  │  │ INT32 accumulators + rescale + perf counters           │  │             │
 │  │  └────────────────────────────────────────────────────────┘  │             │
 │  │                                                             │             │
 │  │  ┌────────────── Transformer vector units ───────────────┐  │             │
 │  │  │ LayerNorm / RMSNorm fixed-point                        │  │             │
 │  │  │ attention score Q*K                                    │  │             │
 │  │  │ softmax LUT                                            │  │             │
 │  │  │ value weighted sum                                     │  │             │
 │  │  │ GELU LUT                                               │  │             │
 │  │  │ residual add / requantize                              │  │             │
 │  │  └────────────────────────────────────────────────────────┘  │             │
 │  │                                                             │             │
 │  │  on-chip state BRAM / regs: x, ln, qkv, attn, ffn, block_out │             │
 │  └─────────────────────────────────────────────────────────────┘             │
 │                                                                              │
 └──────────────────────────────────────────────────────────────────────────────┘
```

一句话分工：CPU 只负责控制、benchmark 和 UART；FPGA 端完成一个 Transformer block 内的主要算子链路，包括 LN、QKV、attention、projection、residual、FFN、GELU 和 block output。现有 `w4a8_linear_engine` 作为其中的 Linear 子引擎继续复用。

### Transformer block 算子分工（目标版）

这里的 `qkv`、`proj`、`ffn_up`、`ffn_down` 都是 block 内的 Linear 层。它们的共同形式都是：

```text
output = W * input
```

区别只在矩阵 shape 和语义不同：

| Linear 层 | 在 Transformer 中的作用 | 当前 shape |
|---|---|---:|
| `qkv` | 把 hidden state 投影成 Q/K/V | `384 x 128` |
| `proj` | 把 attention 输出投影回 hidden 维度 | `128 x 128` |
| `ffn_up` | FFN 第一层升维 | `256 x 128` |
| `ffn_down` | FFN 第二层降回 hidden 维度 | `128 x 256` |
| `lm_head` | 完整 generation 的可选扩展，不属于结课 block accelerator 的硬性范围 | `64 x 128` |

下图展示的是结课目标中的单个 Transformer block accelerator。输入是一个固定 hidden vector，输出是 `block_out[128]`，用于和 Python/CPU golden 做 bit-exact 对比并计算 speedup。

```text
  hidden_in[128]
       │
       ▼
  ┌─────────────────────────────────────────────┐
  │ LayerNorm 1 + requantize                    │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ W4A8 Linear: QKV 384 x 128                  │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ split Q/K/V -> attention score -> softmax   │
  │ -> value weighted sum -> requantize         │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ W4A8 Linear: PROJ 128 x 128                 │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ residual add                                │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ LayerNorm 2 + requantize                    │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ W4A8 Linear: FFN_UP 256 x 128               │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ GELU LUT + requantize                       │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ W4A8 Linear: FFN_DOWN 128 x 256             │
  └──────────────────┬──────────────────────────┘
                     ▼
  ┌─────────────────────────────────────────────┐
  │ residual add                                │
  └──────────────────┬──────────────────────────┘
                     ▼
              block_out[128]
```

| 算子 | block 内次数 | 目标位置 |
|---|---:|---|
| LayerNorm / requantize | 2 | FPGA |
| **Linear: qkv / proj / ffn_up / ffn_down** | **4** | **FPGA** |
| attention score / softmax / value weighted sum | 1 | FPGA |
| GELU LUT | 1 | FPGA |
| residual add | 2 | FPGA |
| CPU control / UART / golden compare | 1 | CPU |

---

## 新硬件架构

当前已完成的第一级顶层是：

```text
w4a8_linear_engine
```

结课目标新增第二级顶层：

```text
w4a8_block_engine
├── icb_slave / register file
├── block_controller_fsm
├── input_buf / output_buf
├── vector_norm_unit
├── attention_unit
├── softmax_lut_unit
├── gelu_lut_unit
├── residual_unit
├── scratch/state memory
└── w4a8_linear_engine
    ├── resident_wmem
    ├── resident_smem
    ├── layer_desc
    ├── act_buf
    ├── core
    ├── y_buf
    └── perf_cnt
```

### 模块职责

| 模块 | 职责 |
|---|---|
| `icb_slave / register file` | MMIO 译码、start/done、test_id、counter、input/output 访问 |
| `block_controller_fsm` | 串联 LN1、QKV、attention、proj、residual、LN2、FFN、GELU、residual |
| `input_buf / output_buf` | CPU 写入 `hidden_in[128]`，FPGA 写回 `block_out[128]` |
| `vector_norm_unit` | 定点 LayerNorm / RMSNorm，输出 INT8 activation |
| `attention_unit` | Q/K/V split、Q*K score、value weighted sum |
| `softmax_lut_unit` | 使用 INT LUT 近似 softmax，避免浮点 |
| `gelu_lut_unit` | 使用 INT8 LUT 实现 FFN 激活 |
| `residual_unit` | INT32/INT8 对齐后的 residual add 与 requantize |
| `scratch/state memory` | 保存 x、ln、qkv、attn、ffn 中间向量 |
| `w4a8_linear_engine` | 复用现有 Linear layer accelerator，执行 qkv/proj/ffn_up/ffn_down |
| `resident_wmem` | 常驻 INT4 packed Linear 权重，16 bank |
| `resident_smem` | 常驻 INT16 packed per-row scale |
| `perf_cnt` | block total、linear total/mac/stall/tile、vector unit cycles |

可复用小模块：

- `int4_unpack.v`
- `row_rescale.v`
- 现有 `w4a8_core.v`
- 现有 `w4a8_resident_wmem.v`
- 现有 `w4a8_resident_smem.v`

旧模块将被替换：

- `mac_array16.v`
- `w4a8_tile_kernel.v`
- `gemv_accel.v`

`w4a8_linear_engine` 不是废弃模块，而是 block engine 内部最重要的 Linear 子引擎。

---

## 常驻 Weight Memory 布局

### Weight Banking 方式

`resident_wmem` 使用 16 个 bank：

```text
bank = row mod 16
```

每个 bank 存该 bank 对应行的 packed INT4 word。

同一 cycle 内，16 个 bank 并行输出同一 `bank_addr` 的 16 个 32-bit packed words，分别喂给 16 行 MAC。

RTL 固定容量：

```text
WMEM_BANK_DEPTH = 4096
WMEM_ADDR_W     = 12
```

目标模型实际使用：

```text
packed weight words = 33792
max bank depth used = 33792 / 16 = 2112
```

因此 4096 深度留有余量，同时保持地址宽度规整。导出脚本必须检查 `bank_addr < WMEM_BANK_DEPTH`。

### Load 地址映射

`W_LOAD_ADDR` 使用 flat index。

硬件映射：

```text
bank      = W_LOAD_ADDR[3:0]
bank_addr = W_LOAD_ADDR >> 4
```

CPU 写入顺序固定为：

```text
for each layer:
  for each row_tile:
    for each col_word:
      for bank in 0..15:
        W_LOAD_DATA = weight[row_tile*16 + bank][col_word]
```

这样连续 16 次写入填满一个 `bank_addr` 下的 16 个 bank。

### Engine 读地址

descriptor 中的 `w_base` 单位为 `bank_addr`。

对某 layer：

```text
bank_addr = w_base + row_tile * (N / 8) + col_word
bank      = 0..15
```

读出的 16 个 word 对应：

```text
row = row_tile * 16 + bank
col = col_word * 8 .. col_word * 8 + 7
```

---

## 常驻 Scale Memory 布局

`resident_smem` 存 packed INT16 scale：

```text
1 word = 2 x signed INT16 scale
```

descriptor 中的 `s_base` 单位为 32-bit word。

对输出 row `r`：

```text
word_addr = s_base + r / 2
half      = r % 2
```

由于 scale memory 可以是单口，engine 在每个 row tile 开始或 rescale 前先读取当前 16 行 scale：

```text
LOAD_SCALE: 8 cycles
scale_tile[0..15] ready
RESCALE: use scale_tile
```

---

## MMIO 寄存器地址表

基地址保持不变：

```text
0x1004_1000
```

地址译码字段：

```text
addr[11:0]
```

| offset | name | R/W | 说明 |
|---:|---|---|---|
| `0x000` | `CTRL` | W | bit0 为 start |
| `0x004` | `STATUS` | R | bit0 为 done，bit1 为 busy |
| `0x008` | `SHIFT` | RW | rescale shift，默认 14 |
| `0x00C` | `LAYER_ID` | RW | 选择 descriptor id，范围 0..8 |
| `0x010` | `W_LOAD_ADDR` | W | 设置 flat weight load index |
| `0x014` | `W_LOAD_DATA` | W | 写 resident weight word，自动递增 |
| `0x018` | `S_LOAD_ADDR` | W | 设置 scale load word index |
| `0x01C` | `S_LOAD_DATA` | W | 写 resident scale word，自动递增 |
| `0x020` | `CNT_TOTAL` | R | 从 start 到 done 的周期数 |
| `0x024` | `CNT_MAC` | R | MAC active 周期数 |
| `0x028` | `CNT_STALL` | R | datapath stall 周期数 |
| `0x02C` | `CNT_TILES` | R | 已执行 tile 数 |
| `0x040` | `DESC0_M` | RW | layer0_qkv M |
| `0x044` | `DESC0_N` | RW | layer0_qkv N |
| `0x048` | `DESC0_W_BASE` | RW | layer0_qkv w_base |
| `0x04C` | `DESC0_S_BASE` | RW | layer0_qkv s_base |
| `0x050` | `DESC1_*` | RW | layer0_proj descriptor |
| `0x060` | `DESC2_*` | RW | layer0_ffn_up descriptor |
| `0x070` | `DESC3_*` | RW | layer0_ffn_down descriptor |
| `0x080` | `DESC4_*` | RW | layer1_qkv descriptor |
| `0x090` | `DESC5_*` | RW | layer1_proj descriptor |
| `0x0A0` | `DESC6_*` | RW | layer1_ffn_up descriptor |
| `0x0B0` | `DESC7_*` | RW | layer1_ffn_down descriptor |
| `0x0C0` | `DESC8_*` | RW | lm_head descriptor |
| `0x0D0..0x0FC` | reserved | - | descriptor/MMIO 扩展预留 |
| `0x100..0x1FC` | `ACT_BUF` | W | 64 words, 256 INT8 packed activation |
| `0x200..0x7FC` | `Y_BUF` | R | 384 words, INT32 output |

`CNT_WLOAD` 暂不做。权重加载耗时由 CPU 使用 `mcycle` 测。

---

## Engine FSM

`core` 状态机：

```text
IDLE
  wait CTRL.start

LOAD_DESC
  latch M, N, w_base, s_base
  clear counters

ROW_INIT
  clear acc[16]
  set row_tile

LOAD_SCALE
  read 8 scale words
  unpack to scale_tile[16]

COL_PREFETCH
  read 16 bank weight words for current col_word

MAC_8
  8 cycles
  each cycle:
    broadcast act[col]
    unpack one int4 per row
    acc[row] += w4[row] * act[col]

NEXT_COL
  if more col_word: prefetch next and continue
  else: go RESCALE

RESCALE
  y[row] = (acc[row] * scale[row]) >>> shift

WRITE_Y
  write 16 rows to y_buf

NEXT_ROW
  if more row_tile: ROW_INIT
  else: DONE

DONE
  done=1, busy=0
```

流水线目标：

- 第一优先级是功能正确。
- `CNT_STALL == 0` 是优化目标，不是第一版功能门槛。
- testbench 必须检查 bit-exact 输出和正确 tile count。

`CNT_TILES` counts 16x64 logical MAC tiles, not 8-column bank words. The FSM should increment it once per 64 activation columns for each row tile. Internally, one tile contains `64 / 8 = 8` packed weight words per bank.

期望 tile count：

```text
tiles = (M / 16) * (N / 64)
```

期望 MAC cycles：

```text
mac_cycles = tiles * 64
```

---

## Python Golden 与导出修改

Update `tools/w4a8_gen_vectors.py` or add a companion script.

需要新增：

1. Banked weight packer:

```text
row-major INT4 matrix
  -> 16-bank resident load stream
```

2. Engine test vector cases:

| case | shape |
|---|---:|
| layer0_qkv | 384 x 128 |
| layer0_proj | 128 x 128 |
| layer0_ffn_up | 256 x 128 |
| layer0_ffn_down | 128 x 256 |
| layer1_qkv | 384 x 128 |
| layer1_proj | 128 x 128 |
| layer1_ffn_up | 256 x 128 |
| layer1_ffn_down | 128 x 256 |
| lm_head | 64 x 128 |

3. 生成 header 内容：

- descriptor table
- banked `w_load_stream`
- `s_load_stream`
- activation input
- golden output

数值 golden 仍然沿用 `golden_linear()`：

```text
W4 x INT8 -> INT32 acc -> per-row Q2.14 rescale
```

只改变 memory layout。

---

## RTL Testbench 计划

当前实际实现使用统一 testbench：

| testbench | 覆盖内容 |
|---|---|
| `tb_w4a8_engine.v` | single layer `128x128`、multicol `128x256`、完整 9 层目标模型 shape |

硬性检查：

- all `Y_BUF` words match Python golden bit-exact
- `CNT_TILES == expected`
- `CNT_MAC == expected`
- `STATUS.done` 置位
- no timeout

软性/诊断检查：

- `CNT_TOTAL` within expected range
- `CNT_STALL` readable and not unknown
- if prefetch is fully optimized, `CNT_STALL == 0`

---

## Firmware Runtime 计划

当前板级路线采用 **BRAM 预初始化 resident weights/scales**：完整 9 层权重和 scale 进入 bitstream，不占 E203 ILM。MMIO `W_LOAD_*` / `S_LOAD_*` 接口仍保留，可用于小规模调试或未来扩展，但当前 firmware 不再开机加载完整 132KB resident weights。

废弃旧 API：

```c
int w4a8_linear(int m, int n,
                const uint32_t *w_packed,
                const uint32_t *x_packed,
                const uint32_t *scale_packed,
                int shift,
                uint32_t *y);
```

新 API：

```c
int w4a8_run_layer(int layer_id,
                       const uint32_t *x_packed_i8,
                       uint32_t *y);

int w4a8_run_block(const int32_t *hidden_in,
                   int32_t *block_out,
                   uint32_t timeout);
```

第一级 Linear Engine 运行流程：

```text
boot:
  write descriptors
  resident weights/scales are already initialized by bitstream BRAM init
  optional debug path: stream weights/scales via W_LOAD_DATA / S_LOAD_DATA

per Linear:
  CPU dynamically quantizes activation to INT8
  write ACT_BUF[0..N/4-1]
  write LAYER_ID
  write CTRL.start
  poll STATUS.done
  read Y_BUF[0..M-1]
  CPU multiplies y_int32 by activation scale
```

结课目标 Block Engine 运行流程：

```text
boot:
  resident weights/scales/LUT are initialized by bitstream BRAM init
  CPU writes optional block descriptors and shift constants

per benchmark:
  CPU writes hidden_in[128] or selects a resident test vector
  CPU writes BLOCK_CTRL.start
  FPGA runs the whole Transformer block
  CPU polls BLOCK_STATUS.done
  CPU reads block_out[128]
  CPU reads block counters
  CPU compares output with golden and prints speedup
```

C 端保留一份 descriptor mirror：

```c
typedef struct {
    int m;
    int n;
    int w_base;
    int s_base;
} w4a8_layer_desc_t;
```

这份 mirror 让 firmware 知道：

- 需要写入多少个 activation word：`n / 4`
- 需要读取多少个 output word：`m`

Layer id 分配：

| id | layer |
|---:|---|
| 0 | layer0_qkv |
| 1 | layer0_proj |
| 2 | layer0_ffn_up |
| 3 | layer0_ffn_down |
| 4 | layer1_qkv |
| 5 | layer1_proj |
| 6 | layer1_ffn_up |
| 7 | layer1_ffn_down |
| 8 | lm_head |

---

## Transformer Block Benchmark 流程

结课主流程不要求生成文本，而是对一个完整 block 做输入输出比对和加速比测试：

```text
1. CPU boot
2. CPU writes hidden_in[128] or test_id to block engine
3. CPU reads mcycle t0
4. CPU writes BLOCK_CTRL.start
5. FPGA block engine:
   - LayerNorm 1
   - QKV Linear
   - attention score / softmax / value weighted sum
   - Projection Linear
   - residual add
   - LayerNorm 2
   - FFN Up Linear
   - GELU
   - FFN Down Linear
   - residual add
   - write block_out[128]
6. CPU polls STATUS.done
7. CPU reads mcycle t1 and FPGA counters
8. CPU reads block_out[128]
9. CPU compares against Python/CPU golden
10. UART prints PASS / mismatches / CPU cycles / FPGA cycles / speedup
```

TinyLM generation 仍可作为扩展流程：在 block engine 之上增加 embedding、KV cache across tokens、lm_head、argmax 和 token loop。但这不是结课硬性目标。

---

## 实施顺序

### 步骤 1A：前置 Trap 诊断

在依赖任何板级 UART 结果之前，必须先分类现有 trap 的根因。

必需结果：

```text
mcause = ...
mepc   = ...
mtval  = ...
classification = startup / UART / MMIO / old runtime / TinyLM / other
```

优先方法：

1. Use `u_ila_trap_store`:

```text
trigger: probe0 == 0x900001f0
capture:
  0x900001f4 -> mcause
  0x900001f8 -> mepc
  0x900001fc -> mtval
```

2. 如果 JTAG/OpenOCD 可用，读取：

```text
x/5wx 0x900001f0
```

这项任务可以和 Python golden、RTL 工作并行，但必须在最终板级验收前解决。

### 步骤 1B：冻结 Spec

本文件作为当前有效路线文档。

### 步骤 2：Python Golden

状态：已完成。当前实现见 `tools/w4a8_engine_vectors.py`，并已导出 `lecture2_0420_release/bram_init/` 与 firmware self-test header。

实现 banked resident layout 生成器和 engine TV。

交付物：

- banked weight stream
- scale stream
- descriptor table
- nine layer test vectors
- unit tests for bank mapping

### 步骤 3：RTL

状态：已完成。当前 RTL 文件已位于 `lecture2_0420_release/trans/trans.srcs/sources_1/new/`。

Create new files under:

```text
lecture2_0420_release/trans/trans.srcs/sources_1/new/
```

计划新增文件：

- `w4a8_icb.v`
- `w4a8_resident_wmem.v`
- `w4a8_resident_smem.v`
- `w4a8_core.v`
- `w4a8_linear_engine.v`

复用：

- `int4_unpack.v`
- `row_rescale.v`

### 步骤 4：仿真

状态：已完成。当前统一 testbench 为 `tb_w4a8_engine.v`，覆盖 single-layer、multicol 和 full 9 layers，并已 XSIM PASS。

Vivado 集成前先运行 testbench。

当前 PASS 项：

```text
ENGINE TB ALL PASS  (9 / 9 layers)
```

### 步骤 5：Firmware Runtime

当前 firmware 工程在：

```text
lecture2_0420_release/test1/application/
```

Add/replace:

- `w4a8.h`
- `w4a8_selftest_vectors.h`
- `w4a8_cpu_ref.{c,h}`
- `w4a8_cpu_ref_weights.h`
- `w4a8_block_vectors.h`
- update `main.c`
- keep UART text output

### 步骤 6：Vivado 集成

状态：已完成。

替换旧 accelerator 实例：

```text
gemv_accel -> w4a8_linear_engine
```

保持基地址：

```text
0x1004_1000
```

除非绝对必要，避免修改 E203 core RTL。

### 步骤 7：板级 Bring-up

阶段性上板目标：

```text
W4A8 Linear Engine
CPU BASELINE PASS
  layer0_proj CPU=... FPGA_call=... FPGA_engine=... speedup call=x... engine=x...
  layer0_qkv  CPU=... FPGA_call=... FPGA_engine=... speedup call=x... engine=x...
  lm_head     CPU=... FPGA_call=... FPGA_engine=... speedup call=x... engine=x...

W4A8 Transformer Block Accelerator
  block_out bit-exact PASS (0 / 128 mismatches)
  CPU block cycles = ...
  FPGA block cycles = ...
  block speedup = x...

TinyLM generation
  optional demo, not required for final acceptance
```

---

## 验收标准

| 层级 | 要求 |
|---|---|
| Python | banked layout 单元测试 PASS |
| RTL | testbench bit-exact PASS |
| Firmware build | ELF/verilog/hex generated cleanly |
| Board boot | no unresolved trap loop |
| MMIO | weight load、descriptor write、start/done/readback 正常 |
| Linear accelerator | FPGA output bit-exact vs CPU/Python golden, speedup reported |
| Transformer block | block output bit-exact PASS, CPU/FPGA cycles and speedup reported |
| TinyLM | optional UART text demo, not a hard requirement |
| Report | includes architecture diagram, register map, memory layout, FSM, performance counters |

最终硬性验收：

```text
Board UART reports Linear PASS, Transformer Block bit-exact PASS, and CPU/FPGA speedup using E203 CPU + FPGA W4A8 block accelerator.
```

---

## 注意事项与约束

- Toolchain: Vivado 2022.2；当前本机 Nuclei Studio 202212 bundled `riscv-nuclei-elf-gcc` 为 GCC 10.2.0。
- Board/part: ALINX AXU3EG, `xczu3eg-sfvc784-1-i`.
- 运行 Vivado 时保持工程路径为全英文。
- BRAM inference 是一级约束。`resident_wmem` 必须推断出 16 个独立 memory/bank，每个 bank 在 load mode 下写入，在 run mode 下读取。避免会阻碍 Vivado 推断 BRAM 的多写端或多 always-block RAM 写法。engine 不需要 read-during-write 行为；load 和 run 阶段彼此分离。
- `resident_smem` may be single-port or simple dual-port. If single-port, explicitly stage 8 scale words into `scale_tile[16]` before rescale.
- Do not hand-edit generated files under:

```text
Debug/
trans.runs/
trans.gen/
trans.cache/
trans.sim/
```

- 避免修改 `sources_1/imports/e203/core/` 下的 E203 core RTL。
- E203 subsystem 下现有 debug 改动是临时的；板级 bring-up 稳定后应移除或清理。
