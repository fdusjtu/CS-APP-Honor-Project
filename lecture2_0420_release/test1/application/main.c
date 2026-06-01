// See LICENSE for license details.
#include <stdio.h>
#include <stdint.h>
#include "hbird_sdk_soc.h"
#include "w4a8.h"
#include "w4a8_selftest_vectors.h"
#include "w4a8_cpu_ref.h"
#include "w4a8_cpu_ref_weights.h"
#include "w4a8_block_full.h"
#include "w4a8_block_full_vectors.h"

#define W4A8_RUN_TIMEOUT  10000000u
#define W4A8_MAX_Y_WORDS  384

static inline uint32_t read_cycle(void)
{
    uint32_t cycle;

    asm volatile("csrr %0, mcycle" : "=r"(cycle));
    return cycle;
}

static int compare_y(const int32_t *got, const int32_t *golden, int count)
{
    int i;

    for (i = 0; i < count; i++) {
        if (got[i] != golden[i]) {
            printf("mismatch y[%d]: got=%d golden=%d\r\n",
                   i, (int)got[i], (int)golden[i]);
            return -1;
        }
    }

    return 0;
}

int main(void)
{
    static int32_t y[W4A8_MAX_Y_WORDS];
    uint32_t t0, t1;
    int all_pass;
    int i;

    /* ------------------------------------------------------------------ */
    /* Phase 1: 9-layer FPGA self-test (BIST). Compact one-line output    */
    /* on success; detailed per-layer dump only on failure.               */
    /* ------------------------------------------------------------------ */
    printf("W4A8 boot self-test\r\n");

    W4A8_SHIFT = W4A8_ST_SHIFT;
    for (i = 0; i < W4A8_ST_N_LAYERS; i++) {
        const w4a8_selftest_layer_t *ly = &w4a8_st_layers[i];

        w4a8_write_desc(ly->id, ly->m, ly->n, ly->w_base, ly->s_base);
    }

    all_pass = 1;
    uint32_t agg_engine_total = 0;
    uint32_t agg_engine_mac   = 0;
    for (i = 0; i < W4A8_ST_N_LAYERS; i++) {
        const w4a8_selftest_layer_t *ly = &w4a8_st_layers[i];
        const uint32_t *act = &w4a8_st_act[ly->act_offset];
        const int32_t *golden = &w4a8_st_y_ref[ly->y_offset];
        int rc;

        t0 = read_cycle();
        rc = w4a8_run_layer(ly->id,
                            act,
                            ly->act_words,
                            y,
                            ly->y_words,
                            W4A8_RUN_TIMEOUT);
        t1 = read_cycle();

        if (rc != 0) {
            printf("  %s TIMEOUT status=0x%08x\r\n",
                   ly->name, (unsigned)W4A8_STATUS);
            all_pass = 0;
            continue;
        }
        if (compare_y(y, golden, ly->y_words) != 0) {
            printf("  %s FAIL\r\n", ly->name);
            all_pass = 0;
            continue;
        }
        if ((int)W4A8_CNT_MAC != ly->mac_cycles ||
            (int)W4A8_CNT_TILES != ly->tiles) {
            printf("  %s FAIL counters mac=%u/%d tiles=%u/%d\r\n",
                   ly->name,
                   (unsigned)W4A8_CNT_MAC, ly->mac_cycles,
                   (unsigned)W4A8_CNT_TILES, ly->tiles);
            all_pass = 0;
            continue;
        }
        agg_engine_total += (uint32_t)W4A8_CNT_TOTAL;
        agg_engine_mac   += (uint32_t)W4A8_CNT_MAC;
        (void)t0; (void)t1;
    }

    if (all_pass) {
        uint32_t util_pct =
            agg_engine_total ? (agg_engine_mac * 100u) / agg_engine_total : 0u;
        printf("  9-layer FPGA self-test PASS (engine cycles=%u MAC util=%u%%)\r\n",
               (unsigned)agg_engine_total, (unsigned)util_pct);
    } else {
        printf("  9-layer FPGA self-test FAIL\r\n");
    }

    /* ------------------------------------------------------------------ */
    /* Phase 2: CPU baseline + speedup over representative layers.        */
    /* ------------------------------------------------------------------ */
    if (!all_pass) {
        printf("CPU BASELINE SKIPPED (self-test failed)\r\n");
        return 1;
    }

    printf("\r\nW4A8 per-layer CPU vs FPGA baseline\r\n");

    int baseline_ok = 1;
    uint32_t total_cpu = 0;
    uint32_t total_fpga_call = 0;
    uint32_t total_fpga_engine = 0;
    int j;

    for (j = 0; j < W4A8_CPU_REF_N_LAYERS; j++) {
        const w4a8_cpu_ref_layer_t *cl = &w4a8_cpu_ref_layers[j];
        const w4a8_selftest_layer_t *fl = &w4a8_st_layers[cl->id];
        const uint32_t *act_words = &w4a8_st_act[fl->act_offset];
        uint32_t fpga_call, fpga_engine, cpu_cyc;
        int rc;
        int mismatch;
        int k;

        /* Re-run FPGA for this layer to capture fresh call/engine cycles. */
        t0 = read_cycle();
        rc = w4a8_run_layer(cl->id,
                            act_words,
                            fl->act_words,
                            y,
                            fl->y_words,
                            W4A8_RUN_TIMEOUT);
        t1 = read_cycle();
        fpga_call = t1 - t0;
        fpga_engine = (uint32_t)W4A8_CNT_TOTAL;

        if (rc != 0) {
            printf("%s FPGA TIMEOUT status=0x%08x\r\n",
                   cl->name, (unsigned)W4A8_STATUS);
            baseline_ok = 0;
            continue;
        }
        if (compare_y(y, cl->y_ref, cl->m) != 0) {
            printf("%s FPGA y vs CPU-ref y_ref FAIL\r\n", cl->name);
            baseline_ok = 0;
            continue;
        }

        /* Naive CPU W4A8 GEMV. y[] is reused as the destination buffer. */
        t0 = read_cycle();
        w4a8_cpu_gemv(cl->m, cl->n,
                      cl->w_packed, cl->act, cl->scale, cl->shift,
                      y);
        t1 = read_cycle();
        cpu_cyc = t1 - t0;

        mismatch = 0;
        for (k = 0; k < cl->m; k++) {
            if (y[k] != cl->y_ref[k]) {
                printf("%s CPU mismatch y[%d]: got=%d golden=%d\r\n",
                       cl->name, k, (int)y[k], (int)cl->y_ref[k]);
                mismatch = 1;
                break;
            }
        }
        if (mismatch) {
            baseline_ok = 0;
            continue;
        }

        /* Fixed-point xN.NN speedup (avoid pulling in soft-float printf). */
        uint32_t sp_call_x100 = fpga_call ? (cpu_cyc * 100u) / fpga_call : 0u;
        uint32_t sp_eng_x100  = fpga_engine ? (cpu_cyc * 100u) / fpga_engine : 0u;

        printf("  %s %dx%d CPU=%u FPGA_call=%u FPGA_engine=%u\r\n",
               cl->name, cl->m, cl->n,
               (unsigned)cpu_cyc, (unsigned)fpga_call, (unsigned)fpga_engine);
        printf("    speedup call=x%u.%02u engine=x%u.%02u\r\n",
               (unsigned)(sp_call_x100 / 100u), (unsigned)(sp_call_x100 % 100u),
               (unsigned)(sp_eng_x100  / 100u), (unsigned)(sp_eng_x100  % 100u));

        total_cpu += cpu_cyc;
        total_fpga_call += fpga_call;
        total_fpga_engine += fpga_engine;
    }

    if (baseline_ok) {
        uint32_t agg_call_x100 =
            total_fpga_call ? (total_cpu * 100u) / total_fpga_call : 0u;
        uint32_t agg_eng_x100 =
            total_fpga_engine ? (total_cpu * 100u) / total_fpga_engine : 0u;
        printf("  AGG CPU=%u FPGA_call=%u FPGA_engine=%u\r\n",
               (unsigned)total_cpu,
               (unsigned)total_fpga_call,
               (unsigned)total_fpga_engine);
        printf("  AGG speedup call=x%u.%02u engine=x%u.%02u\r\n",
               (unsigned)(agg_call_x100 / 100u), (unsigned)(agg_call_x100 % 100u),
               (unsigned)(agg_eng_x100  / 100u), (unsigned)(agg_eng_x100  % 100u));
        printf("CPU BASELINE PASS\r\n");
    } else {
        printf("CPU BASELINE FAIL\r\n");
    }

    /* ------------------------------------------------------------------ */
    /* Phase 3: full Transformer block (LN + attn + softmax + GELU + res) */
    /* ------------------------------------------------------------------ */
    int block_ok = 0;
    if (baseline_ok) {
        static int32_t block_out[W4A8B_HIDDEN];

        printf("\r\nW4A8 full Transformer block (LN+attn+softmax+GELU+residual)\r\n");
        t0 = read_cycle();
        int brc = w4a8_run_full_block(w4a8b_hidden_in, block_out);
        t1 = read_cycle();
        uint32_t block_fpga_cycles = t1 - t0;

        if (brc != 0) {
            printf("  full block FPGA TIMEOUT\r\n");
        } else {
            int mismatches = 0;
            for (int k = 0; k < W4A8B_HIDDEN; k++) {
                if (block_out[k] != w4a8b_block_out_golden[k]) {
                    if (mismatches < 3) {
                        printf("    block_out[%d] got=%d golden=%d\r\n",
                               k, (int)block_out[k],
                               (int)w4a8b_block_out_golden[k]);
                    }
                    mismatches++;
                }
            }
            printf("  block_out bit-exact vs Python golden : %s (%d / %d mismatches)\r\n",
                   mismatches == 0 ? "PASS" : "FAIL",
                   mismatches, W4A8B_HIDDEN);
            printf("  full block FPGA cycles = %u\r\n", (unsigned)block_fpga_cycles);
            if (mismatches == 0)
                block_ok = 1;
        }

        if (block_ok)
            printf("FULL BLOCK PASS\r\n");
        else
            printf("FULL BLOCK FAIL\r\n");
    } else {
        printf("FULL BLOCK SKIPPED (baseline failed)\r\n");
    }

    return (all_pass && baseline_ok && block_ok) ? 0 : 1;
}
