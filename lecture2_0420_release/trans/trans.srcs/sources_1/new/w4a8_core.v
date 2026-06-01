`timescale 1ns/1ps
// Core FSM for w4a8_linear_engine.
//
// Given a Linear layer descriptor (M, N, w_base, s_base), drives:
//   - resident_wmem (16-bank packed INT4 weight, registered read)
//   - resident_smem (packed INT16x2 per-row scale, registered read)
//   - act_buf       (INT8x4 per word, registered read)
//   - y_buf         (INT32 output, single write port from core)
//
// Pipeline per col_word (8 activation columns):
//   COL_PREFETCH : issue wmem read; issue act_lo read.
//   MAC_PRE      : latch w_tile_words[16] and act_lo; issue act_hi read.
//   MAC_8        : 8 cycles, parallel 16-row INT4xINT8 MAC.
//                  Cycle 0 also latches act_hi (its read returned).
//
// Per row tile (16 rows):
//   ROW_INIT (1) -> LOAD_SCALE (9) -> [PREFETCH+PRE+MAC_8]*col_words
//                -> RESCALE (1) -> WRITE_Y (16)
//
// CNT_TILES increments once per 8 col_words (one logical 16x64 tile).
// CNT_MAC counts cycles spent in MAC_8 (8 per col_word).
// CNT_STALL = total busy cycles - mac cycles.

module w4a8_core (
    input              clk,
    input              rst_n,

    // control / config from icb
    input              start,
    input  [15:0]      cfg_m,
    input  [15:0]      cfg_n,
    input  [15:0]      cfg_w_base,
    input  [15:0]      cfg_s_base,
    input  [4:0]       cfg_shift,

    // status
    output             busy,
    output             done,

    // resident weight memory port
    output             wmem_read_en,
    output [11:0]      wmem_bank_addr,
    input  [16*32-1:0] wmem_rdata_flat,

    // resident scale memory port
    output             smem_read_en,
    output [9:0]       smem_addr,
    input  [31:0]      smem_rdata,

    // act_buf read port
    output             act_read_en,
    output [5:0]       act_addr,
    input  [31:0]      act_rdata,

    // y_buf write port
    output             ybuf_we,
    output [8:0]       ybuf_addr,
    output [31:0]      ybuf_wdata,

    // performance counters
    output [31:0]      cnt_total,
    output [31:0]      cnt_mac,
    output [31:0]      cnt_stall,
    output [31:0]      cnt_tiles
);

    // ---------------------------------------------------------------
    // State encoding
    // ---------------------------------------------------------------
    localparam [3:0]
        S_IDLE        = 4'd0,
        S_LOAD_DESC   = 4'd1,
        S_ROW_INIT    = 4'd2,
        S_LOAD_SCALE  = 4'd3,
        S_COL_PRE     = 4'd4,
        S_MAC_PRE     = 4'd5,
        S_MAC_8       = 4'd6,
        S_RESCALE     = 4'd7,
        S_WRITE_Y     = 4'd8,
        S_DONE        = 4'd9;

    reg [3:0] state_q, state_d;

    // ---------------------------------------------------------------
    // Latched layer config and derived bounds
    // ---------------------------------------------------------------
    reg [15:0] m_q, n_q;
    reg [11:0] w_base_q;
    reg [9:0]  s_base_q;
    reg [4:0]  shift_q;

    wire [4:0] row_tile_max = m_q[8:4] - 5'd1;          // M/16 - 1, M up to 384
    wire [4:0] col_word_max = n_q[8:3] - 5'd1;          // N/8 - 1, N up to 256

    // ---------------------------------------------------------------
    // Counters
    // ---------------------------------------------------------------
    reg [4:0]  row_tile_q;
    reg [4:0]  col_word_q;
    reg [3:0]  scnt_q;       // 0..8 for LOAD_SCALE
    reg [2:0]  sub_col_q;    // 0..7 for MAC_8
    reg [4:0]  wcnt_q;       // 0..15 for WRITE_Y

    // ---------------------------------------------------------------
    // Datapath registers
    // ---------------------------------------------------------------
    reg [31:0] w_tile_word [0:15];   // 16 rows x 32-bit packed INT4 (8 nibbles)
    reg [31:0] act_lo_q, act_hi_q;
    reg signed [15:0] scale_tile [0:15];
    reg signed [31:0] acc_q [0:15];
    reg signed [31:0] y_tile_q [0:15];

    // ---------------------------------------------------------------
    // Performance counters
    // ---------------------------------------------------------------
    reg [31:0] cnt_total_q, cnt_mac_q, cnt_stall_q, cnt_tiles_q;
    assign cnt_total = cnt_total_q;
    assign cnt_mac   = cnt_mac_q;
    assign cnt_stall = cnt_stall_q;
    assign cnt_tiles = cnt_tiles_q;

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    reg done_q;
    assign done = done_q;
    assign busy = (state_q != S_IDLE) && (state_q != S_DONE);

    // ---------------------------------------------------------------
    // Next-state logic
    // ---------------------------------------------------------------
    always @(*) begin
        state_d = state_q;
        case (state_q)
            S_IDLE       : if (start) state_d = S_LOAD_DESC;
            S_LOAD_DESC  : state_d = S_ROW_INIT;
            S_ROW_INIT   : state_d = S_LOAD_SCALE;
            S_LOAD_SCALE : if (scnt_q == 4'd8) state_d = S_COL_PRE;
            S_COL_PRE    : state_d = S_MAC_PRE;
            S_MAC_PRE    : state_d = S_MAC_8;
            S_MAC_8      : if (sub_col_q == 3'd7) begin
                              state_d = (col_word_q == col_word_max) ? S_RESCALE : S_COL_PRE;
                           end
            S_RESCALE    : state_d = S_WRITE_Y;
            S_WRITE_Y    : if (wcnt_q == 5'd15) begin
                              state_d = (row_tile_q == row_tile_max) ? S_DONE : S_ROW_INIT;
                           end
            S_DONE       : if (start) state_d = S_LOAD_DESC;
            default      : state_d = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------------
    // Combinational MAC sources for current sub_col
    // ---------------------------------------------------------------
    wire [31:0] act_word_cur  = (sub_col_q[2] == 1'b0) ? act_lo_q : act_hi_q;
    wire [1:0]  byte_sel_cur  = sub_col_q[1:0];
    wire signed [7:0] act_byte_cur = act_word_cur[byte_sel_cur*8 +: 8];

    wire signed [7:0] w_nibble [0:15];
    genvar gr;
    generate
        for (gr = 0; gr < 16; gr = gr + 1) begin : g_unpack
            int4_unpack u_unpack (
                .word  (w_tile_word[gr]),
                .index (sub_col_q),
                .value (w_nibble[gr])
            );
        end
    endgenerate

    // ---------------------------------------------------------------
    // Rescale (parallel)
    // ---------------------------------------------------------------
    wire signed [31:0] y_rescaled [0:15];
    generate
        for (gr = 0; gr < 16; gr = gr + 1) begin : g_rescale
            row_rescale u_rescale (
                .acc   (acc_q[gr]),
                .scale (scale_tile[gr]),
                .shift (shift_q),
                .y     (y_rescaled[gr])
            );
        end
    endgenerate

    // ---------------------------------------------------------------
    // Memory port outputs
    // ---------------------------------------------------------------
    // weight: read during S_COL_PRE, addr = w_base + row_tile*(N/8) + col_word
    wire [11:0] wmem_addr_calc = w_base_q
                                + {7'b0, row_tile_q} * {7'b0, n_q[8:3]}
                                + {7'b0, col_word_q};
    assign wmem_read_en   = (state_q == S_COL_PRE);
    assign wmem_bank_addr = wmem_addr_calc;

    // scale: read during S_LOAD_SCALE (8 issues for scnt 0..7)
    wire [9:0] smem_addr_calc = s_base_q
                                + {2'b0, row_tile_q, 3'b0}     // row_tile*8
                                + {6'b0, scnt_q};
    assign smem_read_en = (state_q == S_LOAD_SCALE) && (scnt_q < 4'd8);
    assign smem_addr    = smem_addr_calc;

    // act: read act_lo in S_COL_PRE (addr = col_word*2); act_hi in S_MAC_PRE (col_word*2 + 1)
    wire [5:0] act_addr_lo = {col_word_q, 1'b0};
    wire [5:0] act_addr_hi = {col_word_q, 1'b1};
    assign act_read_en = (state_q == S_COL_PRE) || (state_q == S_MAC_PRE);
    assign act_addr    = (state_q == S_COL_PRE) ? act_addr_lo : act_addr_hi;

    // y_buf write: 16 sequential words during S_WRITE_Y
    assign ybuf_we    = (state_q == S_WRITE_Y);
    assign ybuf_addr  = {row_tile_q, 4'b0} + {5'b0, wcnt_q[3:0]};  // row_tile*16 + wcnt
    reg [31:0] ybuf_wdata_mux;
    always @(*) begin
        case (wcnt_q[3:0])
            4'd0  : ybuf_wdata_mux = y_tile_q[0];
            4'd1  : ybuf_wdata_mux = y_tile_q[1];
            4'd2  : ybuf_wdata_mux = y_tile_q[2];
            4'd3  : ybuf_wdata_mux = y_tile_q[3];
            4'd4  : ybuf_wdata_mux = y_tile_q[4];
            4'd5  : ybuf_wdata_mux = y_tile_q[5];
            4'd6  : ybuf_wdata_mux = y_tile_q[6];
            4'd7  : ybuf_wdata_mux = y_tile_q[7];
            4'd8  : ybuf_wdata_mux = y_tile_q[8];
            4'd9  : ybuf_wdata_mux = y_tile_q[9];
            4'd10 : ybuf_wdata_mux = y_tile_q[10];
            4'd11 : ybuf_wdata_mux = y_tile_q[11];
            4'd12 : ybuf_wdata_mux = y_tile_q[12];
            4'd13 : ybuf_wdata_mux = y_tile_q[13];
            4'd14 : ybuf_wdata_mux = y_tile_q[14];
            4'd15 : ybuf_wdata_mux = y_tile_q[15];
        endcase
    end
    assign ybuf_wdata = ybuf_wdata_mux;

    // ---------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= S_IDLE;
            m_q         <= 16'b0;
            n_q         <= 16'b0;
            w_base_q    <= 12'b0;
            s_base_q    <= 10'b0;
            shift_q     <= 5'd14;
            row_tile_q  <= 5'b0;
            col_word_q  <= 5'b0;
            scnt_q      <= 4'b0;
            sub_col_q   <= 3'b0;
            wcnt_q      <= 5'b0;
            done_q      <= 1'b0;
            cnt_total_q <= 32'b0;
            cnt_mac_q   <= 32'b0;
            cnt_stall_q <= 32'b0;
            cnt_tiles_q <= 32'b0;
            act_lo_q    <= 32'b0;
            act_hi_q    <= 32'b0;
            for (i = 0; i < 16; i = i + 1) begin
                w_tile_word[i] <= 32'b0;
                scale_tile[i]  <= 16'b0;
                acc_q[i]       <= 32'b0;
                y_tile_q[i]    <= 32'b0;
            end
        end else begin
            state_q <= state_d;

            // ---- LOAD_DESC: latch descriptor, clear counters
            if (state_q == S_LOAD_DESC) begin
                m_q         <= cfg_m;
                n_q         <= cfg_n;
                w_base_q    <= cfg_w_base[11:0];
                s_base_q    <= cfg_s_base[9:0];
                shift_q     <= cfg_shift;
                row_tile_q  <= 5'b0;
                cnt_total_q <= 32'b0;
                cnt_mac_q   <= 32'b0;
                cnt_stall_q <= 32'b0;
                cnt_tiles_q <= 32'b0;
                done_q      <= 1'b0;
            end

            // ---- ROW_INIT: clear accumulators, reset col_word, scnt
            if (state_q == S_ROW_INIT) begin
                col_word_q <= 5'b0;
                scnt_q     <= 4'b0;
                for (i = 0; i < 16; i = i + 1)
                    acc_q[i] <= 32'b0;
            end

            // ---- LOAD_SCALE: issue read each cycle, latch previous rdata
            if (state_q == S_LOAD_SCALE) begin
                // scnt increments every cycle while < 8
                if (scnt_q < 4'd8)
                    scnt_q <= scnt_q + 4'd1;
                // when scnt_q is in 1..8, smem_rdata holds word issued at scnt_q-1
                if (scnt_q >= 4'd1 && scnt_q <= 4'd8) begin
                    scale_tile[(scnt_q-1)*2]     <= smem_rdata[15:0];
                    scale_tile[(scnt_q-1)*2 + 1] <= smem_rdata[31:16];
                end
            end

            // ---- MAC_PRE: latch w_tile_word[16] and act_lo
            if (state_q == S_MAC_PRE) begin
                for (i = 0; i < 16; i = i + 1)
                    w_tile_word[i] <= wmem_rdata_flat[i*32 +: 32];
                act_lo_q <= act_rdata;
                sub_col_q <= 3'b0;
            end

            // ---- MAC_8: on sub_col 0, latch act_hi; every cycle do 16 MACs
            if (state_q == S_MAC_8) begin
                if (sub_col_q == 3'd0)
                    act_hi_q <= act_rdata;
                for (i = 0; i < 16; i = i + 1) begin
                    // signed accumulation: 16-bit signed product extended to 32
                    acc_q[i] <= acc_q[i] +
                                $signed(w_nibble[i]) * $signed(act_byte_cur);
                end
                sub_col_q <= sub_col_q + 3'd1;
                cnt_mac_q <= cnt_mac_q + 32'd1;

                if (sub_col_q == 3'd7) begin
                    // finished one col_word
                    if (col_word_q != col_word_max)
                        col_word_q <= col_word_q + 5'd1;
                    // CNT_TILES: increment once per 8 col_words (one 16x64 tile)
                    if (col_word_q[2:0] == 3'd7)
                        cnt_tiles_q <= cnt_tiles_q + 32'd1;
                end
            end

            // ---- RESCALE: parallel rescale -> y_tile
            if (state_q == S_RESCALE) begin
                for (i = 0; i < 16; i = i + 1)
                    y_tile_q[i] <= y_rescaled[i];
                wcnt_q <= 5'b0;
            end

            // ---- WRITE_Y: 16 sequential writes; on last cycle bump row_tile
            if (state_q == S_WRITE_Y) begin
                if (wcnt_q < 5'd15)
                    wcnt_q <= wcnt_q + 5'd1;
                if (wcnt_q == 5'd15 && row_tile_q != row_tile_max) begin
                    row_tile_q <= row_tile_q + 5'd1;
                end
            end

            // ---- DONE flag
            if (state_q != S_DONE && state_d == S_DONE)
                done_q <= 1'b1;
            if (start)
                done_q <= 1'b0;

            // ---- Performance: total / stall
            // S_LOAD_DESC clears the counters above. Do not also increment in
            // that same cycle, otherwise the later nonblocking assignment wins.
            if (busy && state_q != S_LOAD_DESC) begin
                cnt_total_q <= cnt_total_q + 32'd1;
                if (state_q != S_MAC_8)
                    cnt_stall_q <= cnt_stall_q + 32'd1;
            end
        end
    end

endmodule
