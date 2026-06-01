#!/usr/bin/env python3
"""Generate banked resident layout + test vectors for the w4a8_linear_engine.

This is the Step 2 deliverable for the resident-weight Linear engine. Unlike
``w4a8_gen_vectors.py`` (which targets the old 16x64 tile primitive), this
script lays the full target model out the way the engine consumes it:

  - 16-bank resident weight memory: bank = row % 16, packed INT4, 8 nibbles
    per 32-bit word. The flat W_LOAD index maps as
        bank      = W_LOAD_ADDR[3:0]
        bank_addr = W_LOAD_ADDR >> 4
  - resident scale memory: per-row INT16 scale, 2 per 32-bit word, addressed
        word_addr = s_base + row // 2 ; half = row % 2
  - per-layer descriptors (M, N, w_base[bank_addr], s_base[word]).

The numerical golden is identical to ``golden_linear`` (W4 x INT8 -> INT32
acc -> per-row Q2.14 rescale); only the memory layout differs. The engine,
after loading the banked stream and reading it back via its address formula,
must reconstruct the original row-major weights bit-for-bit -- the self-test
checks exactly that.

Usage:
  python tools/w4a8_engine_vectors.py                 # synthetic, default out dir
  python tools/w4a8_engine_vectors.py --checkpoint out/tiny_char_lm.pt
  python tools/w4a8_engine_vectors.py --self-test
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from w4a8_common import (  # noqa: E402
    DEFAULT_SHIFT,
    TILE_M,
    TILE_N,
    _sign_extend,
    golden_linear,
    pack_int8_values,
    pack_int16_values,
    pack_int32_values,
    write_hex_words,
)

# RTL-fixed resident weight memory geometry (see project_progress.md).
WMEM_BANK_DEPTH = 4096
SMEM_DEPTH = 1024
N_BANKS = 16

# Frozen target model (vocab=64, hidden=128, ffn=256, layers=2, heads=1).
TARGET_CONFIG = {"vocab": 64, "hidden": 128, "ffn": 256, "layers": 2}


def build_layer_table(cfg: dict) -> list[dict]:
    """Ordered Linear layer table; index in the list is the engine layer_id."""
    h, f, v, n_layers = cfg["hidden"], cfg["ffn"], cfg["vocab"], cfg["layers"]
    layers: list[dict] = []
    for li in range(n_layers):
        layers.append({"name": f"layer{li}_qkv", "M": 3 * h, "N": h})
        layers.append({"name": f"layer{li}_proj", "M": h, "N": h})
        layers.append({"name": f"layer{li}_ffn_up", "M": f, "N": h})
        layers.append({"name": f"layer{li}_ffn_down", "M": h, "N": f})
    layers.append({"name": "lm_head", "M": v, "N": h})
    for layer_id, ly in enumerate(layers):
        ly["id"] = layer_id
    return layers


def assign_bases(layers: list[dict]) -> tuple[int, int]:
    """Fill w_base (bank_addr units) and s_base (32-bit word units) in place.

    Returns (total_bank_addr_slots, total_scale_words). Raises if any layer
    violates the tile/banking constraints or overflows resident memory.
    """
    w_base = 0
    s_base = 0
    for ly in layers:
        M, N = ly["M"], ly["N"]
        if M % TILE_M != 0:
            raise ValueError(f"{ly['name']}: M={M} not a multiple of {TILE_M}")
        if N % TILE_N != 0:
            raise ValueError(f"{ly['name']}: N={N} not a multiple of {TILE_N}")
        ly["w_base"] = w_base
        ly["s_base"] = s_base
        w_base += (M // N_BANKS) * (N // 8)  # bank_addr slots
        s_base += M // 2                     # INT16 scales, 2 per word
    if w_base > WMEM_BANK_DEPTH:
        raise ValueError(
            f"max bank_addr {w_base} exceeds WMEM_BANK_DEPTH {WMEM_BANK_DEPTH}"
        )
    return w_base, s_base


def _pack_nibbles(nibbles: Sequence[int]) -> int:
    """Pack up to 8 signed INT4 values into one 32-bit word, nibble0 at [3:0]."""
    word = 0
    for idx, value in enumerate(nibbles):
        if value < -8 or value > 7:
            raise ValueError(f"int4 value {value} outside [-8, 7]")
        word |= (value & 0xF) << (4 * idx)
    return word


def bank_pack_layer(W_q: Sequence[Sequence[int]]) -> list[int]:
    """Banked W_LOAD_DATA stream for one MxN layer, in CPU write order.

    Order: for each row_tile, for each col_word, for each bank (0..15).
    Result length == (M/16) * (N/8) * 16 == M*N/8.
    """
    M = len(W_q)
    N = len(W_q[0])
    n_col_words = N // 8
    words: list[int] = []
    for row_tile in range(M // N_BANKS):
        for col_word in range(n_col_words):
            for bank in range(N_BANKS):
                row = row_tile * N_BANKS + bank
                base = col_word * 8
                words.append(_pack_nibbles(W_q[row][base:base + 8]))
    return words


def engine_read_nibble(
    flat_words: Sequence[int], w_base: int, N: int, row: int, col: int
) -> int:
    """Reconstruct W_q[row][col] from the flat banked stream via the engine's
    read-address formula. Used to prove the load layout round-trips."""
    row_tile = row // N_BANKS
    bank = row % N_BANKS
    col_word = col // 8
    nib_idx = col % 8
    bank_addr = w_base + row_tile * (N // 8) + col_word
    flat_idx = bank_addr * N_BANKS + bank
    word = flat_words[flat_idx]
    return _sign_extend((word >> (4 * nib_idx)) & 0xF, 4)


def scale_pack_layer(scale_q: Sequence[int]) -> list[int]:
    """Per-row INT16 scales packed 2 per word in row order (row r -> word r//2,
    half r%2)."""
    return pack_int16_values(list(scale_q))


# --- synthetic per-row INT4 quantized weights (no torch / training dependency) ---

def _synth_layer(rng: random.Random, M: int, N: int) -> tuple[list[list[int]], list[int]]:
    """AWQ-like per-row quantized slice: INT4 weights + INT16 Q14 row scales."""
    W_q: list[list[int]] = []
    scale_q: list[int] = []
    for _ in range(M):
        fp_row = [rng.gauss(0.0, 0.18) for _ in range(N)]
        max_abs = max(abs(v) for v in fp_row) or 1.0
        real_scale = max_abs / 7.0
        W_q.append([max(-8, min(7, round(v / real_scale))) for v in fp_row])
        scale_q.append(max(1, min(32767, round(real_scale * (1 << DEFAULT_SHIFT)))))
    return W_q, scale_q


def _checkpoint_layers(ckpt_path: Path) -> dict[str, tuple[list[list[int]], list[int]]]:
    """Load real per-row INT4 weights from a trained checkpoint, keyed by layer name."""
    import numpy as np
    import torch

    from tiny_char_lm_export import quantize_linear_per_row

    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    sd = ckpt["model"]
    cfg = ckpt["config"]

    def quant(weight) -> tuple[list[list[int]], list[int]]:
        W = weight.detach().cpu().numpy().astype(np.float32)
        W_q, scale_q, _ = quantize_linear_per_row(W)
        return W_q.astype(int).tolist(), scale_q.astype(int).tolist()

    out: dict[str, tuple[list[list[int]], list[int]]] = {}
    for li in range(cfg["layers"]):
        out[f"layer{li}_qkv"] = quant(sd[f"blocks.{li}.qkv.weight"])
        out[f"layer{li}_proj"] = quant(sd[f"blocks.{li}.proj.weight"])
        out[f"layer{li}_ffn_up"] = quant(sd[f"blocks.{li}.ffn_up.weight"])
        out[f"layer{li}_ffn_down"] = quant(sd[f"blocks.{li}.ffn_down.weight"])
    out["lm_head"] = quant(sd["lm_head.weight"])
    return out, cfg


def build_vectors(
    cfg: dict,
    seed: int,
    weights: dict[str, tuple[list[list[int]], list[int]]] | None,
) -> dict:
    """Assemble descriptors, resident streams, per-layer activations and golden y."""
    layers = build_layer_table(cfg)
    total_bank_slots, total_scale_words = assign_bases(layers)

    rng = random.Random(seed)
    w_load_stream: list[int] = []
    s_load_stream: list[int] = []
    cases: list[dict] = []

    for ly in layers:
        M, N = ly["M"], ly["N"]
        if weights is not None:
            W_q, scale_q = weights[ly["name"]]
            if len(W_q) != M or len(W_q[0]) != N:
                raise ValueError(
                    f"{ly['name']}: checkpoint shape {len(W_q)}x{len(W_q[0])} "
                    f"!= expected {M}x{N}"
                )
        else:
            W_q, scale_q = _synth_layer(rng, M, N)

        # banked stream offset must match descriptor w_base (in flat words).
        assert len(w_load_stream) == ly["w_base"] * N_BANKS, ly["name"]
        assert len(s_load_stream) == ly["s_base"], ly["name"]
        w_load_stream.extend(bank_pack_layer(W_q))
        s_load_stream.extend(scale_pack_layer(scale_q))

        x = [rng.randint(-128, 127) for _ in range(N)]
        y = golden_linear(W_q, x, scale_q, DEFAULT_SHIFT)
        cases.append(
            {
                "id": ly["id"],
                "name": ly["name"],
                "M": M,
                "N": N,
                "w_base": ly["w_base"],
                "s_base": ly["s_base"],
                "W_q": W_q,
                "scale_q": scale_q,
                "x": x,
                "y": y,
            }
        )

    return {
        "layers": layers,
        "w_load_stream": w_load_stream,
        "s_load_stream": s_load_stream,
        "cases": cases,
        "total_bank_slots": total_bank_slots,
        "total_scale_words": total_scale_words,
    }


def self_test(cfg: dict | None = None) -> None:
    """Bank-mapping + golden round-trip checks. Raises AssertionError on failure."""
    cfg = cfg or TARGET_CONFIG
    vec = build_vectors(cfg, seed=1, weights=None)
    flat = vec["w_load_stream"]

    # 1. flat stream length equals sum of M*N/8 over layers.
    expect_words = sum(c["M"] * c["N"] // 8 for c in vec["cases"])
    assert len(flat) == expect_words, (len(flat), expect_words)
    assert vec["total_bank_slots"] * N_BANKS == expect_words

    # 2. banked stream reconstructs every weight bit-exactly for every layer.
    for c in vec["cases"]:
        W_q, M, N, w_base = c["W_q"], c["M"], c["N"], c["w_base"]
        rng = random.Random(c["id"] + 100)
        for _ in range(64):
            r = rng.randrange(M)
            col = rng.randrange(N)
            got = engine_read_nibble(flat, w_base, N, r, col)
            assert got == W_q[r][col], (c["name"], r, col, got, W_q[r][col])
        # corners
        for r in (0, M - 1):
            for col in (0, N - 1):
                assert engine_read_nibble(flat, w_base, N, r, col) == W_q[r][col]

    # 3. scale word layout: row r -> word s_base + r//2, half r%2.
    s = vec["s_load_stream"]
    for c in vec["cases"]:
        for r in range(0, c["M"], max(1, c["M"] // 8)):
            word = s[c["s_base"] + r // 2]
            half = (word >> (16 * (r % 2))) & 0xFFFF
            assert _sign_extend(half, 16) == c["scale_q"][r], (c["name"], r)

    # 4. descriptors are contiguous and within resident capacity.
    assert vec["total_bank_slots"] <= WMEM_BANK_DEPTH
    print(f"self-test PASS: {len(vec['cases'])} layers, "
          f"{len(flat)} weight words (max bank_addr {vec['total_bank_slots']}/"
          f"{WMEM_BANK_DEPTH}), {len(s)} scale words")


def _emit_c_header(vec: dict, path: Path) -> None:
    lines = [
        "#ifndef W4A8_ENGINE_VECTORS_H",
        "#define W4A8_ENGINE_VECTORS_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define W4A8E_N_LAYERS {len(vec['cases'])}",
        f"#define W4A8E_WMEM_BANK_DEPTH {WMEM_BANK_DEPTH}",
        f"#define W4A8E_W_WORDS {len(vec['w_load_stream'])}",
        f"#define W4A8E_S_WORDS {len(vec['s_load_stream'])}",
        f"#define W4A8E_SHIFT {DEFAULT_SHIFT}",
        "",
        "typedef struct { int m, n, w_base, s_base; } w4a8_layer_desc_t;",
        "",
        f"static const w4a8_layer_desc_t w4a8_descs[W4A8E_N_LAYERS] = {{",
    ]
    for c in vec["cases"]:
        lines.append(
            f"    {{ .m = {c['M']}, .n = {c['N']}, "
            f".w_base = {c['w_base']}, .s_base = {c['s_base']} }},"
            f"  /* id {c['id']}: {c['name']} */"
        )
    lines.append("};")
    lines.append("")
    lines.append("#endif")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="ascii")


def _format_c_array(
    name: str,
    c_type: str,
    values: Sequence[int],
    width: int = 8,
    size_expr: str | None = None,
) -> list[str]:
    size = size_expr if size_expr is not None else str(len(values))
    lines = [f"static const {c_type} {name}[{size}] = {{"]
    for base in range(0, len(values), width):
        chunk = values[base:base + width]
        rendered: list[str] = []
        for value in chunk:
            if c_type == "int32_t":
                signed = _sign_extend(value, 32)
                rendered.append(f"{signed}")
            else:
                rendered.append(f"0x{value & 0xFFFFFFFF:08x}u")
        lines.append("    " + ", ".join(rendered) + ",")
    lines.append("};")
    return lines


def export_firmware_selftest_header(vec: dict, path: Path, case_id: int = 1) -> dict:
    """Write a compact C header for the board-level firmware smoke test.

    The firmware ILM is only 64 KiB, so this intentionally exports one layer's
    resident load stream with descriptor bases rebased to zero. It validates the
    same hardware path as the full resident engine: descriptor writes, weight and
    scale loads, ACT_BUF writes, start/done polling, Y_BUF readback, and golden
    comparison.
    """
    try:
        case = next(c for c in vec["cases"] if c["id"] == case_id)
    except StopIteration as exc:
        raise ValueError(f"case_id {case_id} not found") from exc

    w_start = case["w_base"] * N_BANKS
    w_count = case["M"] * case["N"] // 8
    s_start = case["s_base"]
    s_count = case["M"] // 2
    w_words = vec["w_load_stream"][w_start:w_start + w_count]
    s_words = vec["s_load_stream"][s_start:s_start + s_count]
    act_words = pack_int8_values(case["x"])
    y_words = pack_int32_values(case["y"])

    lines = [
        "#ifndef W4A8_SELFTEST_VECTORS_H",
        "#define W4A8_SELFTEST_VECTORS_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define W4A8_ST_LAYER_ID {case_id}",
        f"#define W4A8_ST_M {case['M']}",
        f"#define W4A8_ST_N {case['N']}",
        "#define W4A8_ST_W_BASE 0",
        "#define W4A8_ST_S_BASE 0",
        f"#define W4A8_ST_SHIFT {DEFAULT_SHIFT}",
        f"#define W4A8_ST_W_WORDS {len(w_words)}",
        f"#define W4A8_ST_S_WORDS {len(s_words)}",
        f"#define W4A8_ST_ACT_WORDS {len(act_words)}",
        f"#define W4A8_ST_Y_WORDS {len(y_words)}",
        "",
        f"/* Compact firmware self-test case: id {case_id}, {case['name']} */",
    ]
    lines.extend(
        _format_c_array("w4a8_st_w_load", "uint32_t", w_words, size_expr="W4A8_ST_W_WORDS")
    )
    lines.append("")
    lines.extend(
        _format_c_array("w4a8_st_s_load", "uint32_t", s_words, size_expr="W4A8_ST_S_WORDS")
    )
    lines.append("")
    lines.extend(
        _format_c_array("w4a8_st_act", "uint32_t", act_words, size_expr="W4A8_ST_ACT_WORDS")
    )
    lines.append("")
    lines.extend(
        _format_c_array(
            "w4a8_st_y_ref", "int32_t", y_words, width=4, size_expr="W4A8_ST_Y_WORDS"
        )
    )
    lines.extend(["", "#endif", ""])

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="ascii")
    return {
        "layer_id": case_id,
        "layer_name": case["name"],
        "w_words": len(w_words),
        "s_words": len(s_words),
        "act_words": len(act_words),
        "y_words": len(y_words),
    }


def _pad_words(words: Sequence[int], depth: int, name: str) -> list[int]:
    if len(words) > depth:
        raise ValueError(f"{name}: {len(words)} words exceeds depth {depth}")
    return list(words) + [0] * (depth - len(words))


def export_bram_init_files(vec: dict, out_dir: Path) -> dict:
    """Write synthesis-time BRAM init files for resident W/S memories.

    The historical resident_w_load.hex is a flat CPU-load stream. The RTL BRAM
    instances are physically split by bank, so bank b receives flat words
    ``flat[addr * 16 + b]``. Files are padded to full memory depth to keep
    Vivado's $readmemh initialization deterministic.
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    flat = vec["w_load_stream"]
    used_slots = vec["total_bank_slots"]
    for bank in range(N_BANKS):
        bank_words = [
            flat[addr * N_BANKS + bank] if addr < used_slots else 0
            for addr in range(WMEM_BANK_DEPTH)
        ]
        write_hex_words(out_dir / f"wmem_bank{bank:02d}.hex", bank_words)

    smem_words = _pad_words(vec["s_load_stream"], SMEM_DEPTH, "smem")
    write_hex_words(out_dir / "smem.hex", smem_words)

    desc_words: list[int] = []
    for c in vec["cases"]:
        desc_words.extend([c["M"], c["N"], c["w_base"], c["s_base"], DEFAULT_SHIFT])
        write_hex_words(out_dir / f"act_layer{c['id']}.hex", pack_int8_values(c["x"]))
        write_hex_words(out_dir / f"y_ref_layer{c['id']}.hex", pack_int32_values(c["y"]))
    write_hex_words(out_dir / "desc_table.hex", desc_words)

    return {
        "w_bank_files": N_BANKS,
        "w_bank_depth": WMEM_BANK_DEPTH,
        "w_used_slots": used_slots,
        "s_depth": SMEM_DEPTH,
        "s_used_words": len(vec["s_load_stream"]),
        "layers": len(vec["cases"]),
    }


def export_full_firmware_selftest_header(vec: dict, path: Path) -> dict:
    """Write the 9-layer board self-test header without resident W/S arrays."""
    act_words: list[int] = []
    y_words: list[int] = []
    meta: list[dict] = []

    for c in vec["cases"]:
        act_off = len(act_words)
        y_off = len(y_words)
        act = pack_int8_values(c["x"])
        y = pack_int32_values(c["y"])
        act_words.extend(act)
        y_words.extend(y)
        meta.append(
            {
                "id": c["id"],
                "name": c["name"],
                "M": c["M"],
                "N": c["N"],
                "w_base": c["w_base"],
                "s_base": c["s_base"],
                "act_off": act_off,
                "act_words": len(act),
                "y_off": y_off,
                "y_words": len(y),
                "tiles": (c["M"] // TILE_M) * (c["N"] // TILE_N),
                "mac_cycles": (c["M"] // TILE_M) * (c["N"] // TILE_N) * TILE_N,
            }
        )

    lines = [
        "#ifndef W4A8_SELFTEST_VECTORS_H",
        "#define W4A8_SELFTEST_VECTORS_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define W4A8_ST_N_LAYERS {len(meta)}",
        f"#define W4A8_ST_SHIFT {DEFAULT_SHIFT}",
        f"#define W4A8_ST_ACT_WORDS {len(act_words)}",
        f"#define W4A8_ST_Y_WORDS {len(y_words)}",
        "",
        "typedef struct {",
        "    int id;",
        "    const char *name;",
        "    int m;",
        "    int n;",
        "    int w_base;",
        "    int s_base;",
        "    int act_offset;",
        "    int act_words;",
        "    int y_offset;",
        "    int y_words;",
        "    int tiles;",
        "    int mac_cycles;",
        "} w4a8_selftest_layer_t;",
        "",
        "static const w4a8_selftest_layer_t w4a8_st_layers[W4A8_ST_N_LAYERS] = {",
    ]
    for m in meta:
        lines.append(
            f"    {{ {m['id']}, \"{m['name']}\", {m['M']}, {m['N']}, "
            f"{m['w_base']}, {m['s_base']}, {m['act_off']}, {m['act_words']}, "
            f"{m['y_off']}, {m['y_words']}, {m['tiles']}, {m['mac_cycles']} }},"
        )
    lines.append("};")
    lines.append("")
    lines.extend(
        _format_c_array("w4a8_st_act", "uint32_t", act_words, size_expr="W4A8_ST_ACT_WORDS")
    )
    lines.append("")
    lines.extend(
        _format_c_array(
            "w4a8_st_y_ref", "int32_t", y_words, width=4, size_expr="W4A8_ST_Y_WORDS"
        )
    )
    lines.extend(["", "#endif", ""])

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="ascii")
    return {"layers": len(meta), "act_words": len(act_words), "y_words": len(y_words)}


def write_outputs(vec: dict, out_dir: Path, source: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    write_hex_words(out_dir / "resident_w_load.hex", vec["w_load_stream"])
    write_hex_words(out_dir / "resident_s_load.hex", vec["s_load_stream"])

    desc_lines = ["id name M N w_base s_base"]
    for c in vec["cases"]:
        desc_lines.append(
            f"{c['id']} {c['name']} {c['M']} {c['N']} {c['w_base']} {c['s_base']}"
        )
    (out_dir / "descriptors.txt").write_text("\n".join(desc_lines) + "\n", encoding="ascii")

    for c in vec["cases"]:
        case_dir = out_dir / f"id{c['id']}_{c['name']}"
        case_dir.mkdir(parents=True, exist_ok=True)
        write_hex_words(case_dir / "act.hex", pack_int8_values(c["x"]))
        write_hex_words(case_dir / "y_ref.hex", pack_int32_values(c["y"]))
        (case_dir / "meta.txt").write_text(
            "\n".join(
                [
                    f"id={c['id']}",
                    f"name={c['name']}",
                    f"m={c['M']}",
                    f"n={c['N']}",
                    f"w_base={c['w_base']}",
                    f"s_base={c['s_base']}",
                    f"shift={DEFAULT_SHIFT}",
                    f"act_words={c['N'] // 4}",
                    f"y_words={c['M']}",
                    f"tiles={(c['M'] // TILE_M) * (c['N'] // TILE_N)}",
                    f"mac_cycles={(c['M'] // TILE_M) * (c['N'] // TILE_N) * TILE_N}",
                    "",
                ]
            ),
            encoding="ascii",
        )

    _emit_c_header(vec, out_dir / "w4a8_engine_vectors.h")

    print(f"source: {source}")
    print(f"layers: {len(vec['cases'])}")
    print(
        f"resident weights: {len(vec['w_load_stream'])} words "
        f"(max bank_addr {vec['total_bank_slots']}/{WMEM_BANK_DEPTH})"
    )
    print(f"resident scales:  {len(vec['s_load_stream'])} words")
    print("descriptors:")
    for c in vec["cases"]:
        print(
            f"  id {c['id']:>1}  {c['name']:18s} {c['M']:>3}x{c['N']:<3}  "
            f"w_base={c['w_base']:>4}  s_base={c['s_base']:>4}  "
            f"tiles={(c['M'] // TILE_M) * (c['N'] // TILE_N)}"
        )
    print(f"output dir: {out_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("lecture2_0420_release/test_vectors/w4a8_engine"),
    )
    parser.add_argument("--checkpoint", type=Path, default=None,
                        help="use real per-row INT4 weights from this checkpoint")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--self-test", action="store_true",
                        help="run bank-mapping/golden round-trip checks and exit")
    parser.add_argument(
        "--bram-init-dir",
        type=Path,
        default=None,
        help="also export 16-bank BRAM init files to this directory",
    )
    parser.add_argument(
        "--firmware-selftest-header",
        type=Path,
        default=None,
        help="also export a board firmware self-test header",
    )
    parser.add_argument(
        "--full-firmware-selftest",
        action="store_true",
        help="export all 9 layers without resident W/S arrays; otherwise compact one-layer header",
    )
    parser.add_argument("--firmware-case-id", type=int, default=1)
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if args.checkpoint is not None:
        weights, cfg = _checkpoint_layers(args.checkpoint)
        source = f"checkpoint {args.checkpoint}"
    else:
        weights, cfg = None, TARGET_CONFIG
        source = f"synthetic (seed={args.seed})"

    vec = build_vectors(cfg, args.seed, weights)
    self_test(cfg)  # always verify layout before writing
    write_outputs(vec, args.out_dir, source)
    if args.bram_init_dir is not None:
        bram = export_bram_init_files(vec, args.bram_init_dir)
        print(
            f"bram init: {bram['w_bank_files']} wmem banks x "
            f"{bram['w_bank_depth']} words, smem {bram['s_used_words']}/"
            f"{bram['s_depth']} words -> {args.bram_init_dir}"
        )
    if args.firmware_selftest_header is not None:
        if args.full_firmware_selftest:
            fw = export_full_firmware_selftest_header(vec, args.firmware_selftest_header)
        else:
            fw = export_firmware_selftest_header(
                vec, args.firmware_selftest_header, args.firmware_case_id
            )
        print(f"firmware self-test header: {fw} -> {args.firmware_selftest_header}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
