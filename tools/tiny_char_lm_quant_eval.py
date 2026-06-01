#!/usr/bin/env python3
"""Validate that INT4 per-row quantization preserves tiny_char_lm quality.

For each nn.Linear inside the trained model:
  1. Quantize its weight per-row to INT4 + INT16 Q-format scale (same scheme
     as tools/tiny_char_lm_export.py uses for the C header).
  2. Dequantize back to FP32 in-place so PyTorch keeps running through the
     same architecture but with the quantization-equivalent weights.

Then run two diagnostics:
  - Logits comparison on a held-out validation batch: cosine similarity,
    L1 logit error, top-1 argmax match rate.
  - Side-by-side sampling with the same RNG seed: visually verify the
    quantized model still produces readable Shakespeare-ish text.

This is weight-only quantization; activation INT8 quantization between
layers is a separate validation step (not done here yet).

Usage:
  python tools/tiny_char_lm_quant_eval.py
  python tools/tiny_char_lm_quant_eval.py --prompt "ROMEO:" --length 500
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tiny_char_lm import TinyCharLM, get_batch, resolve_device, sample_inplace  # noqa: E402
from tiny_char_lm_export import quantize_linear_per_row  # noqa: E402
from w4a8_common import DEFAULT_SHIFT  # noqa: E402


def quantize_model_in_place(model: nn.Module, shift: int) -> list[dict]:
    """Replace every nn.Linear weight with its W4-then-dequantized FP32 form."""
    stats_list: list[dict] = []
    for name, module in model.named_modules():
        if not isinstance(module, nn.Linear):
            continue
        W = module.weight.detach().cpu().numpy().astype(np.float32)
        W_q, scale_q, stats = quantize_linear_per_row(W)
        scale_fp = scale_q.astype(np.float32) / float(1 << shift)
        W_dequant = W_q.astype(np.float32) * scale_fp[:, None]
        module.weight.data = torch.from_numpy(W_dequant.astype(np.float32)).to(
            module.weight.device
        )
        stats_list.append({"name": name, "shape": tuple(W.shape), **stats})
    return stats_list


@torch.no_grad()
def compare_logits(
    fp_model: nn.Module,
    q_model: nn.Module,
    data: torch.Tensor,
    cfg: dict,
    device: str,
    n_batches: int,
    batch_size: int,
) -> dict:
    fp_model.eval()
    q_model.eval()
    cos_sims: list[float] = []
    l1_errs: list[float] = []
    top1_matches: list[float] = []
    for _ in range(n_batches):
        x, _ = get_batch(data, batch_size, cfg["seq_len"], device)
        fp_logits = fp_model(x).reshape(-1, cfg["vocab"])
        q_logits = q_model(x).reshape(-1, cfg["vocab"])
        cos = F.cosine_similarity(fp_logits, q_logits, dim=-1).mean().item()
        l1 = (fp_logits - q_logits).abs().mean().item()
        match = (fp_logits.argmax(-1) == q_logits.argmax(-1)).float().mean().item()
        cos_sims.append(cos)
        l1_errs.append(l1)
        top1_matches.append(match)
    return {
        "cosine": float(np.mean(cos_sims)),
        "l1_err": float(np.mean(l1_errs)),
        "top1_match": float(np.mean(top1_matches)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"))
    parser.add_argument("--data", type=Path, default=Path("data/input.txt"))
    parser.add_argument(
        "--device", type=str, default="auto", choices=["auto", "cpu", "cuda"]
    )
    parser.add_argument("--prompt", type=str, default="ROMEO:\n")
    parser.add_argument("--length", type=int, default=400)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--n-batches", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()

    device = resolve_device(args.device)
    print(f"device: {device}")

    if not args.checkpoint.exists():
        raise FileNotFoundError(f"checkpoint not found: {args.checkpoint}")
    ckpt = torch.load(args.checkpoint, map_location=device, weights_only=False)
    cfg = ckpt["config"]
    stoi, itos = ckpt["stoi"], ckpt["itos"]
    print(f"config: {cfg}")
    print(f"quant shift: Q{DEFAULT_SHIFT}")

    fp_model = TinyCharLM(cfg).to(device)
    fp_model.load_state_dict(ckpt["model"])
    fp_model.eval()

    q_model = TinyCharLM(cfg).to(device)
    q_model.load_state_dict(ckpt["model"])
    print("\n--- quantizing every nn.Linear in place (per-row INT4) ---")
    stats_list = quantize_model_in_place(q_model, DEFAULT_SHIFT)
    for s in stats_list:
        shape_str = f"{s['shape'][0]:4d}x{s['shape'][1]:<4d}"
        print(
            f"  {s['name']:28s} shape={shape_str}  "
            f"|W|max={s['weight_max_abs']:.4f}  "
            f"err_max={s['max_abs_err']:.4f}  "
            f"err_rms={s['rms_err']:.4f}  "
            f"sat_rows={s['scale_saturated_rows']}"
        )
    q_model.eval()

    print("\n--- logits comparison on validation data ---")
    text = Path(args.data).read_text(encoding="utf-8")
    encoded = torch.tensor(
        [stoi[ch] for ch in text if ch in stoi], dtype=torch.long
    )
    split = int(0.9 * len(encoded))
    val_data = encoded[split:]

    torch.manual_seed(args.seed)
    metrics = compare_logits(
        fp_model, q_model, val_data, cfg, device, args.n_batches, args.batch_size
    )
    print(f"  cosine similarity:   {metrics['cosine']:.6f}  (1.0 = identical)")
    print(f"  L1 logit error:      {metrics['l1_err']:.4f}")
    print(f"  argmax top-1 match:  {metrics['top1_match']:.4f}  (1.0 = identical)")

    # Quick verdict on whether quantization is acceptable.
    cos_threshold = 0.99
    top1_threshold = 0.90
    if metrics["cosine"] >= cos_threshold and metrics["top1_match"] >= top1_threshold:
        verdict = (
            f"PASS  (cosine >= {cos_threshold:.2f} and top1 >= {top1_threshold:.2f})"
        )
    elif metrics["cosine"] >= 0.95:
        verdict = "MARGINAL  (W4 noticeably degraded but probably still usable)"
    else:
        verdict = "FAIL  (W4 likely destroyed the model -- need to rethink quant)"
    print(f"  verdict: {verdict}")

    torch.manual_seed(args.seed)
    print("\n--- FP32 sample (reference) ---")
    sample_inplace(
        fp_model, cfg, stoi, itos,
        args.prompt, args.length, args.temperature, device,
    )

    torch.manual_seed(args.seed)
    print("\n--- W4 quantized sample (same seed) ---")
    sample_inplace(
        q_model, cfg, stoi, itos,
        args.prompt, args.length, args.temperature, device,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
