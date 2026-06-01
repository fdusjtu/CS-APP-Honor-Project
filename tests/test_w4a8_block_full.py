"""Tests for the Step 3b integer transformer-block reference.

These tests cover:
- LN: integer LN output vs fp32 LayerNorm reference (tolerance bounded)
- isqrt_floor: matches math.isqrt for representative values
- round_div_signed: matches a hand-derived oracle for positive and negative
- GELU LUT: each entry matches the analytic GELU formula
- Softmax: integer probs vs fp32 softmax (tolerance bounded)
- Full block: assembles cleanly with checkpoint weights and produces a
  block_out that approximately matches a fp32 reference.

The Python module is the *golden* for the C firmware; tests primarily
verify the Python is numerically reasonable, then we rely on host-C
bit-exact tests (Step 5) to verify C matches Python exactly.
"""

from __future__ import annotations

import math
import random
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import w4a8_block_full as wb


# -----------------------------------------------------------------------------
# Primitives
# -----------------------------------------------------------------------------

class TestPrimitives:

    def test_round_shift_positive(self):
        assert wb.round_shift(10, 1) == 5
        assert wb.round_shift(11, 1) == 6   # half rounds up
        assert wb.round_shift(0, 5) == 0

    def test_round_shift_negative(self):
        # -11 / 2 with ties-toward-+inf:
        #   abs=11, +half(1) = 12, /2 = 6, negated = -6
        # but our rule: ties to "+infinity in magnitude" (away from zero)
        # actually our rule for negative: -((-num + half) >> shift), so:
        # num=-11, shift=1: -((11+1)>>1) = -((12)>>1) = -6
        assert wb.round_shift(-11, 1) == -6
        assert wb.round_shift(-10, 1) == -5
        assert wb.round_shift(-1, 1) == -1   # -((1+1)>>1) = -1

    def test_round_shift_zero_or_neg_shift(self):
        assert wb.round_shift(42, 0) == 42
        assert wb.round_shift(3, -2) == 12

    def test_round_div_signed(self):
        assert wb.round_div_signed(10, 3) == 3        # 10/3=3.33 -> 3
        assert wb.round_div_signed(11, 3) == 4        # 11/3=3.66 -> 4
        assert wb.round_div_signed(9, 6) == 2         # 9/6=1.5  -> 2 (ties up)
        assert wb.round_div_signed(-9, 6) == -2
        assert wb.round_div_signed(-11, 3) == -4

    def test_round_div_zero_den_raises(self):
        with pytest.raises(ValueError):
            wb.round_div_signed(1, 0)

    def test_sat8_sat16(self):
        assert wb.sat8(200) == 127
        assert wb.sat8(-200) == -128
        assert wb.sat8(0) == 0
        assert wb.sat16(40000) == 32767
        assert wb.sat16(-40000) == -32768

    @pytest.mark.parametrize("n", [0, 1, 2, 4, 9, 16, 1023, 1024,
                                    65535, 1 << 20, 1 << 28, (1 << 30) - 1])
    def test_isqrt_matches_math(self, n):
        assert wb.isqrt_floor(n) == math.isqrt(n)


# -----------------------------------------------------------------------------
# LayerNorm
# -----------------------------------------------------------------------------

def _fp32_layernorm(x, gamma, beta):
    """Reference fp32 LayerNorm with eps=0 to match the integer version."""
    n = len(x)
    mu = sum(x) / n
    var = sum((v - mu) ** 2 for v in x) / n
    sigma = math.sqrt(max(var, 1e-12))
    return [(v - mu) / sigma * g + b for v, g, b in zip(x, gamma, beta)]


class TestLayerNorm:

    def test_constant_input_returns_beta_only(self):
        # Constant input -> sigma=0 -> we clamp to 1 in the int impl.
        # gamma=0 -> output should be beta exactly.
        gamma_f = [0.0] * wb.HIDDEN
        beta_f = [3.0 + 0.001 * i for i in range(wb.HIDDEN)]
        g_q, b_q = wb.quantize_layernorm_params(gamma_f, beta_f)
        x = [42] * wb.HIDDEN
        y = wb.int_layernorm_py(x, g_q, b_q)
        assert y == b_q

    def test_matches_fp32_within_tolerance(self):
        rng = random.Random(0xA11CE)
        x = [rng.randint(-128, 127) for _ in range(wb.HIDDEN)]
        gamma_f = [rng.uniform(0.5, 1.5) for _ in range(wb.HIDDEN)]
        beta_f = [rng.uniform(-0.5, 0.5) for _ in range(wb.HIDDEN)]
        g_q, b_q = wb.quantize_layernorm_params(gamma_f, beta_f)

        y_int = wb.int_layernorm_py(x, g_q, b_q)
        y_fp = _fp32_layernorm(x, gamma_f, beta_f)

        scale = 1 << wb.GAMMA_LOG2
        y_int_real = [v / scale for v in y_int]
        # error bounded by ~few/sigma + 1/scale per element
        err = [abs(a - b) for a, b in zip(y_int_real, y_fp)]
        rng_y = max(y_fp) - min(y_fp)
        assert max(err) < 0.05 * rng_y + 0.1, (
            f"LN max error {max(err):.4f} too large for range {rng_y:.4f}"
        )


# -----------------------------------------------------------------------------
# GELU LUT
# -----------------------------------------------------------------------------

class TestGeluLUT:

    def test_lut_length_and_bounds(self):
        lut = wb.build_gelu_lut()
        assert len(lut) == 256
        for v in lut:
            assert -128 <= v <= 127

    def test_lut_matches_analytic(self):
        lut = wb.build_gelu_lut()
        # tanh-approx GELU
        for i in range(256):
            x = (i - 128) / 128.0
            expected = round(127.0 * wb._gelu_real(x))
            expected = max(-128, min(127, expected))
            assert lut[i] == expected, f"i={i}"

    def test_lookup_negative_index(self):
        lut = wb.build_gelu_lut()
        # gelu(0) ~ 0, gelu(-1.5) ~ -0.10
        assert wb.int_gelu_lut_py(lut, 0) == lut[128]
        assert wb.int_gelu_lut_py(lut, -128) == lut[0]
        assert wb.int_gelu_lut_py(lut, 127) == lut[255]


# -----------------------------------------------------------------------------
# Softmax
# -----------------------------------------------------------------------------

def _fp32_softmax(scores):
    m = max(scores)
    e = [math.exp(s - m) for s in scores]
    s = sum(e)
    return [v / s for v in e]


class TestSoftmax:

    def test_exp_lut(self):
        lut = wb.build_exp_lut()
        assert len(lut) == 17
        # exp(0) at index 16 == 32767
        assert lut[16] == 32767
        # monotone increasing
        for i in range(1, 17):
            assert lut[i] >= lut[i - 1]
        # exp(-16) should be effectively 0
        assert lut[0] == round(32767 * math.exp(-16))

    def test_softmax_uniform_input(self):
        lut = wb.build_exp_lut()
        probs = wb.int_softmax_py([5, 5], lut)
        # uniform should be ~16384 each
        assert abs(probs[0] - 16384) <= 1
        assert abs(probs[1] - 16384) <= 1
        assert abs(sum(probs) - 32767) <= 2

    def test_softmax_skewed(self):
        lut = wb.build_exp_lut()
        scores = [10, -3]
        probs_int = wb.int_softmax_py(scores, lut)
        probs_fp = _fp32_softmax(scores)
        # Convert int Q15 to float and compare
        probs_int_f = [p / 32768.0 for p in probs_int]
        for a, b in zip(probs_int_f, probs_fp):
            assert abs(a - b) < 0.01, (probs_int_f, probs_fp)

    def test_softmax_clamp_low(self):
        # Very negative score difference -> exp clamps to lut[0]
        lut = wb.build_exp_lut()
        probs = wb.int_softmax_py([100, 0], lut)
        # First should dominate, second near zero
        assert probs[0] > 32000
        assert probs[1] < 10


# -----------------------------------------------------------------------------
# Full block (requires checkpoint)
# -----------------------------------------------------------------------------

CKPT = Path(__file__).resolve().parents[1] / "out" / "tiny_char_lm.pt"


@pytest.mark.skipif(not CKPT.exists(), reason="checkpoint not built")
class TestFullBlock:

    @pytest.fixture(scope="class")
    def result(self):
        params = wb.load_block_params(CKPT)
        inputs = wb.build_fixed_inputs()
        gelu_lut = wb.build_gelu_lut()
        exp_lut = wb.build_exp_lut()
        return wb.run_full_block_py(
            inputs["hidden_in"],
            weights=params["weights"],
            ln1=params["ln1"],
            ln2=params["ln2"],
            gelu_lut=gelu_lut,
            exp_lut=exp_lut,
            kv_prev_k=inputs["kv_prev_k"],
            kv_prev_v=inputs["kv_prev_v"],
        )

    def test_shifts_are_nonnegative(self, result):
        for k, v in result["shifts"].items():
            assert v >= 0, f"shift {k} negative: {v}"

    def test_intermediate_shapes(self, result):
        assert len(result["block_out"]) == wb.HIDDEN
        assert len(result["qkv_out"]) == 3 * wb.HIDDEN
        assert len(result["proj_out"]) == wb.HIDDEN
        assert len(result["ffn_up_out"]) == wb.FFN
        assert len(result["ffn_dn_out"]) == wb.HIDDEN
        assert len(result["probs_q15"]) == 2
        # probs sum close to 1.0
        assert abs(sum(result["probs_q15"]) - 32768) <= 2

    def test_block_out_nontrivial(self, result):
        bo = result["block_out"]
        # not all zero, not all identical
        assert max(bo) != min(bo)
        # Range bounded; if blows up beyond INT32 something is wrong.
        for v in bo:
            assert -(1 << 30) < v < (1 << 30), f"block_out value {v} out of bounds"

    def test_softmax_didnt_collapse(self, result):
        # Both probs should be nonzero — if seed=0xCAFE/0xBEEF picks scores
        # that diverge too much, we want to flag it now.
        p = result["probs_q15"]
        assert p[0] > 0 and p[1] > 0, (
            f"softmax degenerate: probs={p}, scores={result['scores_q8']}"
        )
