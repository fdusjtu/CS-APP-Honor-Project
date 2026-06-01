#include "w4a8_cpu_ref.h"

/*
 * Naive C reference: per row r, accumulate W4 * INT8 over all N columns into
 * an INT32 accumulator, then apply the per-row INT16 scale and arithmetic
 * right shift. Matches tools/w4a8_common.py:golden_linear() bit-exactly.
 *
 * Intentionally unoptimised: no loop unroll, no nibble parallelism, no
 * accumulator reordering. This is the "baseline" the FPGA speedup is
 * reported against.
 */
void w4a8_cpu_gemv(int m, int n,
                   const uint8_t *w_packed,
                   const int8_t *act,
                   const int16_t *scale,
                   int shift,
                   int32_t *y_out)
{
    const int half_n = n >> 1;
    int r;

    for (r = 0; r < m; r++) {
        const uint8_t *w_row = w_packed + r * half_n;
        int32_t acc = 0;
        int b;

        for (b = 0; b < half_n; b++) {
            uint8_t byte = w_row[b];
            int32_t lo = byte & 0xF;
            int32_t hi = (byte >> 4) & 0xF;
            /* sign-extend the 4-bit nibbles (range [-8, 7]). */
            if (lo & 0x8) lo -= 16;
            if (hi & 0x8) hi -= 16;

            acc += lo * (int32_t)act[2 * b];
            acc += hi * (int32_t)act[2 * b + 1];
        }

        /*
         * acc fits in INT32 (worst case 384 * 7 * 127 ~= 341 k). scale fits
         * in INT16. Their product can need 47 bits, so widen to INT64 before
         * the arithmetic right shift, then narrow.
         */
        y_out[r] = (int32_t)(((int64_t)acc * (int64_t)scale[r]) >> shift);
    }
}
