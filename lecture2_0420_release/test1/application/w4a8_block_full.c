/* Step 3b: full transformer block on E203 + W4A8 Linear Engine. */
#include "w4a8_block_full.h"
#include "w4a8.h"
#include "w4a8_ops.h"
#include "w4a8_block_full_vectors.h"

#define HIDDEN   W4A8B_HIDDEN
#define FFN      W4A8B_FFN
#define HEAD_DIM W4A8B_HEAD_DIM

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

static int run_fpga(int layer_id,
                    const uint32_t *act_words, int act_word_count,
                    int32_t *y, int y_count)
{
    return w4a8_run_layer(layer_id, act_words, act_word_count, y, y_count,
                          W4A8_BLOCK_RUN_TIMEOUT);
}

/* Static scratch buffers in .bss (DTCM). */
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
static uint32_t s_act_words [FFN / 4];  /* enough for the FFN layer */

int w4a8_run_full_block(const int8_t *hidden_in, int32_t *block_out)
{
    /* -- Stage 1: LN1 over hidden_in (sign-extend INT8 -> INT32) -- */
    int32_t x_i32[HIDDEN];
    for (int i = 0; i < HIDDEN; i++)
        x_i32[i] = (int32_t)hidden_in[i];

    w4a8_int_layernorm(x_i32, HIDDEN, 7,
                       w4a8b_ln1_gamma, w4a8b_ln1_beta, s_ln1_out);
    for (int i = 0; i < HIDDEN; i++)
        s_ln1_q8[i] = w4a8_sat8(w4a8_round_shift(s_ln1_out[i], W4A8B_S_LN1_OUT));

    /* -- Stage 2: FPGA qkv -- */
    pack_i8(s_ln1_q8, HIDDEN, s_act_words);
    if (run_fpga(W4A8B_ID_QKV, s_act_words, HIDDEN / 4,
                 s_qkv_out, 3 * HIDDEN) != 0)
        return -1;

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

    /* attn_out[d] = sum_t probs[t] * V_seq[t][d]; then >> 15 then >> S_ATTN_OUT */
    for (int d = 0; d < HEAD_DIM; d++) {
        int32_t acc = 0;
        for (int t = 0; t < 2; t++)
            acc += (int32_t)s_probs_q15[t] * (int32_t)V_seq[t][d];
        int32_t back = w4a8_round_shift(acc, 15);
        s_attn_q8[d] = w4a8_sat8(w4a8_round_shift(back, W4A8B_S_ATTN_OUT));
    }

    /* -- Stage 4: FPGA proj -- */
    pack_i8(s_attn_q8, HIDDEN, s_act_words);
    if (run_fpga(W4A8B_ID_PROJ, s_act_words, HIDDEN / 4,
                 s_proj_out, HIDDEN) != 0)
        return -1;

    /* -- Stage 5: residual 1 -- */
    for (int i = 0; i < HIDDEN; i++)
        s_res1[i] = ((int32_t)hidden_in[i] << W4A8B_S_LIFT) + s_proj_out[i];

    /* -- Stage 6: LN2 over res1 -- */
    w4a8_int_layernorm(s_res1, HIDDEN, 7,
                       w4a8b_ln2_gamma, w4a8b_ln2_beta, s_ln2_out);
    for (int i = 0; i < HIDDEN; i++)
        s_ln2_q8[i] = w4a8_sat8(w4a8_round_shift(s_ln2_out[i], W4A8B_S_LN2_OUT));

    /* -- Stage 7: FPGA ffn_up -- */
    pack_i8(s_ln2_q8, HIDDEN, s_act_words);
    if (run_fpga(W4A8B_ID_FFN_UP, s_act_words, HIDDEN / 4,
                 s_ffn_up_out, FFN) != 0)
        return -1;

    /* -- Stage 8: GELU via LUT -- */
    for (int i = 0; i < FFN; i++)
        s_ffn_up_q8[i] = w4a8_sat8(w4a8_round_shift(s_ffn_up_out[i],
                                                    W4A8B_S_FFN_UP_OUT));
    for (int i = 0; i < FFN; i++)
        s_gelu_out[i] = w4a8_int_gelu_lut(w4a8b_gelu_lut, s_ffn_up_q8[i]);

    /* -- Stage 9: FPGA ffn_down -- */
    pack_i8(s_gelu_out, FFN, s_act_words);
    if (run_fpga(W4A8B_ID_FFN_DOWN, s_act_words, FFN / 4,
                 s_ffn_dn_out, HIDDEN) != 0)
        return -1;

    /* -- Stage 10: residual 2 -> block_out -- */
    /* Python: (res1 >> S_BLK_TRIM if S>=0 else res1 << -S) + ffn_dn_out
       We use round_shift to keep both branches in one form; for S>=0 this is
       just an arithmetic right shift with rounding (matches Python expr because
       Python uses raw >> when S_BLK_TRIM>=0). With the current header,
       S_BLK_TRIM=0, so this is just res1 + ffn_dn_out either way.            */
    if (W4A8B_S_BLK_TRIM >= 0) {
        for (int i = 0; i < HIDDEN; i++)
            block_out[i] = (s_res1[i] >> W4A8B_S_BLK_TRIM) + s_ffn_dn_out[i];
    } else {
        for (int i = 0; i < HIDDEN; i++)
            block_out[i] = (s_res1[i] << (-W4A8B_S_BLK_TRIM)) + s_ffn_dn_out[i];
    }

    return 0;
}
