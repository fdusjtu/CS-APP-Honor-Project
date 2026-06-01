#!/usr/bin/env python3
"""Emit a small TinyCharLM smoke-test header for the W4A8 firmware.

This is intentionally smaller than tiny_char_lm_export.py: it keeps only
one token embedding row, packed as INT8 activations, plus the quantized
lm_head Linear. It is meant to verify the FPGA W4A8 path before the full
TinyLM C runtime exists.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tiny_char_lm_export import format_u32_array, quantize_linear_per_row  # noqa: E402
from w4a8_common import DEFAULT_SHIFT, pack_int16_values, pack_int4_matrix  # noqa: E402


ACT_SCALE = 16


def pack_int4_row_major(w_q: np.ndarray) -> list[int]:
    flat = w_q.reshape(-1).astype(int).tolist()
    return pack_int4_matrix([flat])


def pack_i8(values: Sequence[int]) -> list[int]:
    if len(values) % 4 != 0:
        raise ValueError(f"INT8 activation length must be multiple of 4, got {len(values)}")
    words: list[int] = []
    for base in range(0, len(values), 4):
        word = 0
        for i in range(4):
            word |= (values[base + i] & 0xFF) << (8 * i)
        words.append(word)
    return words


def emit_itos(out: list[str], itos: dict[int, str]) -> None:
    out.append(f"static const char tcs_itos[{len(itos)}] = {{")
    for base in range(0, len(itos), 8):
        chunk = [itos[i] for i in range(base, min(base + 8, len(itos)))]
        suffix = "," if base + 8 < len(itos) else ""
        out.append("    " + ", ".join(f"0x{ord(ch):02x}" for ch in chunk) + suffix)
    out.append("};")
    out.append("")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"))
    parser.add_argument("--header", type=Path, default=Path("out/tiny_char_lm_smoke.h"))
    parser.add_argument("--token", type=int, default=0)
    args = parser.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    cfg = ckpt["config"]
    sd = ckpt["model"]
    itos = ckpt["itos"]

    vocab = int(cfg["vocab"])
    hidden = int(cfg["hidden"])
    if args.token < 0 or args.token >= vocab:
        raise ValueError(f"token {args.token} outside vocab size {vocab}")

    lm_head = sd["lm_head.weight"].detach().cpu().numpy().astype(np.float32)
    w_q, scale_q, stats = quantize_linear_per_row(lm_head)
    w_words = pack_int4_row_major(w_q)
    scale_words = pack_int16_values(scale_q.tolist())

    emb = sd["tok_emb.weight"][args.token].detach().cpu().numpy().astype(np.float32)
    x_i8 = np.clip((emb * ACT_SCALE).astype(np.int32), -128, 127).astype(np.int8)
    x_words = pack_i8(x_i8.astype(int).tolist())

    out: list[str] = []
    out.append("#ifndef TINY_CHAR_LM_SMOKE_H")
    out.append("#define TINY_CHAR_LM_SMOKE_H")
    out.append("")
    out.append("#include <stdint.h>")
    out.append("")
    out.append(f"#define TCS_VOCAB       {vocab}")
    out.append(f"#define TCS_HIDDEN      {hidden}")
    out.append(f"#define TCS_TOKEN       {args.token}")
    out.append(f"#define TCS_SHIFT       {DEFAULT_SHIFT}")
    out.append(f"#define TCS_ACT_SCALE   {ACT_SCALE}")
    out.append("")
    emit_itos(out, itos)
    out.append(format_u32_array("tcs_x_packed", x_words))
    out.append("")
    out.append(format_u32_array("tcs_lm_head_w_packed", w_words))
    out.append("")
    out.append(format_u32_array("tcs_lm_head_scale_packed", scale_words))
    out.append("")
    out.append("#endif")
    out.append("")

    args.header.parent.mkdir(parents=True, exist_ok=True)
    args.header.write_text("\n".join(out), encoding="ascii")
    print(f"exported smoke header: {args.header} ({args.header.stat().st_size / 1024:.1f} KB)")
    print(
        "lm_head quantization: "
        f"max_abs_err={stats['max_abs_err']:.4f} "
        f"rms_err={stats['rms_err']:.4f} "
        f"sat_rows={stats['scale_saturated_rows']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
