// See LICENSE for license details.
#include <stdio.h>
#include <stdint.h>

#include "hbird_sdk_soc.h"
#include "w4a8.h"
#include "w4a8_cpu_ref.h"
#include "w4a8_cpu_ref_weights.h"
#include "w4a8_block_fpga.h"

#define W4A8_RUN_TIMEOUT  10000000u
#define W4A8_MAX_Y_WORDS  384

static int32_t s_fpga_y[W4A8_MAX_Y_WORDS];
static int32_t s_cpu_y[W4A8_MAX_Y_WORDS];
static uint32_t s_act_words[64];

static inline uint32_t read_cycle(void)
{
    uint32_t cycle;
    asm volatile("csrr %0, mcycle" : "=r"(cycle));
    return cycle;
}

static void pack_i8(const int8_t *src, int count, uint32_t *dst)
{
    for (int i = 0; i < count; i += 4) {
        dst[i >> 2] =
              ((uint32_t)(uint8_t)src[i + 0])
            | ((uint32_t)(uint8_t)src[i + 1]) <<  8
            | ((uint32_t)(uint8_t)src[i + 2]) << 16
            | ((uint32_t)(uint8_t)src[i + 3]) << 24;
    }
}

static int compare_y(const int32_t *got, const int32_t *golden, int count)
{
    for (int i = 0; i < count; i++) {
        if (got[i] != golden[i]) {
            printf("mismatch y[%d]: got=%d golden=%d\r\n",
                   i, (int)got[i], (int)golden[i]);
            return -1;
        }
    }
    return 0;
}

static int run_cpu_baseline(void)
{
    uint32_t total_cpu = 0;
    uint32_t total_fpga_call = 0;
    uint32_t total_fpga_engine = 0;
    int baseline_ok = 1;

    printf("W4A8 per-layer CPU vs FPGA baseline\r\n");

    for (int j = 0; j < W4A8_CPU_REF_N_LAYERS; j++) {
        const w4a8_cpu_ref_layer_t *cl = &w4a8_cpu_ref_layers[j];
        uint32_t t0, t1;
        uint32_t fpga_call, fpga_engine, cpu_cyc;
        int rc;

        pack_i8(cl->act, cl->n, s_act_words);

        t0 = read_cycle();
        rc = w4a8_run_layer(cl->id,
                            s_act_words,
                            cl->n / 4,
                            s_fpga_y,
                            cl->m,
                            W4A8_RUN_TIMEOUT);
        t1 = read_cycle();
        fpga_call = t1 - t0;
        fpga_engine = (uint32_t)W4A8_CNT_TOTAL;

        if (rc != 0) {
            printf("  %s FPGA TIMEOUT status=0x%08x\r\n",
                   cl->name, (unsigned)W4A8_STATUS);
            baseline_ok = 0;
            continue;
        }

        t0 = read_cycle();
        w4a8_cpu_gemv(cl->m, cl->n,
                      cl->w_packed, cl->act, cl->scale, cl->shift,
                      s_cpu_y);
        t1 = read_cycle();
        cpu_cyc = t1 - t0;

        if (compare_y(s_fpga_y, s_cpu_y, cl->m) != 0) {
            printf("  %s FPGA vs CPU FAIL\r\n", cl->name);
            baseline_ok = 0;
            continue;
        }

        uint32_t sp_call_x100 = fpga_call ? (cpu_cyc * 100u) / fpga_call : 0u;
        uint32_t sp_eng_x100 = fpga_engine ? (cpu_cyc * 100u) / fpga_engine : 0u;

        printf("  %s %dx%d CPU=%u FPGA_call=%u FPGA_engine=%u\r\n",
               cl->name, cl->m, cl->n,
               (unsigned)cpu_cyc, (unsigned)fpga_call, (unsigned)fpga_engine);
        printf("    speedup call=x%u.%02u engine=x%u.%02u\r\n",
               (unsigned)(sp_call_x100 / 100u), (unsigned)(sp_call_x100 % 100u),
               (unsigned)(sp_eng_x100 / 100u), (unsigned)(sp_eng_x100 % 100u));

        total_cpu += cpu_cyc;
        total_fpga_call += fpga_call;
        total_fpga_engine += fpga_engine;
    }

    if (baseline_ok) {
        uint32_t agg_call_x100 =
            total_fpga_call ? (total_cpu * 100u) / total_fpga_call : 0u;
        uint32_t agg_eng_x100 =
            total_fpga_engine ? (total_cpu * 100u) / total_fpga_engine : 0u;
        printf("  AGG speedup call=x%u.%02u engine=x%u.%02u\r\n",
               (unsigned)(agg_call_x100 / 100u), (unsigned)(agg_call_x100 % 100u),
               (unsigned)(agg_eng_x100 / 100u), (unsigned)(agg_eng_x100 % 100u));
        printf("CPU BASELINE PASS\r\n");
    } else {
        printf("CPU BASELINE FAIL\r\n");
    }

    return baseline_ok ? 0 : -1;
}

static void init_w4a8_descriptors(void)
{
    W4A8_SHIFT = 14u;

    w4a8_write_desc(0, 384, 128,    0,   0);  /* layer0_qkv */
    w4a8_write_desc(1, 128, 128,  384, 192);  /* layer0_proj */
    w4a8_write_desc(2, 256, 128,  512, 256);  /* layer0_ffn_up */
    w4a8_write_desc(3, 128, 256,  768, 384);  /* layer0_ffn_down */
    w4a8_write_desc(4, 384, 128, 1024, 448);  /* layer1_qkv */
    w4a8_write_desc(5, 128, 128, 1408, 640);  /* layer1_proj */
    w4a8_write_desc(6, 256, 128, 1536, 704);  /* layer1_ffn_up */
    w4a8_write_desc(7, 128, 256, 1792, 832);  /* layer1_ffn_down */
    w4a8_write_desc(8,  64, 128, 2048, 896);  /* lm_head */
}

int main(void)
{
    int baseline_ok;
    int block_ok;

    init_w4a8_descriptors();

    baseline_ok = run_cpu_baseline();
    block_ok = w4a8_run_block_fpga_demo();

    return (baseline_ok == 0 && block_ok == 0) ? 0 : 1;
}
