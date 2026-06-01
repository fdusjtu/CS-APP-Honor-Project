/*
 * Step 3b full transformer block (LN + qkv + attn + softmax + proj + res +
 * LN + ffn_up + GELU + ffn_dn + res). All non-Linear ops are integer
 * routines from w4a8_ops.{c,h}; all Linear layers run on the FPGA engine.
 */
#ifndef W4A8_BLOCK_FULL_H
#define W4A8_BLOCK_FULL_H

#include <stdint.h>

#define W4A8_BLOCK_RUN_TIMEOUT  10000000u

/*
 * Run one full transformer block on the FPGA + CPU.
 *
 *   hidden_in:  INT8[128]  — input activation (constant; matches Python golden).
 *   block_out:  INT32[128] — output of full block. Bit-exact to Python golden.
 *
 * Returns:
 *   0  on success
 *  -1  on any FPGA timeout
 */
int w4a8_run_full_block(const int8_t *hidden_in, int32_t *block_out);

#endif /* W4A8_BLOCK_FULL_H */
