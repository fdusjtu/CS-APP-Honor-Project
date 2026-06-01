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

#endif
