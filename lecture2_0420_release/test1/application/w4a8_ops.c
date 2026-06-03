/* Step 3b integer ops. Bit-exact to tools/w4a8_block_full.py. */
#include "w4a8_ops.h"

int32_t w4a8_round_shift(int32_t value, int shift)
{
    if (shift <= 0)
        return value << (-shift);
    int32_t half = (int32_t)1 << (shift - 1);
    if (value >= 0)
        return (value + half) >> shift;
    return -(((-value) + half) >> shift);
}

int32_t w4a8_round_div_signed(int32_t num, int32_t den)
{
    int32_t half = den >> 1;       /* den > 0, equivalent to den/2 floor */
    if (num >= 0)
        return (num + half) / den;
    return -(((-num) + half) / den);
}

int32_t w4a8_isqrt_floor(int32_t n)
{
    if (n < 2)
        return n;
    int32_t x = n;
    int32_t y = (x + 1) >> 1;
    while (y < x) {
        x = y;
        y = (x + n / x) >> 1;
    }
    return x;
}

int8_t w4a8_sat8(int32_t v)
{
    if (v >  127) return  127;
    if (v < -128) return -128;
    return (int8_t)v;
}

int16_t w4a8_sat16(int32_t v)
{
    if (v >  32767)  return  32767;
    if (v < -32768)  return -32768;
    return (int16_t)v;
}

void w4a8_int_layernorm(const int32_t *x, int N, int log2N,
                        const int8_t *gamma_q,
                        const int16_t *beta_q,
                        int32_t *y_out)
{
    int32_t sum = 0;
    for (int i = 0; i < N; i++)
        sum += x[i];
    int32_t mean = w4a8_round_shift(sum, log2N);

    int32_t sq_sum = 0;
    for (int i = 0; i < N; i++) {
        int32_t d = x[i] - mean;
        sq_sum += d * d;
    }
    int32_t var = w4a8_round_shift(sq_sum, log2N);
    if (var < 1) var = 1;
    int32_t sigma = w4a8_isqrt_floor(var);
    if (sigma < 1) sigma = 1;

    for (int i = 0; i < N; i++) {
        int32_t d = x[i] - mean;
        int32_t num = d * (int32_t)gamma_q[i];
        int32_t q = w4a8_round_div_signed(num, sigma);
        y_out[i] = q + (int32_t)beta_q[i];
    }
}

int8_t w4a8_int_gelu_lut(const int8_t *gelu_lut, int8_t x)
{
    int idx = (int)x + 128;        /* signed INT8 -> 0..255 */
    return gelu_lut[idx];
}

void w4a8_int_softmax(const int8_t *scores_q8, int L,
                      const int16_t *exp_lut,
                      int16_t *probs_q15)
{
    if (L <= 0) return;
    int32_t m = scores_q8[0];
    for (int i = 1; i < L; i++)
        if (scores_q8[i] > m) m = scores_q8[i];

    int32_t exp_q[80];   /* Step 4 max is prompt(7)+generation(64) = 71. */
    if (L > 80)
        L = 80;
    int32_t sum_exp = 0;
    for (int i = 0; i < L; i++) {
        int32_t y = (int32_t)scores_q8[i] - m;
        if (y < -16) y = -16;
        if (y >  0) y = 0;
        exp_q[i] = exp_lut[y + 16];
        sum_exp += exp_q[i];
    }
    if (sum_exp <= 0) {
        for (int i = 0; i < L; i++)
            probs_q15[i] = (int16_t)(32768 / L);
        return;
    }
    int32_t half = sum_exp >> 1;
    for (int i = 0; i < L; i++) {
        int32_t num = exp_q[i] << 15;
        int32_t q = (num + half) / sum_exp;
        if (q > 32767) q = 32767;
        probs_q15[i] = (int16_t)q;
    }
}
