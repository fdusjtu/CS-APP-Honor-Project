#!/usr/bin/env python3
"""Quantize a trained tiny_char_lm checkpoint and emit a C header.

All Linear weights are quantized per-row with symmetric INT4 encoding,
sharing the wire format with the Phase 2 W4A8 accelerator:

  - INT4 row-major, 8 nibbles per 32-bit word, LSN at bits [3:0]
  - INT16 Q-format scale (DEFAULT_SHIFT from tools/w4a8_gen_vectors.py)
  - scale_i = max(|W[i, :]|) / 7
  - W_q[i, :] = clip(round(W[i, :] / scale_i), -8, 7)

Non-accelerator tensors (embedding, LayerNorm gamma/beta) are emitted
as FP32 arrays; the CPU side handles them in software during inference.

The script reads the model config from the checkpoint and emits one
quantized set per transformer block (tlm_layer0_*, tlm_layer1_*, ...).

Usage:
  python tools/tiny_char_lm_export.py \
      --checkpoint out/tiny_char_lm.pt \
      --header out/tiny_char_lm.h
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from w4a8_common import (  # noqa: E402
    DEFAULT_SHIFT,
    TILE_M,
    TILE_N,
    pack_int16_values,
    pack_int4_matrix,
)


def quantize_linear_per_row(weight: np.ndarray) -> tuple[np.ndarray, np.ndarray, dict]:
    if weight.ndim != 2:
        raise ValueError(f"expected 2D weight, got shape {weight.shape}")
    max_abs = np.maximum(np.abs(weight).max(axis=1), 1e-8)
    real_scale = max_abs / 7.0

    quantized = np.round(weight / real_scale[:, None]).astype(np.int32)
    quantized = np.clip(quantized, -8, 7).astype(np.int8)

    scale_q = np.round(real_scale * (1 << DEFAULT_SHIFT)).astype(np.int64)
    saturated = int(((scale_q < 1) | (scale_q > 32767)).sum())
    scale_q = np.clip(scale_q, 1, 32767).astype(np.int16)

    dequant = quantized.astype(np.float32) * (
        scale_q.astype(np.float32) / (1 << DEFAULT_SHIFT)
    )[:, None]
    err = weight - dequant
    stats = {
        "max_abs_err": float(np.abs(err).max()),
        "rms_err": float(np.sqrt((err * err).mean())),
        "weight_max_abs": float(np.abs(weight).max()),
        "scale_saturated_rows": saturated,
    }
    return quantized, scale_q, stats


def check_tile_compat(name: str, M: int, N: int) -> None:
    if M % TILE_M != 0:
        raise ValueError(f"{name}: M={M} not a multiple of TILE_M={TILE_M}")
    if N % TILE_N != 0:
        raise ValueError(f"{name}: N={N} not a multiple of TILE_N={TILE_N}")


def format_u32_array(name: str, values: Sequence[int], per_line: int = 4) -> str:
    lines = [f"static const uint32_t {name}[{len(values)}] = {{"]
    for base in range(0, len(values), per_line):
        chunk = values[base : base + per_line]
        suffix = "," if base + per_line < len(values) else ""
        lines.append(
            "    " + ", ".join(f"0x{v & 0xFFFFFFFF:08x}u" for v in chunk) + suffix
        )
    lines.append("};")
    return "\n".join(lines)


def format_f32_array(name: str, values: Sequence[float], per_line: int = 4) -> str:
    lines = [f"static const float {name}[{len(values)}] = {{"]
    for base in range(0, len(values), per_line):
        chunk = values[base : base + per_line]
        suffix = "," if base + per_line < len(values) else ""
        lines.append("    " + ", ".join(f"{v:.8e}f" for v in chunk) + suffix)
    lines.append("};")
    return "\n".join(lines)


def pack_int4_row_major(W_q: np.ndarray) -> list[int]:
    M, N = W_q.shape
    if (M * N) % 8 != 0:
        raise ValueError(f"row-major packing needs M*N multiple of 8, got {M*N}")
    flat = W_q.reshape(-1).astype(int).tolist()
    return pack_int4_matrix([flat])


def emit_linear(
    out: list[str],
    prefix: str,
    weight: torch.Tensor,
    stats_report: list[str],
) -> None:
    W = weight.detach().cpu().numpy().astype(np.float32)
    M, N = W.shape
    check_tile_compat(prefix, M, N)
    W_q, scale_q, stats = quantize_linear_per_row(W)
    w_words = pack_int4_row_major(W_q)
    s_words = pack_int16_values(scale_q.tolist())

    out.append(f"/* {prefix}: Linear {M}x{N} (int4, per-row Q{DEFAULT_SHIFT} scale) */")
    out.append(f"#define {prefix.upper()}_M {M}")
    out.append(f"#define {prefix.upper()}_N {N}")
    out.append(format_u32_array(f"{prefix}_w_packed", w_words))
    out.append("")
    out.append(format_u32_array(f"{prefix}_scale_packed", s_words))
    out.append("")

    stats_report.append(
        f"  {prefix:24s}  shape={M:4d}x{N:<4d}  "
        f"|W|max={stats['weight_max_abs']:.4f}  "
        f"err_max={stats['max_abs_err']:.4f}  "
        f"err_rms={stats['rms_err']:.4f}  "
        f"sat_rows={stats['scale_saturated_rows']}"
    )


def emit_fp32_tensor(out: list[str], prefix: str, weight: torch.Tensor) -> None:
    W = weight.detach().cpu().numpy().astype(np.float32)
    if W.ndim == 1:
        out.append(f"#define {prefix.upper()}_LEN {W.shape[0]}")
        out.append(format_f32_array(prefix, W.tolist()))
    else:
        rows, cols = W.shape
        out.append(f"#define {prefix.upper()}_ROWS {rows}")
        out.append(f"#define {prefix.upper()}_COLS {cols}")
        out.append(format_f32_array(prefix, W.reshape(-1).tolist()))
    out.append("")


def format_i8_array(name: str, values: Sequence[int], per_line: int = 16) -> str:
    lines = [f"static const int8_t {name}[{len(values)}] = {{"]
    for base in range(0, len(values), per_line):
        chunk = values[base : base + per_line]
        suffix = "," if base + per_line < len(values) else ""
        lines.append("    " + ", ".join(f"{v:4d}" for v in chunk) + suffix)
    lines.append("};")
    return "\n".join(lines)


def emit_int8_embedding(out: list[str], prefix: str, weight: torch.Tensor,
                        stats_report: list[str]) -> None:
    """Quantize a 2D embedding table to int8 with one global scale.

    Stored as row-major int8; readers dequantize via val * scale_float.
    """
    W = weight.detach().cpu().numpy().astype(np.float32)
    if W.ndim != 2:
        raise ValueError(f"{prefix}: expected 2D embedding, got {W.shape}")
    rows, cols = W.shape

    max_abs = float(np.abs(W).max())
    if max_abs < 1e-8:
        max_abs = 1e-8
    scale = max_abs / 127.0
    W_q = np.round(W / scale).astype(np.int32)
    W_q = np.clip(W_q, -128, 127).astype(np.int8)
    dequant = W_q.astype(np.float32) * scale
    err = W - dequant

    out.append(f"#define {prefix.upper()}_ROWS {rows}")
    out.append(f"#define {prefix.upper()}_COLS {cols}")
    out.append(f"#define {prefix.upper()}_SCALE {scale:.8e}f")
    out.append(format_i8_array(f"{prefix}_i8", W_q.reshape(-1).tolist()))
    out.append("")

    stats_report.append(
        f"  {prefix:24s}  shape={rows:4d}x{cols:<4d}  "
        f"|W|max={max_abs:.4f}  scale={scale:.6f}  "
        f"err_max={float(np.abs(err).max()):.4f}  "
        f"err_rms={float(np.sqrt((err*err).mean())):.4f}"
    )


def emit_vocab_table(out: list[str], itos: dict[int, str]) -> None:
    chars_ordered = [itos[i] for i in range(len(itos))]
    out.append("/* itos: char code at index i (includes non-printables like '\\n'). */")
    out.append(f"static const char tlm_itos[{len(chars_ordered)}] = {{")
    for base in range(0, len(chars_ordered), 8):
        chunk = chars_ordered[base : base + 8]
        suffix = "," if base + 8 < len(chars_ordered) else ""
        formatted = ", ".join(f"0x{ord(ch):02x}" for ch in chunk)
        out.append("    " + formatted + suffix)
    out.append("};")
    out.append("")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"))
    parser.add_argument("--header", type=Path, default=Path("out/tiny_char_lm.h"))
    args = parser.parse_args()

    if not args.checkpoint.exists():
        raise FileNotFoundError(f"checkpoint not found: {args.checkpoint}")

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    sd = ckpt["model"]
    cfg = ckpt["config"]
    stoi = ckpt["stoi"]
    itos = ckpt["itos"]

    out: list[str] = []
    stats: list[str] = []

    out.append("#ifndef TINY_CHAR_LM_H")
    out.append("#define TINY_CHAR_LM_H")
    out.append("")
    out.append("#include <stdint.h>")
    out.append("")
    out.append(f"#define TLM_VOCAB        {cfg['vocab']}")
    out.append(f"#define TLM_HIDDEN       {cfg['hidden']}")
    out.append(f"#define TLM_FFN          {cfg['ffn']}")
    out.append(f"#define TLM_SEQ_LEN      {cfg['seq_len']}")
    out.append(f"#define TLM_N_LAYERS     {cfg['layers']}")
    out.append(f"#define TLM_N_HEADS      {cfg['heads']}")
    out.append(f"#define TLM_HEAD_DIM     {cfg['hidden'] // cfg['heads']}")
    out.append(f"#define TLM_QUANT_SHIFT  {DEFAULT_SHIFT}")
    out.append("")

    emit_vocab_table(out, itos)

    emit_int8_embedding(out, "tlm_tok_emb", sd["tok_emb.weight"], stats)
    emit_int8_embedding(out, "tlm_pos_emb", sd["pos_emb.weight"], stats)

    for layer in range(cfg["layers"]):
        emit_fp32_tensor(out, f"tlm_layer{layer}_ln1_gamma", sd[f"blocks.{layer}.ln1.weight"])
        emit_fp32_tensor(out, f"tlm_layer{layer}_ln1_beta", sd[f"blocks.{layer}.ln1.bias"])
        emit_linear(out, f"tlm_layer{layer}_qkv", sd[f"blocks.{layer}.qkv.weight"], stats)
        emit_linear(out, f"tlm_layer{layer}_proj", sd[f"blocks.{layer}.proj.weight"], stats)
        emit_fp32_tensor(out, f"tlm_layer{layer}_ln2_gamma", sd[f"blocks.{layer}.ln2.weight"])
        emit_fp32_tensor(out, f"tlm_layer{layer}_ln2_beta", sd[f"blocks.{layer}.ln2.bias"])
        emit_linear(out, f"tlm_layer{layer}_ffn_up", sd[f"blocks.{layer}.ffn_up.weight"], stats)
        emit_linear(out, f"tlm_layer{layer}_ffn_down", sd[f"blocks.{layer}.ffn_down.weight"], stats)

    emit_fp32_tensor(out, "tlm_lnf_gamma", sd["ln_f.weight"])
    emit_fp32_tensor(out, "tlm_lnf_beta", sd["ln_f.bias"])
    emit_linear(out, "tlm_lm_head", sd["lm_head.weight"], stats)

    out.append("#endif")
    out.append("")

    args.header.parent.mkdir(parents=True, exist_ok=True)
    args.header.write_text("\n".join(out), encoding="ascii")
    size_kb = args.header.stat().st_size / 1024.0
    print(f"exported header: {args.header}  ({size_kb:.1f} KB)")
    print(f"config: {cfg}")
    print("per-linear quantization stats:")
    for line in stats:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
