# 复旦大学计算机原理与体系结构荣誉课程设计

## W4A8 Transformer Block FPGA 加速器

本项目为复旦大学《计算机原理与体系结构》荣誉课程设计，在 **ALINX AXU3EG**（Zynq UltraScale+ MPSoC）上实现了基于 E203 RISC-V 软核 SoC 的 Transformer Block 硬件加速器。

**板上验证结果（2026-06-03）：**

```
整块加速比（vs 真·全 CPU 基线）：engine x137.83 / call x129.23
单层加速比（qkv 384×128）：        engine x314.6  / call x169.9
```

---

## 量化方案 — W4A8

- **权重**：INT4，每行独立缩放（INT16 scale，Q-format shift=14）
- **激活**：INT8
- **累加器**：INT32
- 权重打包格式：每个 32-bit word 存 8 个 INT4 nibble，LSN-first，行主序

## Transformer Block 结构

加速器实现一个完整的 Transformer Block（单层，seq_len=2）：

```
hidden_in（INT8，128 维）
    │
    ├─ LayerNorm 1（整数 isqrt + LUT）
    ├─ QKV Linear   384×128   W4A8  ─┐
    ├─ Attention（Q·K, softmax, ·V）  │  全部在 FPGA 硬件中完成
    ├─ Proj Linear  128×128   W4A8  ─┤
    ├─ Residual 1                    │
    ├─ LayerNorm 2                   │
    ├─ FFN-up Linear  256×128 W4A8  ─┤
    ├─ GELU（256 项 LUT）             │
    └─ FFN-down Linear 128×256 W4A8 ─┘
         │
    block_out（INT32，128 维）
```

模型规格：字符级语言模型，vocab=64，hidden=128，ffn=256，2 层，1 个注意力头。

---

## 硬件架构

```
E203 RISC-V 核心（15 MHz）
    │  ICB 总线（内存映射 MMIO）
    ▼
w4a8_block_engine  @ 0x1000_8000
    ├── w4a8_core           — 16 路并行 INT4×INT8 MAC 阵列（Linear 层）
    ├── w4a8_ln_unit        — 整数 LayerNorm（isqrt 状态机）
    ├── w4a8_attn_unit      — 点积注意力 + softmax
    ├── w4a8_gelu_unit      — GELU（256 项 LUT）
    ├── w4a8_residual_unit  — 残差加法 + 重量化
    ├── w4a8_resident_wmem  — 16-bank BRAM，权重在 bitstream 初始化时加载
    └── w4a8_resident_smem  — BRAM，存储每行缩放系数
```

权重和缩放系数通过 BRAM init 在烧写 bitstream 时直接初始化，无需 CPU 在启动时传输权重。

---

## 目录结构

```
fpga/
├── vivado/                     Vivado 工程（trans.xpr + RTL 源码）
│   └── trans.srcs/
│       ├── sources_1/new/      核心 RTL（w4a8_*.v/.vh，共 17 个文件）
│       ├── sources_1/imports/  E203 RISC-V SoC 上游源码
│       └── sim_1/new/          仿真 Testbench（tb_w4a8_*.v）
├── firmware/                   固件源码（RISC-V C）
│   └── application/
│       ├── main.c              顶层入口：baseline + block demo
│       ├── w4a8.h              MMIO 寄存器映射 + 驱动
│       ├── w4a8_block_fpga.c   FPGA block demo + 加速比测量
│       ├── w4a8_block_cpu.c    真·全 CPU 基线（Method A 权重读回）
│       ├── w4a8_ops.c          整数 LN / GELU / softmax / 重量化
│       └── w4a8_cpu_ref.c      单层 CPU GEMV 参考
├── hexdump/
│   ├── test1.bin / test1.hex   编译后的固件二进制
│   └── test2.hex               ITCM 初始化 hex（嵌入 bitstream）
└── bram_init/                  权重/缩放系数的 BRAM 初始化 hex

tools/
├── tiny_char_lm.py             训练字符级语言模型
├── tiny_char_lm_export.py      导出 checkpoint → 固件头文件
├── w4a8_common.py              W4A8 打包 / 定点 golden 计算
├── w4a8_block_full.py          完整 block 整数 golden（Python）
├── w4a8_block_rtl_export.py    生成 BRAM init hex + RTL 常量头文件
├── w4a8_cpu_ref_export.py      导出 CPU 参考权重/缩放系数
├── w4a8_engine_vectors.py      生成引擎仿真测试向量
├── w4a8_ffn_scales_export.py   导出 FFN 层缩放系数
├── update_test1_hex.ps1        固件重编译 → 更新 test2.hex（PowerShell）
└── run_soc_uart_diag.tcl       SoC 级 UART 诊断仿真脚本

tests/                          pytest 测试（Python/C 逐位比对）
data/input.txt                  字符级 LM 训练语料
```

---

## 复现步骤

### 1. 训练模型

```bash
python tools/tiny_char_lm.py          # 输出到 out/tiny_char_lm.pt
```

### 2. 导出权重，生成 BRAM 初始化 hex

```bash
python tools/w4a8_block_rtl_export.py   # → fpga/bram_init/
python tools/w4a8_cpu_ref_export.py     # → fpga/firmware/application/w4a8_cpu_ref_weights.h
python tools/w4a8_ffn_scales_export.py  # → fpga/firmware/application/w4a8_ffn_scales.h
```

### 3. 运行 Python 单元测试

```bash
pytest tests/ -q
```

### 4. Vivado 综合实现

打开 `fpga/vivado/trans.xpr`，在 Tcl Console 执行：

```tcl
reset_run synth_1
launch_runs synth_1 -jobs 8
# 综合完成后：
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
```

### 5. 编译固件

```powershell
# 先配置 Nuclei Studio 工具链路径
$env:PATH = 'D:\...\NucleiStudio\toolchain\gcc\bin;...' + $env:PATH
cd fpga/firmware/Debug
make all
```

重新生成 test2.hex（嵌入 bitstream 的 ITCM 初始化文件）：

```powershell
pwsh -File tools/update_test1_hex.ps1
```

更新 test2.hex 后需在 Vivado 中重跑 `impl_1` 以将新固件嵌入 bitstream（ITCM 是 BRAM 初始化的）。

### 6. 烧写并读取 UART

通过 Vivado Hardware Manager 烧写 bitstream。使用串口终端以 **115200 8N1** 连接，预期输出：

```
W4A8 per-layer CPU vs FPGA baseline
  layer0_qkv  384x128  CPU=1412008  FPGA_engine=4488   speedup engine=x314.61
  layer0_proj 128x128  CPU=470696   FPGA_engine=1496   speedup engine=x314.63
  lm_head      64x128  CPU=235368   FPGA_engine=748    speedup engine=x314.66
  AGG speedup call=x162.97 engine=x314.62
CPU BASELINE PASS

Transformer Block Accelerator
  block_out bit-exact PASS (0 / 128 mismatches)
  CPU block bit-exact vs golden : PASS (0 / 128)
  CPU block cycles      = 3996987
  FPGA block cycles     = 28999 (engine), 30928 (call)
  block speedup engine  = x137.83
  block speedup call    = x129.23
FULL BLOCK PASS
```

---

## 硬件平台

| 项目 | 规格 |
|------|------|
| 开发板 | ALINX AXU3EG（Zynq UltraScale+ XCZU3EG） |
| 软核 SoC | E203 RISC-V（HummingBird v2，15 MHz） |
| 加速器时钟 | 100 MHz（MMCM 由 200 MHz 差分输入分频） |
| ILM（指令存储器） | 64 KB @ 0x8000\_0000 |
| DTCM（数据存储器） | 64 KB @ 0x9000\_0000 |
| 加速器 MMIO 基地址 | 0x1000\_8000 |

## 依赖环境

- **Vivado 2019.2+**（综合与实现）
- **Nuclei Studio 2022.12**（RISC-V GCC 工具链，用于固件编译）
- **Python 3.9+**，需安装 `torch`、`numpy`、`pytest`
- **iverilog**（可选，用于不依赖 Vivado 的 RTL 仿真）
