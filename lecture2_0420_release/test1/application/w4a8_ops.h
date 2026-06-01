/*
 * Integer primitives and non-linear ops for Step 3b.
 *
 * Each function is a literal C translation of the matching helper in
 * tools/w4a8_block_full.py and is bit-exact to the Python golden.
 */
#ifndef W4A8_OPS_H
#define W4A8_OPS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* value / 2^shift, round-to-nearest, ties away from zero. */
int32_t w4a8_round_shift(int32_t value, int shift);

/* num / den, round-to-nearest, ties away from zero. den must be > 0. */
int32_t w4a8_round_div_signed(int32_t num, int32_t den);

/* floor(sqrt(n)) via Newton iteration. n must be >= 0. */
int32_t w4a8_isqrt_floor(int32_t n);

int8_t  w4a8_sat8(int32_t v);
int16_t w4a8_sat16(int32_t v);

/*
 * LayerNorm.
 * x: INT32[N] input vector (typed accumulator).
 * gamma_q: INT8[N]   — quantized gamma (gamma_real * 2^GAMMA_LOG2).
 * beta_q : INT16[N]  — quantized beta  (beta_real  * 2^GAMMA_LOG2).
 * y_out  : INT32[N]  — LayerNorm result in Q-GAMMA_LOG2 (caller right-shifts).
 *
 * N must equal W4A8B_HIDDEN (and log2N == 7).
 */
void w4a8_int_layernorm(const int32_t *x, int N, int log2N,
                        const int8_t *gamma_q,
                        const int16_t *beta_q,
                        int32_t *y_out);

/* gelu_lut[256] indexed by signed INT8 (offset by 128 internally). */
int8_t w4a8_int_gelu_lut(const int8_t *gelu_lut, int8_t x);

/*
 * Softmax over an INT8 score vector of length L.
 *
 * Output: probs_q15[L] in Q0.15 (INT16, [0..32767]). The exp LUT must have
 * exactly 17 entries with exp_lut[16] = exp(0) (= 32767).
 */
void w4a8_int_softmax(const int8_t *scores_q8, int L,
                      const int16_t *exp_lut,
                      int16_t *probs_q15);

#ifdef __cplusplus
}
#endif

#endif /* W4A8_OPS_H */
