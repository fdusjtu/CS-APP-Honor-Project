#ifndef W4A8_CPU_REF_H
#define W4A8_CPU_REF_H

#include <stdint.h>

/*
 * Naive CPU baseline for W4A8 GEMV.
 *   y[r] = ((sum_{c=0..N-1} W4[r][c] * INT8 act[c]) * scale[r]) >> shift
 *
 * Weights are packed row-major, two signed INT4 values per byte:
 *   byte b of row r = (W[r][2*b] & 0xF) | ((W[r][2*b+1] & 0xF) << 4)
 *
 * Output matches w4a8_linear_engine bit-exactly for the same (W, x, scale,
 * shift) inputs, so y from this kernel can be compared directly against the
 * FPGA y_ref read back over MMIO.
 *
 * Constraints (also enforced by the engine):
 *   - N must be a positive multiple of 2.
 *   - shift is the per-row Q-format right-shift count, normally 14.
 */
void w4a8_cpu_gemv(int m, int n,
                   const uint8_t *w_packed,
                   const int8_t *act,
                   const int16_t *scale,
                   int shift,
                   int32_t *y_out);

#endif
