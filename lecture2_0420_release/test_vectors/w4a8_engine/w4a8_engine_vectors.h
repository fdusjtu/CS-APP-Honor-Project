#ifndef W4A8_ENGINE_VECTORS_H
#define W4A8_ENGINE_VECTORS_H

#include <stdint.h>

#define W4A8E_N_LAYERS 9
#define W4A8E_WMEM_BANK_DEPTH 4096
#define W4A8E_W_WORDS 33792
#define W4A8E_S_WORDS 928
#define W4A8E_SHIFT 14

typedef struct { int m, n, w_base, s_base; } w4a8_layer_desc_t;

static const w4a8_layer_desc_t w4a8_descs[W4A8E_N_LAYERS] = {
    { .m = 384, .n = 128, .w_base = 0, .s_base = 0 },  /* id 0: layer0_qkv */
    { .m = 128, .n = 128, .w_base = 384, .s_base = 192 },  /* id 1: layer0_proj */
    { .m = 256, .n = 128, .w_base = 512, .s_base = 256 },  /* id 2: layer0_ffn_up */
    { .m = 128, .n = 256, .w_base = 768, .s_base = 384 },  /* id 3: layer0_ffn_down */
    { .m = 384, .n = 128, .w_base = 1024, .s_base = 448 },  /* id 4: layer1_qkv */
    { .m = 128, .n = 128, .w_base = 1408, .s_base = 640 },  /* id 5: layer1_proj */
    { .m = 256, .n = 128, .w_base = 1536, .s_base = 704 },  /* id 6: layer1_ffn_up */
    { .m = 128, .n = 256, .w_base = 1792, .s_base = 832 },  /* id 7: layer1_ffn_down */
    { .m = 64, .n = 128, .w_base = 2048, .s_base = 896 },  /* id 8: lm_head */
};

#endif
