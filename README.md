# W4A8 Transformer Block FPGA Accelerator

A complete hardware accelerator for a quantized Transformer block, implemented on the **ALINX AXU3EG** board (Zynq UltraScale+ MPSoC) with an **E203 RISC-V soft-core SoC**.

Board-verified results (2026-06-03):

```
block speedup vs true all-CPU baseline:  engine x137.83 / call x129.23
per-layer (qkv 384×128):                 engine x314.6  / call x169.9
```

---

## What This Implements

### Quantization Scheme — W4A8

- **Weights**: INT4, per-row scale (INT16, Q-format shift=14)
- **Activations**: INT8
- **Accumulator**: INT32
- Weights stored packed: 8 nibbles per 32-bit word, LSN-first, row-major

### Transformer Block (one layer, seq_len=2)

```
hidden_in (INT8, 128)
    │
    ├─ LayerNorm 1 (integer isqrt + LUT)
    ├─ QKV Linear  384×128  W4A8 ──┐
    ├─ Attention (Q·K, softmax, ·V)│  all in hardware
    ├─ Proj Linear 128×128  W4A8  ─┤
    ├─ Residual 1                  │
    ├─ LayerNorm 2                 │
    ├─ FFN-up Linear 256×128 W4A8 ─┤
    ├─ GELU (LUT)                  │
    └─ FFN-down Linear 128×256 W4A8┘
         │
    block_out (INT32, 128)
```

Model: tiny character-level LM — vocab=64, hidden=128, ffn=256, 2 layers, 1 head.

### Hardware Architecture

```
E203 RISC-V core (15 MHz)
    │  ICB (memory-mapped)
    ▼
w4a8_block_engine  @ 0x1000_8000
    ├── w4a8_core          — 16-wide INT4×INT8 MAC array (Linear layers)
    ├── w4a8_ln_unit        — integer LayerNorm (isqrt FSM)
    ├── w4a8_attn_unit      — dot-product attention + softmax
    ├── w4a8_gelu_unit      — GELU via 256-entry LUT
    ├── w4a8_residual_unit  — residual add with requantisation
    ├── w4a8_resident_wmem  — 16-bank BRAM, weights loaded at bitstream init
    └── w4a8_resident_smem  — BRAM for per-row scales
```

Weights and scales are initialised directly from BRAM init hex at bitstream load time — no CPU boot-time weight transfer needed.

---

## Repository Layout

```
lecture2_0420_release/
├── trans/
│   ├── trans.xpr                   Vivado project file
│   └── trans.srcs/
│       ├── sources_1/new/          RTL source (w4a8_*.v/.vh)
│       ├── sources_1/imports/e203/ E203 RISC-V SoC upstream source
│       ├── sim_1/new/              Testbenches (tb_w4a8_*.v)
│       └── constrs_1/              XDC constraints
├── test1/application/              Firmware source (C)
│   ├── main.c                      Top-level demo + benchmark
│   ├── w4a8.h                      MMIO register map + driver
│   ├── w4a8_block_fpga.c/.h        FPGA block demo + speedup measurement
│   ├── w4a8_block_cpu.c/.h         True all-CPU baseline (Method A readback)
│   ├── w4a8_ops.c/.h               Integer LN / GELU / softmax / requant
│   └── w4a8_cpu_ref.c/.h           Per-layer CPU GEMV reference
├── hexdump-2.1.0/
│   ├── test1.bin / test1.hex       Compiled firmware binary
│   └── test2.hex                   ITCM init hex (loaded into bitstream)
└── bram_init/                      BRAM initialisation hex (weights/scales)

tools/
├── tiny_char_lm.py                 Train the tiny character LM
├── tiny_char_lm_export.py          Export checkpoint → firmware headers
├── w4a8_common.py                  W4A8 packing / golden computation
├── w4a8_block_full.py              Full block integer golden (Python)
├── w4a8_block_rtl_export.py        Generate BRAM init hex + RTL constants
├── w4a8_cpu_ref_export.py          Export CPU reference weights/scales
├── w4a8_engine_vectors.py          Generate engine test vectors
├── w4a8_ffn_scales_export.py       Export FFN layer scales
├── update_test1_hex.ps1            Rebuild firmware → test2.hex (PowerShell)
└── run_soc_uart_diag.tcl           SoC-level UART diagnostic simulation

tests/                              pytest — bit-exact Python/C cross-checks
data/input.txt                      Character LM training corpus
```

---

## How to Reproduce

### 1. Train the model

```bash
python tools/tiny_char_lm.py          # writes out/tiny_char_lm.pt
```

### 2. Export weights and generate BRAM init hex

```bash
python tools/w4a8_block_rtl_export.py   # → lecture2_0420_release/bram_init/
python tools/w4a8_cpu_ref_export.py     # → w4a8_cpu_ref_weights.h
python tools/w4a8_ffn_scales_export.py  # → w4a8_ffn_scales.h
```

### 3. Run Python tests

```bash
pytest tests/ -q
```

### 4. Synthesise and implement in Vivado

Open `lecture2_0420_release/trans/trans.xpr`, then in the Tcl Console:

```tcl
reset_run synth_1
launch_runs synth_1 -jobs 8
# after synth completes:
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
```

### 5. Build firmware

```powershell
# Add Nuclei Studio toolchain to PATH first
$env:PATH = 'D:\...\NucleiStudio\toolchain\gcc\bin;...' + $env:PATH
cd lecture2_0420_release/test1/Debug
make all
```

Then regenerate `test2.hex` (ITCM init for bitstream):

```powershell
pwsh -File tools/update_test1_hex.ps1
```

After updating `test2.hex`, re-run `impl_1` to embed the new firmware in the bitstream (ITCM is BRAM-initialised).

### 6. Program board and read UART

Program the bitstream via Vivado Hardware Manager. Connect a UART terminal at **115200 8N1**. Expected output:

```
W4A8 per-layer CPU vs FPGA baseline
  layer0_qkv  384x128  CPU=1412008  FPGA_engine=4488   speedup engine=x314.61
  layer0_proj 128x128  CPU=470696   FPGA_engine=1496   speedup engine=x314.63
  ...
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

## Hardware Platform

| Item | Detail |
|------|--------|
| Board | ALINX AXU3EG (Zynq UltraScale+ XCZU3EG) |
| SoC | E203 RISC-V (HummingBird v2, 15 MHz) |
| Accelerator clock | 100 MHz (MMCM from 200 MHz diff input) |
| ILM (instruction memory) | 64 KB @ 0x8000\_0000 |
| DTCM (data memory) | 64 KB @ 0x9000\_0000 |
| Accelerator MMIO | 0x1000\_8000 |

---

## Dependencies

- **Vivado 2019.2+** (synthesis and implementation)
- **Nuclei Studio 2022.12** (RISC-V GCC toolchain for firmware)
- **Python 3.9+** with `torch`, `numpy`, `pytest`
- **iverilog** (optional, for RTL simulation without Vivado)
