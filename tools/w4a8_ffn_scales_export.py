#!/usr/bin/env python3
"""Export FFN per-row INT16 scales for the true all-CPU Transformer block.

Method-A CPU block baseline reads ffn_up / ffn_down INT4 weights back from FPGA
BRAM at boot, but still needs the per-row scales in memory to finish each GEMV.
qkv / proj scales already live in w4a8_cpu_ref_weights.h; this script emits only
the two missing FFN scale arrays (layer0_ffn_up: 256, layer0_ffn_down: 128),
taken from the exact same build_vectors() source as the resident smem image, so
they match the FPGA engine bit-exactly.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from w4a8_engine_vectors import (  # noqa: E402
    TARGET_CONFIG,
    _checkpoint_layers,
    build_vectors,
)

FFN_LAYERS = ("layer0_ffn_up", "layer0_ffn_down")


def _format_scale(name: str, values: Sequence[int]) -> list[str]:
    lines = [f"static const int16_t {name}[{len(values)}] = {{"]
    for base in range(0, len(values), 8):
        chunk = values[base:base + 8]
        lines.append("    " + ", ".join(f"{v:6d}" for v in chunk) + ",")
    lines.append("};")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"))
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("fpga/firmware/application/w4a8_ffn_scales.h"),
    )
    parser.add_argument("--seed", type=int, default=1, help="must match engine vectors seed")
    args = parser.parse_args()

    if args.checkpoint.exists():
        weights, cfg = _checkpoint_layers(args.checkpoint)
        source = f"checkpoint {args.checkpoint}"
    else:
        weights, cfg = None, TARGET_CONFIG
        source = f"synthetic (seed={args.seed})"
    vec = build_vectors(cfg, args.seed, weights)
    by_name = {c["name"]: c for c in vec["cases"]}

    lines = [
        "#ifndef W4A8_FFN_SCALES_H",
        "#define W4A8_FFN_SCALES_H",
        "",
        "#include <stdint.h>",
        "",
        "/* Per-row INT16 scales for the FFN Linear layers, matching the resident",
        "   smem image. Weights themselves are read back from FPGA BRAM. */",
        "",
    ]
    for name in FFN_LAYERS:
        c = by_name[name]
        slug = name.replace("-", "_")
        lines.append(f"/* {slug}: M={c['M']}, N={c['N']} */")
        lines.extend(_format_scale(f"{slug}_scale", c["scale_q"]))
        lines.append("")
    lines.extend(["#endif", ""])

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines), encoding="ascii")

    print(f"source: {source}")
    for name in FFN_LAYERS:
        c = by_name[name]
        print(f"  {name:18s} M={c['M']:>3} N={c['N']:>3}  scale_entries={c['M']}")
    print(f"wrote: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
