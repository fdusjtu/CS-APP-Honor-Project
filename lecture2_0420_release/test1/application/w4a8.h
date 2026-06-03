#ifndef W4A8_H
#define W4A8_H

#include <stdint.h>

#define W4A8_BASE          0x10041000UL

#define W4A8_REG32(off)    (*(volatile uint32_t *)(W4A8_BASE + (off)))

#define W4A8_CTRL          W4A8_REG32(0x000)
#define W4A8_STATUS        W4A8_REG32(0x004)
#define W4A8_SHIFT         W4A8_REG32(0x008)
#define W4A8_LAYER_ID      W4A8_REG32(0x00c)
#define W4A8_W_LOAD_ADDR   W4A8_REG32(0x010)
#define W4A8_W_LOAD_DATA   W4A8_REG32(0x014)
#define W4A8_S_LOAD_ADDR   W4A8_REG32(0x018)
#define W4A8_S_LOAD_DATA   W4A8_REG32(0x01c)
#define W4A8_W_RD_ADDR     W4A8_REG32(0x030)
#define W4A8_W_RD_DATA     W4A8_REG32(0x034)
#define W4A8_CNT_TOTAL     W4A8_REG32(0x020)
#define W4A8_CNT_MAC       W4A8_REG32(0x024)
#define W4A8_CNT_STALL     W4A8_REG32(0x028)
#define W4A8_CNT_TILES     W4A8_REG32(0x02c)

#define W4A8_DESC_BASE     0x040
#define W4A8_ACT_BASE      0x100
#define W4A8_Y_BASE        0x200

#define W4A8_STATUS_DONE   (1u << 0)
#define W4A8_STATUS_BUSY   (1u << 1)
#define W4A8_CTRL_START    (1u << 0)

static inline void w4a8_write_desc(int layer_id, int m, int n, int w_base, int s_base)
{
    uintptr_t base = W4A8_BASE + W4A8_DESC_BASE + (uintptr_t)layer_id * 0x10u;

    (*(volatile uint32_t *)(base + 0x0u)) = (uint32_t)m;
    (*(volatile uint32_t *)(base + 0x4u)) = (uint32_t)n;
    (*(volatile uint32_t *)(base + 0x8u)) = (uint32_t)w_base;
    (*(volatile uint32_t *)(base + 0xcu)) = (uint32_t)s_base;
}

static inline void w4a8_load_weights(const uint32_t *words, int count)
{
    int i;

    W4A8_W_LOAD_ADDR = 0;
    for (i = 0; i < count; i++)
        W4A8_W_LOAD_DATA = words[i];
}

static inline void w4a8_load_scales(const uint32_t *words, int count)
{
    int i;

    W4A8_S_LOAD_ADDR = 0;
    for (i = 0; i < count; i++)
        W4A8_S_LOAD_DATA = words[i];
}

static inline void w4a8_write_act(const uint32_t *words, int count)
{
    int i;

    for (i = 0; i < count; i++)
        W4A8_REG32(W4A8_ACT_BASE + i * 4) = words[i];
}

static inline void w4a8_read_y(int32_t *y, int count)
{
    int i;

    for (i = 0; i < count; i++)
        y[i] = (int32_t)W4A8_REG32(W4A8_Y_BASE + i * 4);
}

static inline int w4a8_run_layer(int layer_id,
                                 const uint32_t *act_words,
                                 int act_word_count,
                                 int32_t *y,
                                 int y_count,
                                 uint32_t timeout)
{
    w4a8_write_act(act_words, act_word_count);
    W4A8_LAYER_ID = (uint32_t)layer_id;
    W4A8_CTRL = W4A8_CTRL_START;

    while ((W4A8_STATUS & W4A8_STATUS_DONE) == 0u) {
        if (timeout == 0u)
            return -1;
        timeout--;
    }

    w4a8_read_y(y, y_count);
    return 0;
}

/* Read a resident Linear layer's INT4-packed weights back from FPGA BRAM into
   a row-major packed buffer (2 signed nibbles per byte, byte b = cols 2b/2b+1),
   matching exactly what w4a8_cpu_gemv expects. w_base is in bank_addr units
   (the descriptor w_base). The banked word is "lsn first" so its 4 bytes drop
   straight into row-major positions cw*4..cw*4+3 with no bit shuffling.
   Must only be called while no Linear/block run is active (boot time). */
static inline void w4a8_read_layer_weights(int w_base, int m, int n, uint8_t *dst)
{
    int row, cw;
    int words_per_row = n >> 3;     /* N / 8 nibbles-per-word */
    int half_n        = n >> 1;     /* bytes per row in dst */

    for (row = 0; row < m; row++) {
        int row_tile = row >> 4;    /* row / 16 */
        int bank     = row & 15;    /* row % 16 */
        uint8_t *drow = dst + (uintptr_t)row * (uintptr_t)half_n;

        for (cw = 0; cw < words_per_row; cw++) {
            int bank_addr = w_base + row_tile * words_per_row + cw;
            uint32_t flat = ((uint32_t)bank_addr << 4) | (uint32_t)bank;
            uint32_t word;

            W4A8_W_RD_ADDR = flat;
            word = W4A8_W_RD_DATA;

            drow[cw * 4 + 0] = (uint8_t)(word >>  0);
            drow[cw * 4 + 1] = (uint8_t)(word >>  8);
            drow[cw * 4 + 2] = (uint8_t)(word >> 16);
            drow[cw * 4 + 3] = (uint8_t)(word >> 24);
        }
    }
}

/* ---- Step-4 Transformer Block Engine MMIO ---- */
#define W4A8_BLOCK_CTRL    W4A8_REG32(0x800)
#define W4A8_BLOCK_STATUS  W4A8_REG32(0x804)
#define W4A8_BLOCK_CNT     W4A8_REG32(0x808)
#define W4A8_BLOCK_STAGE   W4A8_REG32(0x80c)
#define W4A8_HIN_BASE      0x900   /* 128 INT8 packed, 32 words */
#define W4A8_BO_BASE       0xA00   /* 128 INT32 */

/* Run the full transformer block on the FPGA. Descriptors 0..3 (qkv/proj/
   ffn_up/ffn_down) must already be written. Writes hidden_in[128] INT8,
   starts the block, polls done, reads block_out[128] INT32. Returns the
   engine cycle count (start->done) in *cycles_out. */
static inline int w4a8_run_block_fpga(const int8_t *hidden_in,
                                      int32_t *block_out,
                                      uint32_t timeout,
                                      uint32_t *cycles_out)
{
    int i;

    for (i = 0; i < 32; i++) {
        uint32_t word =
              ((uint32_t)(uint8_t)hidden_in[i * 4 + 0])
            | ((uint32_t)(uint8_t)hidden_in[i * 4 + 1]) <<  8
            | ((uint32_t)(uint8_t)hidden_in[i * 4 + 2]) << 16
            | ((uint32_t)(uint8_t)hidden_in[i * 4 + 3]) << 24;
        W4A8_REG32(W4A8_HIN_BASE + i * 4) = word;
    }

    W4A8_BLOCK_CTRL = 1u;

    while ((W4A8_BLOCK_STATUS & 1u) == 0u) {
        if (timeout == 0u)
            return -1;
        timeout--;
    }

    for (i = 0; i < 128; i++)
        block_out[i] = (int32_t)W4A8_REG32(W4A8_BO_BASE + i * 4);

    if (cycles_out)
        *cycles_out = W4A8_BLOCK_CNT;
    return 0;
}

#endif
