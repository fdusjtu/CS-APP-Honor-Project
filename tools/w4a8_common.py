#!/usr/bin/env python3
"""Shared W4A8 primitives: packing, numerical golden, and hex/bin I/O.

These helpers are layout-agnostic and reused by both vector generators:
  - ``w4a8_gen_vectors.py``    -> old 16x64 tile primitive (gemv_accel)
  - ``w4a8_engine_vectors.py`` -> resident-weight w4a8_linear_engine

Wire formats:
  - W4 weights: signed int4, eight nibbles per 32-bit word, nibble 0 at [3:0].
  - X activations: signed int8, four values per 32-bit word.
  - Scale values: signed int16, two values per 32-bit word.
  - Y reference: signed int32, one value per 32-bit word.

The numerical golden is W4 x INT8 -> INT32 acc -> per-row Q-format rescale.
"""

from __future__ import annotations

import struct
from pathlib import Path
from typing import Iterable, Sequence


TILE_M = 16
TILE_N = 64
DEFAULT_SHIFT = 14
ONE_SCALE = 1 << DEFAULT_SHIFT


def _require_range(value: int, low: int, high: int, name: str) -> None:
    if value < low or value > high:
        raise ValueError(f"{name} value {value} outside [{low}, {high}]")


def _to_unsigned(value: int, bits: int) -> int:
    return value & ((1 << bits) - 1)


def _sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & sign else value


def _flatten_matrix(matrix: Sequence[Sequence[int]]) -> list[int]:
    return [value for row in matrix for value in row]


def pack_int4_matrix(values: Sequence[int] | Sequence[Sequence[int]]) -> list[int]:
    """Pack signed int4 values into 32-bit words, eight nibbles per word."""
    if values and isinstance(values[0], (list, tuple)):  # type: ignore[index]
        flat = _flatten_matrix(values)  # type: ignore[arg-type]
    else:
        flat = list(values)  # type: ignore[arg-type]

    words: list[int] = []
    for base in range(0, len(flat), 8):
        word = 0
        for idx, value in enumerate(flat[base:base + 8]):
            _require_range(value, -8, 7, "int4")
            word |= _to_unsigned(value, 4) << (4 * idx)
        words.append(word)
    return words


def unpack_int4_words(words: Sequence[int], count: int) -> list[int]:
    values: list[int] = []
    for word in words:
        for idx in range(8):
            values.append(_sign_extend((word >> (4 * idx)) & 0xF, 4))
            if len(values) == count:
                return values
    return values


def pack_int8_values(values: Sequence[int]) -> list[int]:
    words: list[int] = []
    for base in range(0, len(values), 4):
        word = 0
        for idx, value in enumerate(values[base:base + 4]):
            _require_range(value, -128, 127, "int8")
            word |= _to_unsigned(value, 8) << (8 * idx)
        words.append(word)
    return words


def pack_int16_values(values: Sequence[int]) -> list[int]:
    words: list[int] = []
    for base in range(0, len(values), 2):
        word = 0
        for idx, value in enumerate(values[base:base + 2]):
            _require_range(value, -32768, 32767, "int16")
            word |= _to_unsigned(value, 16) << (16 * idx)
        words.append(word)
    return words


def pack_int32_values(values: Sequence[int]) -> list[int]:
    return [_to_unsigned(value, 32) for value in values]


def golden_tile(
    w_tile: Sequence[Sequence[int]],
    x_tile: Sequence[int],
    scale: Sequence[int],
    shift: int,
    acc_in: Sequence[int] | None = None,
    *,
    finalize: bool,
) -> tuple[list[int], list[int] | None]:
    """Compute one 16x64 W4A8 tile exactly as the RTL should."""
    if len(w_tile) != TILE_M or any(len(row) != TILE_N for row in w_tile):
        raise ValueError(f"w_tile must be {TILE_M}x{TILE_N}")
    if len(x_tile) != TILE_N:
        raise ValueError(f"x_tile must have {TILE_N} elements")
    if len(scale) != TILE_M:
        raise ValueError(f"scale must have {TILE_M} elements")

    acc = list(acc_in) if acc_in is not None else [0 for _ in range(TILE_M)]
    if len(acc) != TILE_M:
        raise ValueError(f"acc_in must have {TILE_M} elements")

    for row in range(TILE_M):
        row_acc = acc[row]
        for col in range(TILE_N):
            _require_range(w_tile[row][col], -8, 7, "int4")
            _require_range(x_tile[col], -128, 127, "int8")
            row_acc += w_tile[row][col] * x_tile[col]
        acc[row] = row_acc

    if not finalize:
        return acc, None

    y = [(acc[row] * scale[row]) >> shift for row in range(TILE_M)]
    return acc, y


def golden_linear(
    w_matrix: Sequence[Sequence[int]],
    x_vector: Sequence[int],
    scale: Sequence[int],
    shift: int,
) -> list[int]:
    """Compute a complete MxN W4A8 linear layer through 16x64 tiles."""
    m = len(w_matrix)
    if m == 0 or m % TILE_M != 0:
        raise ValueError(f"row count must be a positive multiple of {TILE_M}")
    n = len(x_vector)
    if n == 0 or n % TILE_N != 0:
        raise ValueError(f"column count must be a positive multiple of {TILE_N}")
    if any(len(row) != n for row in w_matrix):
        raise ValueError("all weight rows must have the same width as x_vector")
    if len(scale) != m:
        raise ValueError("scale length must equal row count")

    y: list[int] = []
    for row_base in range(0, m, TILE_M):
        acc = [0 for _ in range(TILE_M)]
        for col_base in range(0, n, TILE_N):
            w_tile = [
                list(w_matrix[row_base + row][col_base:col_base + TILE_N])
                for row in range(TILE_M)
            ]
            x_tile = list(x_vector[col_base:col_base + TILE_N])
            finalize = col_base + TILE_N == n
            tile_scale = list(scale[row_base:row_base + TILE_M])
            acc, tile_y = golden_tile(
                w_tile,
                x_tile,
                tile_scale,
                shift,
                acc,
                finalize=finalize,
            )
            if tile_y is not None:
                y.extend(tile_y)
    return y


def write_hex_words(path: Path, words: Iterable[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as f:
        for word in words:
            f.write(f"{word & 0xFFFFFFFF:08x}\n")


def write_bin_words(path: Path, words: Iterable[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        for word in words:
            f.write(struct.pack("<I", word & 0xFFFFFFFF))


def format_c_array(
    name: str, c_type: str, values: Sequence[int], width: int, size_expr: str
) -> list[str]:
    """Render a C `static const` array. Returns a list of lines (no trailing newline).

    Validates int16_t range. Other typed arrays are emitted as decimal; "uint32_t"
    style raw words are emitted as hex literals.
    """
    if c_type == "int16_t":
        for v in values:
            if v < -32768 or v > 32767:
                raise ValueError(f"{name}: value {v} outside int16 range")
    if c_type == "int8_t":
        for v in values:
            if v < -128 or v > 127:
                raise ValueError(f"{name}: value {v} outside int8 range")
    lines = [f"static const {c_type} {name}[{size_expr}] = {{"]
    for base in range(0, len(values), width):
        chunk = values[base:base + width]
        rendered: list[str] = []
        for v in chunk:
            if c_type in ("int32_t", "int16_t", "int8_t"):
                rendered.append(f"{v}")
            else:
                rendered.append(f"0x{v & 0xFFFFFFFF:08x}u")
        lines.append("    " + ", ".join(rendered) + ",")
    lines.append("};")
    return lines
