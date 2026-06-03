#ifndef W4A8_BLOCK_FPGA_H
#define W4A8_BLOCK_FPGA_H

/* Step-4 FPGA Transformer Block demo / benchmark.
 *
 * Runs the whole transformer block on the FPGA block engine, compares the
 * output bit-exact against the Python golden (w4a8b_block_out_golden), and
 * prints the Step-4 UART lines. Optionally compares against the software
 * reference (w4a8_run_full_block) to report CPU vs FPGA block speedup.
 *
 * Prerequisite: descriptors 0..3 (qkv/proj/ffn_up/ffn_down) must already be
 * written into the engine descriptor table (e.g. by the boot descriptor init).
 *
 * Returns 0 on bit-exact PASS, non-zero otherwise.
 */
int w4a8_run_block_fpga_demo(void);

#endif /* W4A8_BLOCK_FPGA_H */
