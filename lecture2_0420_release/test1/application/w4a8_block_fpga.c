/* Step-4 FPGA Transformer Block demo / benchmark. */
#define W4A8_BLOCK_CPU_REF 1
#include <stdint.h>
#include "w4a8.h"
#include "w4a8_block_fpga.h"
#include "w4a8_block_full_vectors.h"   /* w4a8b_hidden_in, w4a8b_block_out_golden */

/* Define W4A8_BLOCK_CPU_REF to also time the true all-CPU full block (4 Linears
 * via w4a8_cpu_gemv on weights read back from FPGA BRAM) for an honest speedup.
 * Requires w4a8_block_cpu.c + w4a8_ops.c + w4a8_cpu_ref.c in the build. */
#ifdef W4A8_BLOCK_CPU_REF
#include "w4a8_block_cpu.h"            /* w4a8_run_full_block_cpu, verify */
#endif

#ifndef W4A8_BLOCK_RUN_TIMEOUT
#define W4A8_BLOCK_RUN_TIMEOUT 5000000u
#endif

extern int printf(const char *, ...);

static inline uint32_t blk_read_cycle(void)
{
    uint32_t c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

static int32_t s_block_out[W4A8B_HIDDEN];
#ifdef W4A8_BLOCK_CPU_REF
static int32_t s_block_out_cpu[W4A8B_HIDDEN];
#endif

int w4a8_run_block_fpga_demo(void)
{
    uint32_t fpga_cycles = 0;
    uint32_t t0, t1, fpga_call_cycles;
    int i, mism = 0;

    printf("\r\nTransformer Block Accelerator\r\n");

    t0 = blk_read_cycle();
    if (w4a8_run_block_fpga(w4a8b_hidden_in, s_block_out,
                            W4A8_BLOCK_RUN_TIMEOUT, &fpga_cycles) != 0) {
        printf("  block FPGA TIMEOUT status=0x%08x\r\n",
               (unsigned)W4A8_BLOCK_STATUS);
        return -1;
    }
    t1 = blk_read_cycle();
    fpga_call_cycles = t1 - t0;

    for (i = 0; i < W4A8B_HIDDEN; i++)
        if (s_block_out[i] != w4a8b_block_out_golden[i])
            mism++;

    if (mism == 0)
        printf("  block_out bit-exact PASS (%d / %d mismatches)\r\n",
               mism, W4A8B_HIDDEN);
    else
        printf("  block_out bit-exact FAIL (%d / %d mismatches)\r\n",
               mism, W4A8B_HIDDEN);

#ifdef W4A8_BLOCK_CPU_REF
    {
        uint32_t cpu_cycles;
        t0 = blk_read_cycle();
        w4a8_run_full_block_cpu(w4a8b_hidden_in, s_block_out_cpu);
        t1 = blk_read_cycle();
        cpu_cycles = t1 - t0;

        /* Cross-check the CPU path is bit-exact to the same golden. */
        {
            int cpu_mism = 0;
            for (int j = 0; j < W4A8B_HIDDEN; j++)
                if (s_block_out_cpu[j] != w4a8b_block_out_golden[j])
                    cpu_mism++;
            printf("  CPU block bit-exact vs golden : %s (%d / %d)\r\n",
                   cpu_mism == 0 ? "PASS" : "FAIL", cpu_mism, W4A8B_HIDDEN);
        }

        printf("  CPU block cycles      = %u\r\n", (unsigned)cpu_cycles);
        printf("  FPGA block cycles     = %u (engine), %u (call)\r\n",
               (unsigned)fpga_cycles, (unsigned)fpga_call_cycles);
        if (fpga_cycles)
            printf("  block speedup engine  = x%u.%02u\r\n",
                   (unsigned)(cpu_cycles / fpga_cycles),
                   (unsigned)((cpu_cycles % fpga_cycles) * 100u / fpga_cycles));
        if (fpga_call_cycles)
            printf("  block speedup call    = x%u.%02u\r\n",
                   (unsigned)(cpu_cycles / fpga_call_cycles),
                   (unsigned)((cpu_cycles % fpga_call_cycles) * 100u / fpga_call_cycles));
    }
#else
    printf("  FPGA block cycles     = %u (engine), %u (call)\r\n",
           (unsigned)fpga_cycles, (unsigned)fpga_call_cycles);
#endif

    if (mism == 0)
        printf("FULL BLOCK PASS\r\n");
    else
        printf("FULL BLOCK FAIL\r\n");

    return mism == 0 ? 0 : -1;
}
