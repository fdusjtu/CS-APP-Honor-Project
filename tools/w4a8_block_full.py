#!/usr/bin/env python3
"""Step 3b full-block Python golden + firmware vector generator.

Bit-exact integer reference for the complete transformer block:

    hidden_in -> LN1 -> qkv -> split -> attn(Q.K, softmax, .V with fake K[0]/V[0])
              -> proj -> res1 -> LN2 -> ffn_up -> GELU -> ffn_dn -> res2 = block_out

All arithmetic is integer; every shift / division uses an explicit
round-to-nearest expression so a literal C translation produces bit-exact
identical output. See docs/superpowers/specs/2026-05-29-step3b-design.md.
"""

from __future__ import annotations

import argparse
import math
import random
import struct
from pathlib import Path
from typing import Sequence

from w4a8_common import format_c_array, golden_linear


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

HIDDEN       = 128
FFN          = 256
N_HEADS      = 1
HEAD_DIM     = HIDDEN // N_HEADS  # 128 (seq_len=2, single head)
LOG2_HIDDEN  = 7                  # log2(128)
LOG2_HEAD    = 7                  # log2(128) for attention scale denominator factor

# Quantization scale for LayerNorm gamma/beta.
# gamma_q = round(gamma_float * 2^GAMMA_LOG2)  stored INT8
# beta_q  = round(beta_float  * 2^GAMMA_LOG2)  stored INT16
GAMMA_LOG2 = 6  # gamma_real in roughly [-2, 2)

# Exp LUT for softmax: 17 entries indexed by clamp(y, -16, 0) + 16
# exp_lut[i] = round(2^15 * exp((i - 16)))  in Q0.15 (INT16)
EXP_LUT_LEN = 17

# Layer ids in the FPGA descriptor table (matches existing self-test header).
LAYER_ID_QKV       = 0
LAYER_ID_PROJ      = 1
LAYER_ID_FFN_UP    = 2
LAYER_ID_FFN_DOWN  = 3

# DEFAULT_SHIFT for the FPGA engine row-rescale (matches RTL).
DEFAULT_SHIFT = 14


# -----------------------------------------------------------------------------
# Integer primitives — every one of these has a direct C counterpart.
# -----------------------------------------------------------------------------

def round_shift(value: int, shift: int) -> int:
    """value / 2^shift, round-to-nearest, ties up. Matches C:
        (value + (1 << (shift-1))) >> shift   for value >= 0
        -((-value + (1 << (shift-1))) >> shift) for value < 0
    """
    if shift <= 0:
        return value << (-shift)
    half = 1 << (shift - 1)
    if value >= 0:
        return (value + half) >> shift
    return -((-value + half) >> shift)


def round_div_signed(num: int, den: int) -> int:
    """num / den, round-to-nearest, ties up. den must be positive.

    C: int32_t q;
       if (num >= 0) q = (num + den/2) / den;
       else          q = -((-num + den/2) / den);
    """
    if den <= 0:
        raise ValueError(f"round_div_signed: den must be positive, got {den}")
    if num >= 0:
        return (num + den // 2) // den
    return -((-num + den // 2) // den)


def sat8(v: int) -> int:
    if v > 127: return 127
    if v < -128: return -128
    return v


def sat16(v: int) -> int:
    if v > 32767: return 32767
    if v < -32768: return -32768
    return v


def isqrt_floor(n: int) -> int:
    """floor(sqrt(n)) via Newton's method. Equivalent to math.isqrt for n >= 0.

    We re-implement here to make the C-side translation explicit.
    """
    if n < 0:
        raise ValueError("isqrt_floor: n must be >= 0")
    if n < 2:
        return n
    # Initial guess: shift so that x >= sqrt(n)
    x = n
    y = (x + 1) >> 1
    while y < x:
        x = y
        y = (x + n // x) >> 1
    return x


# -----------------------------------------------------------------------------
# LayerNorm (integer)
# -----------------------------------------------------------------------------

def int_layernorm_py(
    x_int32: Sequence[int],
    gamma_q: Sequence[int],
    beta_q: Sequence[int],
    *,
    N: int = HIDDEN,
    log2N: int = LOG2_HIDDEN,
) -> list[int]:
    """LayerNorm with integer arithmetic, bit-exact translatable to C.

    Inputs:
      x_int32: arbitrary INT32 vector of length N.
      gamma_q: INT8 vector, gamma_q[i] = round(gamma_float[i] * 2^GAMMA_LOG2).
      beta_q:  INT16 vector, beta_q[i]  = round(beta_float[i]  * 2^GAMMA_LOG2).

    Output:
      y_int32: INT32 vector. y_int32[i] / 2^GAMMA_LOG2 approximates the real
      LayerNorm output. Downstream callers apply a Step-3b right shift
      S_LN*_OUT to bring it into INT8 range for the next FPGA Linear.

    Algorithm:
      mean  = round( sum(x) / N )
      diff  = x - mean
      var   = round( sum(diff^2) / N )
      sigma = isqrt_floor(max(var, 1))                  (INT32, "Q0")
      y[i]  = round_div_signed(diff[i] * gamma_q[i], sigma) + beta_q[i]
    """
    if len(x_int32) != N:
        raise ValueError(f"x length {len(x_int32)} != N {N}")
    if len(gamma_q) != N or len(beta_q) != N:
        raise ValueError("gamma_q / beta_q must match length N")

    mean = round_shift(sum(x_int32), log2N)
    diff = [v - mean for v in x_int32]
    var = round_shift(sum(d * d for d in diff), log2N)
    sigma = isqrt_floor(max(var, 1))

    y: list[int] = []
    for i in range(N):
        num = diff[i] * gamma_q[i]                  # INT32
        q = round_div_signed(num, sigma)            # INT32
        y.append(q + beta_q[i])
    return y


def quantize_layernorm_params(
    gamma_float: Sequence[float],
    beta_float: Sequence[float],
) -> tuple[list[int], list[int]]:
    scale = 1 << GAMMA_LOG2
    gamma_q = [sat8(round(g * scale)) for g in gamma_float]
    beta_q  = [sat16(round(b * scale)) for b in beta_float]
    return gamma_q, beta_q


# -----------------------------------------------------------------------------
# GELU lookup table (INT8 -> INT8)
# -----------------------------------------------------------------------------

def _gelu_real(x: float) -> float:
    """tanh approximation matching PyTorch nn.GELU(approximate='tanh')."""
    return 0.5 * x * (1.0 + math.tanh(math.sqrt(2.0 / math.pi) * (x + 0.044715 * x * x * x)))


def build_gelu_lut() -> list[int]:
    """gelu_lut[i] = round(127 * gelu( (i - 128) / 128 ))  for i in 0..255."""
    out = []
    for i in range(256):
        x = (i - 128) / 128.0
        y = _gelu_real(x)
        q = round(127.0 * y)
        out.append(sat8(q))
    return out


def int_gelu_lut_py(lut: Sequence[int], x_int8: int) -> int:
    """Look up gelu(x_int8) using the precomputed 256-entry signed INT8 LUT."""
    if x_int8 < -128 or x_int8 > 127:
        raise ValueError("gelu input out of INT8 range")
    return lut[x_int8 + 128]


# -----------------------------------------------------------------------------
# Softmax (integer, fixed-point Q0.15 probabilities)
# -----------------------------------------------------------------------------

def build_exp_lut() -> list[int]:
    """exp_lut[i] = round(32767 * exp(i - 16))  for i in 0..16.

    Index convention: y_clip in [-16, 0], lookup index = y_clip + 16.
    """
    out = []
    for i in range(EXP_LUT_LEN):
        v = round(32767.0 * math.exp(i - 16))
        out.append(sat16(v))
    return out


def int_softmax_py(scores_int8: Sequence[int], exp_lut: Sequence[int]) -> list[int]:
    """Compute Q0.15 INT16 probabilities for an INT8 score vector.

    scores_int8: length L. Output: length L, probs sum to ~32768.
    """
    if len(scores_int8) == 0:
        return []
    m = max(scores_int8)
    y_clip = [max(-16, min(0, s - m)) for s in scores_int8]
    exp_q = [exp_lut[y + 16] for y in y_clip]
    sum_exp = sum(exp_q)
    if sum_exp <= 0:
        # Degenerate; uniform fallback.
        return [32768 // len(scores_int8)] * len(scores_int8)
    probs = []
    for e in exp_q:
        num = e << 15
        # round-to-nearest unsigned division (both positive)
        q = (num + (sum_exp >> 1)) // sum_exp
        probs.append(min(32767, q))
    return probs


# -----------------------------------------------------------------------------
# Full block dataflow
# -----------------------------------------------------------------------------

def _round_shift_vec(vec: Sequence[int], shift: int) -> list[int]:
    return [round_shift(v, shift) for v in vec]


def _sat8_vec(vec: Sequence[int]) -> list[int]:
    return [sat8(v) for v in vec]


def pick_shift_to_int8(values: Sequence[int]) -> int:
    """Choose the smallest non-negative shift S such that max(|v >> S|) <= 127."""
    if not values:
        return 0
    peak = max(abs(v) for v in values)
    s = 0
    while peak > 127:
        peak >>= 1
        s += 1
    return s


def pick_shift_for_softmax(values: Sequence[int], max_span: int = 9) -> int:
    """Choose smallest shift S so values >> S fit INT8 AND have span <= max_span.

    The exp LUT only covers (max - score) in [0, 16], but Q0.15 only
    represents exp values >= ~3e-5 (exp(-10) and above). With max_span=9
    every attended position gets exp_q >= 4, keeping softmax non-degenerate
    on representative inputs.
    """
    if not values:
        return 0
    peak = max(abs(v) for v in values)
    span = max(values) - min(values)
    s = 0
    while peak > 127 or span > max_span:
        peak >>= 1
        span >>= 1
        s += 1
    return s


def run_full_block_py(
    hidden_in: Sequence[int],
    *,
    weights: dict,           # {qkv, proj, ffn_up, ffn_down: (W_q, scale_q)}
    ln1: tuple[Sequence[int], Sequence[int]],   # (gamma_q, beta_q)
    ln2: tuple[Sequence[int], Sequence[int]],
    gelu_lut: Sequence[int],
    exp_lut: Sequence[int],
    kv_prev_k: Sequence[int],
    kv_prev_v: Sequence[int],
    shifts: dict | None = None,    # optional override; otherwise auto-pick
) -> dict:
    """Run the Step 3b transformer block in integer arithmetic.

    Returns a dict with:
      block_out (INT32[HIDDEN]), and all stage intermediates for debugging.
    """
    if len(hidden_in) != HIDDEN:
        raise ValueError(f"hidden_in must have {HIDDEN} elements")

    qkv_W, qkv_S = weights["qkv"]
    proj_W, proj_S = weights["proj"]
    ffn_up_W, ffn_up_S = weights["ffn_up"]
    ffn_dn_W, ffn_dn_S = weights["ffn_down"]

    s = shifts.copy() if shifts else {}

    # -- Stage 1: LN1 over hidden_in (treat INT8 as INT32 sign-extended) --
    ln1_g, ln1_b = ln1
    ln1_out = int_layernorm_py(list(hidden_in), ln1_g, ln1_b)

    # Pick S_LN1_OUT so ln1_q8 fits INT8.
    s.setdefault("S_LN1_OUT", pick_shift_to_int8(ln1_out))
    ln1_q8 = _sat8_vec(_round_shift_vec(ln1_out, s["S_LN1_OUT"]))

    # -- Stage 2: FPGA qkv (Linear) --
    qkv_out = golden_linear(qkv_W, ln1_q8, qkv_S, DEFAULT_SHIFT)  # INT32[384]

    # Split Q | K | V (each HIDDEN).
    Q_int32 = qkv_out[0:HIDDEN]
    K_int32 = qkv_out[HIDDEN:2 * HIDDEN]
    V_int32 = qkv_out[2 * HIDDEN:3 * HIDDEN]

    # Quantize current K, V to INT8 for attention.
    s.setdefault("S_K_REQUANT", pick_shift_to_int8(K_int32))
    s.setdefault("S_V_REQUANT", pick_shift_to_int8(V_int32))
    s.setdefault("S_Q_REQUANT", pick_shift_to_int8(Q_int32))
    K1_q8 = _sat8_vec(_round_shift_vec(K_int32, s["S_K_REQUANT"]))
    V1_q8 = _sat8_vec(_round_shift_vec(V_int32, s["S_V_REQUANT"]))
    Q_q8  = _sat8_vec(_round_shift_vec(Q_int32, s["S_Q_REQUANT"]))

    # -- Stage 3: attention with seq_len=2 (positions 0 and 1) --
    # K and V vectors: [kv_prev_k, K1_q8] and [kv_prev_v, V1_q8]
    K_seq = [list(kv_prev_k), K1_q8]
    V_seq = [list(kv_prev_v), V1_q8]
    # Q . K_seq[s]:  INT32 dot product
    scores_i32 = [sum(Q_q8[d] * K_seq[t][d] for d in range(HEAD_DIM)) for t in range(2)]
    # Requant scores to INT8, constraining the spread so softmax is meaningful.
    s.setdefault("S_SCORES", pick_shift_for_softmax(scores_i32))
    scores_q8 = _sat8_vec(_round_shift_vec(scores_i32, s["S_SCORES"]))

    # Integer softmax -> Q0.15 probs
    probs_q15 = int_softmax_py(scores_q8, exp_lut)

    # Weighted sum: attn_out[d] = sum_t probs[t] * V_seq[t][d], result INT32
    attn_i32 = []
    for d in range(HEAD_DIM):
        acc = 0
        for t in range(2):
            acc += probs_q15[t] * V_seq[t][d]
        # acc is roughly Q15 (probs Q15 * V_int8); shift down to INT8 range
        attn_i32.append(acc)
    # >> 15 to get back to V_int8 scale; then a further shift to INT8 if needed.
    attn_back = [round_shift(v, 15) for v in attn_i32]
    s.setdefault("S_ATTN_OUT", pick_shift_to_int8(attn_back))
    attn_q8 = _sat8_vec(_round_shift_vec(attn_back, s["S_ATTN_OUT"]))

    # -- Stage 4: FPGA proj --
    proj_out = golden_linear(proj_W, attn_q8, proj_S, DEFAULT_SHIFT)

    # -- Stage 5: residual 1 --
    s.setdefault("S_LIFT", 0)  # hidden_in lift before adding proj_out
    res1 = [(int(hidden_in[i]) << s["S_LIFT"]) + proj_out[i] for i in range(HIDDEN)]

    # -- Stage 6: LN2 over res1 (INT32) --
    ln2_g, ln2_b = ln2
    ln2_out = int_layernorm_py(res1, ln2_g, ln2_b)
    s.setdefault("S_LN2_OUT", pick_shift_to_int8(ln2_out))
    ln2_q8 = _sat8_vec(_round_shift_vec(ln2_out, s["S_LN2_OUT"]))

    # -- Stage 7: FPGA ffn_up --
    ffn_up_out = golden_linear(ffn_up_W, ln2_q8, ffn_up_S, DEFAULT_SHIFT)

    # -- Stage 8: GELU --
    # Requant ffn_up_out to INT8 first
    s.setdefault("S_FFN_UP_OUT", pick_shift_to_int8(ffn_up_out))
    ffn_up_q8 = _sat8_vec(_round_shift_vec(ffn_up_out, s["S_FFN_UP_OUT"]))
    gelu_out = [int_gelu_lut_py(gelu_lut, v) for v in ffn_up_q8]

    # -- Stage 9: FPGA ffn_down --
    ffn_dn_out = golden_linear(ffn_dn_W, gelu_out, ffn_dn_S, DEFAULT_SHIFT)

    # -- Stage 10: residual 2 -> block_out --
    s.setdefault("S_BLK_TRIM", 0)
    block_out = [
        (res1[i] >> s["S_BLK_TRIM"] if s["S_BLK_TRIM"] >= 0 else res1[i] << (-s["S_BLK_TRIM"]))
        + ffn_dn_out[i]
        for i in range(HIDDEN)
    ]

    return {
        "block_out":  block_out,
        "ln1_out":    ln1_out,
        "ln1_q8":     ln1_q8,
        "qkv_out":    qkv_out,
        "Q_q8":       Q_q8,
        "K1_q8":      K1_q8,
        "V1_q8":      V1_q8,
        "scores_i32": scores_i32,
        "scores_q8":  scores_q8,
        "probs_q15":  probs_q15,
        "attn_q8":    attn_q8,
        "proj_out":   proj_out,
        "res1":       res1,
        "ln2_out":    ln2_out,
        "ln2_q8":     ln2_q8,
        "ffn_up_out": ffn_up_out,
        "ffn_up_q8":  ffn_up_q8,
        "gelu_out":   gelu_out,
        "ffn_dn_out": ffn_dn_out,
        "shifts":     s,
    }


# -----------------------------------------------------------------------------
# Checkpoint loading
# -----------------------------------------------------------------------------

def load_block_params(ckpt_path: Path) -> dict:
    """Load layer0 weights + LN1 / LN2 gamma/beta from the trained checkpoint."""
    import torch
    import sys

    sys.path.insert(0, str(Path(__file__).parent))
    from w4a8_engine_vectors import _checkpoint_layers

    weights, cfg = _checkpoint_layers(ckpt_path)
    block_w = {
        "qkv":      weights["layer0_qkv"],
        "proj":     weights["layer0_proj"],
        "ffn_up":   weights["layer0_ffn_up"],
        "ffn_down": weights["layer0_ffn_down"],
    }

    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    sd = ckpt["model"]
    ln1_g_f = sd["blocks.0.ln1.weight"].detach().cpu().tolist()
    ln1_b_f = sd["blocks.0.ln1.bias"].detach().cpu().tolist()
    ln2_g_f = sd["blocks.0.ln2.weight"].detach().cpu().tolist()
    ln2_b_f = sd["blocks.0.ln2.bias"].detach().cpu().tolist()

    ln1_g, ln1_b = quantize_layernorm_params(ln1_g_f, ln1_b_f)
    ln2_g, ln2_b = quantize_layernorm_params(ln2_g_f, ln2_b_f)

    return {
        "weights": block_w,
        "ln1": (ln1_g, ln1_b),
        "ln2": (ln2_g, ln2_b),
        "ln1_float": (ln1_g_f, ln1_b_f),
        "ln2_float": (ln2_g_f, ln2_b_f),
        "cfg": cfg,
    }


def build_fixed_inputs(seed: int = 0xC001) -> dict:
    rng = random.Random(seed)
    hidden_in  = [rng.randint(-128, 127) for _ in range(HIDDEN)]
    # Fake KV "previous token" — fixed seeds so reproducible.
    rng_k = random.Random(0xCAFE)
    rng_v = random.Random(0xBEEF)
    kv_prev_k = [rng_k.randint(-128, 127) for _ in range(HEAD_DIM)]
    kv_prev_v = [rng_v.randint(-128, 127) for _ in range(HEAD_DIM)]
    return {"hidden_in": hidden_in, "kv_prev_k": kv_prev_k, "kv_prev_v": kv_prev_v}


# -----------------------------------------------------------------------------
# Header emission (Step ③)
# -----------------------------------------------------------------------------

C_HEADER_PATH = Path(
    "lecture2_0420_release/test1/application/w4a8_block_full_vectors.h"
)


def emit_header(result: dict, inputs: dict, lns: dict, path: Path) -> None:
    s = result["shifts"]
    lines = [
        "#ifndef W4A8_BLOCK_FULL_VECTORS_H",
        "#define W4A8_BLOCK_FULL_VECTORS_H",
        "/* Auto-generated by tools/w4a8_block_full.py. Do not edit by hand. */",
        "",
        "#include <stdint.h>",
        "",
        f"#define W4A8B_HIDDEN  {HIDDEN}",
        f"#define W4A8B_FFN     {FFN}",
        f"#define W4A8B_HEAD_DIM {HEAD_DIM}",
        f"#define W4A8B_SEQ_LEN 2",
        f"#define W4A8B_GAMMA_LOG2 {GAMMA_LOG2}",
        "",
        f"#define W4A8B_ID_QKV      {LAYER_ID_QKV}",
        f"#define W4A8B_ID_PROJ     {LAYER_ID_PROJ}",
        f"#define W4A8B_ID_FFN_UP   {LAYER_ID_FFN_UP}",
        f"#define W4A8B_ID_FFN_DOWN {LAYER_ID_FFN_DOWN}",
        "",
        "/* Per-stage right shifts chosen by the Python golden. */",
        f"#define W4A8B_S_LN1_OUT     {s['S_LN1_OUT']}",
        f"#define W4A8B_S_Q_REQUANT   {s['S_Q_REQUANT']}",
        f"#define W4A8B_S_K_REQUANT   {s['S_K_REQUANT']}",
        f"#define W4A8B_S_V_REQUANT   {s['S_V_REQUANT']}",
        f"#define W4A8B_S_SCORES      {s['S_SCORES']}",
        f"#define W4A8B_S_ATTN_OUT    {s['S_ATTN_OUT']}",
        f"#define W4A8B_S_LIFT        {s['S_LIFT']}",
        f"#define W4A8B_S_LN2_OUT     {s['S_LN2_OUT']}",
        f"#define W4A8B_S_FFN_UP_OUT  {s['S_FFN_UP_OUT']}",
        f"#define W4A8B_S_BLK_TRIM    {s['S_BLK_TRIM']}",
        "",
    ]

    def emit(name, ctype, vals, width, size):
        lines.extend(format_c_array(name, ctype, list(vals), width, size))
        lines.append("")

    emit("w4a8b_hidden_in",  "int8_t",  inputs["hidden_in"],       16, "W4A8B_HIDDEN")
    emit("w4a8b_kv_prev_k",  "int8_t",  inputs["kv_prev_k"],       16, "W4A8B_HEAD_DIM")
    emit("w4a8b_kv_prev_v",  "int8_t",  inputs["kv_prev_v"],       16, "W4A8B_HEAD_DIM")
    emit("w4a8b_ln1_gamma",  "int8_t",  lns["ln1"][0],             16, "W4A8B_HIDDEN")
    emit("w4a8b_ln1_beta",   "int16_t", lns["ln1"][1],             8,  "W4A8B_HIDDEN")
    emit("w4a8b_ln2_gamma",  "int8_t",  lns["ln2"][0],             16, "W4A8B_HIDDEN")
    emit("w4a8b_ln2_beta",   "int16_t", lns["ln2"][1],             8,  "W4A8B_HIDDEN")
    emit("w4a8b_gelu_lut",   "int8_t",  lns["gelu_lut"],           16, "256")
    emit("w4a8b_exp_lut",    "int16_t", lns["exp_lut"],            8,  str(EXP_LUT_LEN))
    emit("w4a8b_block_out_golden", "int32_t", result["block_out"], 8, "W4A8B_HIDDEN")

    lines.append("#endif  /* W4A8_BLOCK_FULL_VECTORS_H */")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


# -----------------------------------------------------------------------------
# Host C bit-exact binary blob (Step ⑤)
# -----------------------------------------------------------------------------

HOST_BLOB_PATH = Path("tools/host_c_test/golden.bin")


def _pack_i8_vec(vec: Sequence[int]) -> bytes:
    return b"".join(struct.pack("<b", int(v)) for v in vec)


def _pack_i16_vec(vec: Sequence[int]) -> bytes:
    return b"".join(struct.pack("<h", int(v)) for v in vec)


def _pack_i32_vec(vec: Sequence[int]) -> bytes:
    return b"".join(struct.pack("<i", int(v)) for v in vec)


def emit_host_blob(result: dict, inputs: dict, lns: dict, path: Path) -> None:
    """Pack Python golden vectors into a binary file the host C test reads.

    File layout (little-endian, sequential):
      hidden_in:    INT8 [128]
      kv_prev_k:    INT8 [128]
      kv_prev_v:    INT8 [128]
      ln1_gamma:    INT8 [128]
      ln1_beta:     INT16[128]
      ln2_gamma:    INT8 [128]
      ln2_beta:     INT16[128]
      gelu_lut:     INT8 [256]
      exp_lut:      INT16[17]
      ln1_out:      INT32[128]
      ln2_out:      INT32[128]
      gelu_in_q8:   INT8 [256]   (== ffn_up_q8)
      gelu_out:     INT8 [256]
      scores_q8:    INT8 [2]
      probs_q15:    INT16[2]
      block_out:    INT32[128]
    Shifts and layer ids are passed via #define-style ASCII sidecar so the
    host test source can read them directly via the same vectors.h.
    """
    blob = b""
    blob += _pack_i8_vec(inputs["hidden_in"])
    blob += _pack_i8_vec(inputs["kv_prev_k"])
    blob += _pack_i8_vec(inputs["kv_prev_v"])
    blob += _pack_i8_vec(lns["ln1"][0])
    blob += _pack_i16_vec(lns["ln1"][1])
    blob += _pack_i8_vec(lns["ln2"][0])
    blob += _pack_i16_vec(lns["ln2"][1])
    blob += _pack_i8_vec(lns["gelu_lut"])
    blob += _pack_i16_vec(lns["exp_lut"])
    blob += _pack_i32_vec(result["ln1_out"])
    blob += _pack_i32_vec(result["ln2_out"])
    blob += _pack_i8_vec(result["ffn_up_q8"])
    blob += _pack_i8_vec(result["gelu_out"])
    blob += _pack_i8_vec(result["scores_q8"])
    blob += _pack_i16_vec(result["probs_q15"])
    blob += _pack_i32_vec(result["block_out"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _self_summarize(result: dict) -> None:
    s = result["shifts"]
    print("Shifts:")
    for k in ("S_LN1_OUT", "S_Q_REQUANT", "S_K_REQUANT", "S_V_REQUANT",
             "S_SCORES", "S_ATTN_OUT", "S_LIFT", "S_LN2_OUT",
             "S_FFN_UP_OUT", "S_BLK_TRIM"):
        print(f"  {k:<14} = {s[k]}")
    bo = result["block_out"]
    print(f"block_out[0:4] = {bo[0:4]}")
    print(f"block_out[-4:] = {bo[-4:]}")
    print(f"block_out range = [{min(bo)}, {max(bo)}]")
    print(f"scores_q8 = {result['scores_q8']}, probs_q15 = {result['probs_q15']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"),
        help="trained model checkpoint",
    )
    parser.add_argument(
        "--header", type=Path, default=C_HEADER_PATH,
        help="output firmware vectors header",
    )
    parser.add_argument(
        "--blob", type=Path, default=HOST_BLOB_PATH,
        help="output host-C bit-exact binary blob",
    )
    args = parser.parse_args()

    params = load_block_params(args.checkpoint)
    inputs = build_fixed_inputs()
    gelu_lut = build_gelu_lut()
    exp_lut = build_exp_lut()
    lns = {
        "ln1":      params["ln1"],
        "ln2":      params["ln2"],
        "gelu_lut": gelu_lut,
        "exp_lut":  exp_lut,
    }
    result = run_full_block_py(
        inputs["hidden_in"],
        weights=params["weights"],
        ln1=params["ln1"],
        ln2=params["ln2"],
        gelu_lut=gelu_lut,
        exp_lut=exp_lut,
        kv_prev_k=inputs["kv_prev_k"],
        kv_prev_v=inputs["kv_prev_v"],
    )

    _self_summarize(result)
    emit_header(result, inputs, lns, args.header)
    emit_host_blob(result, inputs, lns, args.blob)
    print(f"\nWrote {args.header}")
    print(f"Wrote {args.blob}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
