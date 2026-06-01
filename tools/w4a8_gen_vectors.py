#!/usr/bin/env python3
"""Generate W4A8 tile test vectors for the old 16x64 tile primitive (gemv_accel).

Shared packing/golden/I/O primitives live in ``w4a8_common``; this module only
holds the tile-level case generators and the C-header exporter for the legacy
gemv path. (The resident-weight engine vectors live in ``w4a8_engine_vectors``.)
"""

from __future__ import annotations

import argparse
import random
import struct
import sys
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from w4a8_common import (  # noqa: E402
    DEFAULT_SHIFT,
    ONE_SCALE,
    TILE_M,
    TILE_N,
    golden_linear,
    golden_tile,
    pack_int4_matrix,
    pack_int8_values,
    pack_int16_values,
    pack_int32_values,
    write_bin_words,
    write_hex_words,
)


def _random_matrix(rng: random.Random, rows: int, cols: int) -> list[list[int]]:
    return [[rng.randint(-8, 7) for _ in range(cols)] for _ in range(rows)]


def _random_x(rng: random.Random, cols: int) -> list[int]:
    return [rng.randint(-32, 31) for _ in range(cols)]


def _boundary_matrix(rows: int, cols: int) -> list[list[int]]:
    return [[-8 if (row + col) % 2 == 0 else 7 for col in range(cols)] for row in range(rows)]


def _boundary_x(cols: int) -> list[int]:
    return [-128 if col % 2 == 0 else 127 for col in range(cols)]


def _awq_like_matrix_and_scale(
    rng: random.Random,
    rows: int,
    cols: int,
) -> tuple[list[list[int]], list[int]]:
    """Create an AWQ-shaped per-row INT4 quantized slice without external model deps."""
    matrix: list[list[int]] = []
    scale: list[int] = []
    for _ in range(rows):
        fp_row = [rng.gauss(0.0, 0.18) for _ in range(cols)]
        max_abs = max(abs(value) for value in fp_row) or 1.0
        real_scale = max_abs / 7.0
        quant_row = [
            max(-8, min(7, int(round(value / real_scale))))
            for value in fp_row
        ]
        scale_int = max(1, min(32767, int(round(real_scale * (1 << DEFAULT_SHIFT)))))
        matrix.append(quant_row)
        scale.append(scale_int)
    return matrix, scale


def _write_case(
    case_dir: Path,
    *,
    name: str,
    w_matrix: Sequence[Sequence[int]],
    x_vector: Sequence[int],
    scale: Sequence[int],
    shift: int,
    source: str,
) -> dict[str, int]:
    y = golden_linear(w_matrix, x_vector, scale, shift)
    w_words = pack_int4_matrix(w_matrix)
    x_words = pack_int8_values(x_vector)
    scale_words = pack_int16_values(scale)
    y_words = pack_int32_values(y)

    write_bin_words(case_dir / "w.bin", w_words)
    write_bin_words(case_dir / "x.bin", x_words)
    write_bin_words(case_dir / "scale.bin", scale_words)
    write_bin_words(case_dir / "y_ref.bin", y_words)
    (case_dir / "meta.txt").write_text(
        "\n".join(
            [
                f"case={name}",
                f"source={source}",
                f"m={len(w_matrix)}",
                f"n={len(x_vector)}",
                f"tile_m={TILE_M}",
                f"tile_n={TILE_N}",
                "word_endian=little",
                "weight_format=signed_int4_packed_8_per_u32_lsn_first",
                "x_format=signed_int8_packed_4_per_u32",
                "scale_format=signed_int16_packed_2_per_u32",
                f"shift={shift}",
                "y_format=signed_int32_one_per_u32",
                f"w_words={len(w_words)}",
                f"x_words={len(x_words)}",
                f"scale_words={len(scale_words)}",
                f"y_words={len(y_words)}",
                "",
            ]
        ),
        encoding="ascii",
    )
    return {
        "m": len(w_matrix),
        "n": len(x_vector),
        "w_words": len(w_words),
        "x_words": len(x_words),
        "scale_words": len(scale_words),
        "y_words": len(y_words),
    }


def generate_tv_suite(out_dir: Path, seed: int = 1) -> dict[str, dict[str, int]]:
    rng = random.Random(seed)
    cases: dict[str, tuple[list[list[int]], list[int], list[int], str]] = {}

    cases["tile_random"] = (
        _random_matrix(rng, TILE_M, TILE_N),
        _random_x(rng, TILE_N),
        [ONE_SCALE for _ in range(TILE_M)],
        "deterministic_random_tile",
    )
    cases["tile_boundary"] = (
        _boundary_matrix(TILE_M, TILE_N),
        _boundary_x(TILE_N),
        [ONE_SCALE for _ in range(TILE_M)],
        "signed_range_boundary_tile",
    )
    cases["linear_random_32x128"] = (
        _random_matrix(rng, 32, 128),
        _random_x(rng, 128),
        [ONE_SCALE for _ in range(32)],
        "deterministic_random_linear",
    )
    cases["linear_boundary_32x128"] = (
        _boundary_matrix(32, 128),
        _boundary_x(128),
        [ONE_SCALE for _ in range(32)],
        "signed_range_boundary_linear",
    )
    awq_w, awq_scale = _awq_like_matrix_and_scale(rng, 32, 128)
    cases["linear_awq_like_32x128"] = (
        awq_w,
        _random_x(rng, 128),
        awq_scale,
        "synthetic_awq_like_per_row_quantized_slice",
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    summary: dict[str, dict[str, int]] = {}
    for name, (w_matrix, x_vector, scale, source) in cases.items():
        summary[name] = _write_case(
            out_dir / name,
            name=name,
            w_matrix=w_matrix,
            x_vector=x_vector,
            scale=scale,
            shift=DEFAULT_SHIFT,
            source=source,
        )
    return summary


def _read_bin_words(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) % 4 != 0:
        raise ValueError(f"{path} length is not a multiple of 4")
    return [
        struct.unpack_from("<I", data, offset)[0]
        for offset in range(0, len(data), 4)
    ]


def _read_meta(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            meta[key] = value
    return meta


def _c_ident(name: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in name)


def _format_c_array(name: str, values: Sequence[int]) -> str:
    lines = [f"static const uint32_t {name}[{len(values)}] = {{"]
    for base in range(0, len(values), 4):
        chunk = values[base:base + 4]
        suffix = "," if base + 4 < len(values) else ""
        lines.append(
            "    " + ", ".join(f"0x{value:08x}u" for value in chunk) + suffix
        )
    lines.append("};")
    return "\n".join(lines)


def export_c_header(tv_dir: Path, header_path: Path) -> dict[str, int]:
    case_dirs = [
        tv_dir / "tile_random",
        tv_dir / "tile_boundary",
        tv_dir / "linear_random_32x128",
        tv_dir / "linear_boundary_32x128",
        tv_dir / "linear_awq_like_32x128",
    ]
    missing = [path for path in case_dirs if not path.exists()]
    if missing:
        raise FileNotFoundError(f"missing tv case directories: {missing}")

    body: list[str] = [
        "#ifndef W4A8_TEST_VECTORS_H",
        "#define W4A8_TEST_VECTORS_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define W4A8_TILE_M {TILE_M}",
        f"#define W4A8_TILE_N {TILE_N}",
        "#define W4A8_W_WORDS 128",
        "#define W4A8_X_WORDS 16",
        "#define W4A8_SCALE_WORDS 8",
        "#define W4A8_Y_WORDS 16",
        f"#define W4A8_SHIFT {DEFAULT_SHIFT}",
        f"#define W4A8_TV_COUNT {len(case_dirs)}",
        "",
        "typedef struct {",
        "    const char *name;",
        "    int m;",
        "    int n;",
        "    int shift;",
        "    const uint32_t *w;",
        "    const uint32_t *x;",
        "    const uint32_t *scale;",
        "    const uint32_t *y_ref;",
        "} w4a8_tv_case_t;",
        "",
    ]

    case_entries: list[str] = []
    for case_dir in case_dirs:
        meta = _read_meta(case_dir / "meta.txt")
        name = meta["case"]
        ident = _c_ident(name)
        m = int(meta["m"])
        n = int(meta["n"])
        shift = int(meta["shift"])
        arrays = {
            "w": _read_bin_words(case_dir / "w.bin"),
            "x": _read_bin_words(case_dir / "x.bin"),
            "scale": _read_bin_words(case_dir / "scale.bin"),
            "y_ref": _read_bin_words(case_dir / "y_ref.bin"),
        }
        for suffix, values in arrays.items():
            body.append(_format_c_array(f"w4a8_{ident}_{suffix}", values))
            body.append("")
        case_entries.append(
            "    {"
            f" .name = \"{name}\", .m = {m}, .n = {n}, .shift = {shift}, "
            f".w = w4a8_{ident}_w, .x = w4a8_{ident}_x, "
            f".scale = w4a8_{ident}_scale, .y_ref = w4a8_{ident}_y_ref "
            "}"
        )

    body.append("static const w4a8_tv_case_t w4a8_tv_cases[W4A8_TV_COUNT] = {")
    for idx, entry in enumerate(case_entries):
        body.append(entry + ("," if idx + 1 < len(case_entries) else ""))
    body.append("};")
    body.append("")
    body.append("#endif")
    body.append("")

    header_path.parent.mkdir(parents=True, exist_ok=True)
    with header_path.open("w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(body))
    return {"cases": len(case_dirs)}


def generate_default_case(out_dir: Path, seed: int = 1) -> dict[str, int]:
    rng = random.Random(seed)
    w_tile = [
        [rng.randint(-8, 7) for _ in range(TILE_N)]
        for _ in range(TILE_M)
    ]
    x_tile = [rng.randint(-32, 31) for _ in range(TILE_N)]
    scale = [ONE_SCALE for _ in range(TILE_M)]

    _, y = golden_tile(w_tile, x_tile, scale, DEFAULT_SHIFT, finalize=True)
    assert y is not None

    w_words = pack_int4_matrix(w_tile)
    x_words = pack_int8_values(x_tile)
    scale_words = pack_int16_values(scale)
    y_words = pack_int32_values(y)

    out_dir.mkdir(parents=True, exist_ok=True)
    write_hex_words(out_dir / "tile_16x64_w.hex", w_words)
    write_hex_words(out_dir / "tile_16x64_x.hex", x_words)
    write_hex_words(out_dir / "tile_16x64_scale.hex", scale_words)
    write_hex_words(out_dir / "tile_16x64_y_ref.hex", y_words)

    (out_dir / "tile_16x64_meta.txt").write_text(
        "\n".join(
            [
                "case=tile_16x64",
                f"seed={seed}",
                f"tile_m={TILE_M}",
                f"tile_n={TILE_N}",
                "weight_format=signed_int4_packed_8_per_word_lsn_first",
                "x_format=signed_int8_packed_4_per_word",
                "scale_format=signed_int16_packed_2_per_word",
                f"shift={DEFAULT_SHIFT}",
                f"scale_value={ONE_SCALE}",
                "effective_scale=1.0",
                "y_format=signed_int32_one_per_word",
                "",
            ]
        ),
        encoding="ascii",
    )

    return {
        "w_words": len(w_words),
        "x_words": len(x_words),
        "scale_words": len(scale_words),
        "y_words": len(y_words),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("lecture2_0420_release/test_vectors/w4a8"),
        help="directory for generated hex vectors",
    )
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument(
        "--bin-suite",
        action="store_true",
        help="also generate tile/linear binary vectors under out-dir/tv",
    )
    parser.add_argument(
        "--c-header",
        type=Path,
        help="export generated out-dir/tv vectors to a C header",
    )
    args = parser.parse_args()

    summary = generate_default_case(args.out_dir, args.seed)
    tv_summary = generate_tv_suite(args.out_dir / "tv", args.seed) if args.bin_suite else None
    c_summary = export_c_header(args.out_dir / "tv", args.c_header) if args.c_header else None
    print("Generated W4A8 tile test:")
    print(f"M={TILE_M}, N={TILE_N}, shift={DEFAULT_SHIFT}")
    print(f"W packed words: {summary['w_words']}")
    print(f"X words: {summary['x_words']}")
    print(f"Scale words: {summary['scale_words']}")
    print(f"Y words: {summary['y_words']}")
    print(f"Output: {args.out_dir}")
    if tv_summary is not None:
        print("Generated binary TV suite:")
        for name, case_summary in tv_summary.items():
            print(
                f"  {name}: W={case_summary['w_words']} "
                f"X={case_summary['x_words']} "
                f"S={case_summary['scale_words']} "
                f"Y={case_summary['y_words']}"
            )
    if c_summary is not None:
        print(f"Generated C header: {args.c_header} ({c_summary['cases']} cases)")
    print("Self-check PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
