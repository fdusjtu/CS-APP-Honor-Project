/* Method A: true all-CPU transformer block (4 Linears via w4a8_cpu_gemv). */
#include "w4a8_block_cpu.h"
#include "w4a8.h"
#include "w4a8_ops.h"
#include "w4a8_cpu_ref.h"
#include "w4a8_cpu_ref_weights.h"   /* layer0_qkv/proj scales (weights via readback) */
#include "w4a8_ffn_scales.h"        /* layer0_ffn_up/down scales */
#include "w4a8_block_full_vectors.h"

#define HIDDEN   W4A8B_HIDDEN
#define FFN      W4A8B_FFN
#define HEAD_DIM W4A8B_HEAD_DIM
#define LIN_SHIFT W4A8_CPU_REF_SHIFT   /* engine W4A8_SHIFT == 14 */

/* Resident Linear descriptors (must match init_w4a8_descriptors in main.c). */
#define QKV_WBASE      0
#define PROJ_WBASE   384
#define FFN_UP_WBASE 512
#define FFN_DN_WBASE 768

/* DTCM scratch (.bss, no ILM cost). One reusable weight buffer sized for the
   largest layer (qkv 384x128 -> 24576 bytes). */
static uint8_t s_wbuf[384 * 128 / 2];

static int32_t s_ln1_out [HIDDEN];
static int32_t s_ln2_out [HIDDEN];
static int8_t  s_ln1_q8  [HIDDEN];
static int8_t  s_ln2_q8  [HIDDEN];
static int32_t s_qkv_out [3 * HIDDEN];
static int8_t  s_Q_q8    [HIDDEN];
static int8_t  s_K1_q8   [HIDDEN];
static int8_t  s_V1_q8   [HIDDEN];
static int8_t  s_scores_q8 [2];
static int16_t s_probs_q15 [2];
static int8_t  s_attn_q8  [HIDDEN];
static int32_t s_proj_out [HIDDEN];
static int32_t s_res1     [HIDDEN];
static int32_t s_ffn_up_out [FFN];
static int8_t  s_ffn_up_q8  [FFN];
static int8_t  s_gelu_out   [FFN];
static int32_t s_ffn_dn_out [HIDDEN];

/* Read a layer's weights from FPGA BRAM into s_wbuf, then run CPU GEMV. */
static void cpu_linear(int w_base, int m, int n,
                       const int8_t *act, const int16_t *scale, int32_t *y)
{
    w4a8_read_layer_weights(w_base, m, n, s_wbuf);
    w4a8_cpu_gemv(m, n, s_wbuf, act, scale, LIN_SHIFT, y);
}

int w4a8_run_full_block_cpu(const int8_t *hidden_in, int32_t *block_out)
{
    int32_t x_i32[HIDDEN];
    for (int i = 0; i < HIDDEN; i++)
        x_i32[i] = (int32_t)hidden_in[i];

    /* -- Stage 1: LN1 -- */
    w4a8_int_layernorm(x_i32, HIDDEN, 7,
                       w4a8b_ln1_gamma, w4a8b_ln1_beta, s_ln1_out);
    for (int i = 0; i < HIDDEN; i++)
        s_ln1_q8[i] = w4a8_sat8(w4a8_round_shift(s_ln1_out[i], W4A8B_S_LN1_OUT));

    /* -- Stage 2: qkv (CPU) -- */
    cpu_linear(QKV_WBASE, 384, 128, s_ln1_q8, layer0_qkv_scale, s_qkv_out);

    for (int i = 0; i < HIDDEN; i++)
        s_Q_q8[i] = w4a8_sat8(w4a8_round_shift(s_qkv_out[i], W4A8B_S_Q_REQUANT));
    for (int i = 0; i < HIDDEN; i++)
        s_K1_q8[i] = w4a8_sat8(w4a8_round_shift(s_qkv_out[HIDDEN + i],
                                                W4A8B_S_K_REQUANT));
    for (int i = 0; i < HIDDEN; i++)
        s_V1_q8[i] = w4a8_sat8(w4a8_round_shift(s_qkv_out[2 * HIDDEN + i],
                                                W4A8B_S_V_REQUANT));

    /* -- Stage 3: attention seq_len=2 (prev fake KV + current) -- */
    const int8_t *K_seq[2] = { w4a8b_kv_prev_k, s_K1_q8 };
    const int8_t *V_seq[2] = { w4a8b_kv_prev_v, s_V1_q8 };

    int32_t scores_i32[2];
    for (int t = 0; t < 2; t++) {
        int32_t acc = 0;
        for (int d = 0; d < HEAD_DIM; d++)
            acc += (int32_t)s_Q_q8[d] * (int32_t)K_seq[t][d];
        scores_i32[t] = acc;
    }
    for (int t = 0; t < 2; t++)
        s_scores_q8[t] = w4a8_sat8(w4a8_round_shift(scores_i32[t],
                                                    W4A8B_S_SCORES));
    w4a8_int_softmax(s_scores_q8, 2, w4a8b_exp_lut, s_probs_q15);

    for (int d = 0; d < HEAD_DIM; d++) {
        int32_t acc = 0;
        for (int t = 0; t < 2; t++)
            acc += (int32_t)s_probs_q15[t] * (int32_t)V_seq[t][d];
        int32_t back = w4a8_round_shift(acc, 15);
        s_attn_q8[d] = w4a8_sat8(w4a8_round_shift(back, W4A8B_S_ATTN_OUT));
    }

    /* -- Stage 4: proj (CPU) -- */
    cpu_linear(PROJ_WBASE, 128, 128, s_attn_q8, layer0_proj_scale, s_proj_out);

    /* -- Stage 5: residual 1 -- */
    for (int i = 0; i < HIDDEN; i++)
        s_res1[i] = ((int32_t)hidden_in[i] << W4A8B_S_LIFT) + s_proj_out[i];

    /* -- Stage 6: LN2 -- */
    w4a8_int_layernorm(s_res1, HIDDEN, 7,
                       w4a8b_ln2_gamma, w4a8b_ln2_beta, s_ln2_out);
    for (int i = 0; i < HIDDEN; i++)
        s_ln2_q8[i] = w4a8_sat8(w4a8_round_shift(s_ln2_out[i], W4A8B_S_LN2_OUT));

    /* -- Stage 7: ffn_up (CPU) -- */
    cpu_linear(FFN_UP_WBASE, 256, 128, s_ln2_q8, layer0_ffn_up_scale, s_ffn_up_out);

    /* -- Stage 8: GELU LUT -- */
    for (int i = 0; i < FFN; i++)
        s_ffn_up_q8[i] = w4a8_sat8(w4a8_round_shift(s_ffn_up_out[i],
                                                    W4A8B_S_FFN_UP_OUT));
    for (int i = 0; i < FFN; i++)
        s_gelu_out[i] = w4a8_int_gelu_lut(w4a8b_gelu_lut, s_ffn_up_q8[i]);

    /* -- Stage 9: ffn_down (CPU) -- */
    cpu_linear(FFN_DN_WBASE, 128, 256, s_gelu_out, layer0_ffn_down_scale, s_ffn_dn_out);

    /* -- Stage 10: residual 2 -> block_out -- */
    if (W4A8B_S_BLK_TRIM >= 0) {
        for (int i = 0; i < HIDDEN; i++)
            block_out[i] = (s_res1[i] >> W4A8B_S_BLK_TRIM) + s_ffn_dn_out[i];
    } else {
        for (int i = 0; i < HIDDEN; i++)
            block_out[i] = (s_res1[i] << (-W4A8B_S_BLK_TRIM)) + s_ffn_dn_out[i];
    }

    return 0;
}
