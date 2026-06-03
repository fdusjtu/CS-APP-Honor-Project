/*
 * True all-CPU Transformer block reference (Method A).
 *
 * Identical dataflow to w4a8_run_full_block(), but the four Linear layers
 * (qkv / proj / ffn_up / ffn_down) run on the CPU via w4a8_cpu_gemv instead of
 * being offloaded to the FPGA. The INT4 weights are read back from FPGA BRAM at
 * boot into a DTCM scratch buffer (so they cost no ILM), then matmul'd on the
 * E203 core. This is the honest CPU baseline for the block speedup.
 */
#ifndef W4A8_BLOCK_CPU_H
#define W4A8_BLOCK_CPU_H

#include <stdint.h>

/* Run the whole transformer block on the CPU (4 Linears via w4a8_cpu_gemv on
   readback weights). hidden_in: INT8[128], block_out: INT32[128]. Returns 0. */
int w4a8_run_full_block_cpu(const int8_t *hidden_in, int32_t *block_out);

#endif /* W4A8_BLOCK_CPU_H */
