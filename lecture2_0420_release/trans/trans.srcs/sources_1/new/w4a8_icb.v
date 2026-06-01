`timescale 1ns/1ps
// ICB slave + MMIO register file + descriptor table + ACT/Y buffers
// for w4a8_linear_engine. Base address 0x1004_1000 is decoded externally;
// this module sees only addr[11:0].
//
// Register map (see project_goal.md for full description):
//   0x000 CTRL          W   bit[0]=start (auto pulse)
//   0x004 STATUS        R   bit[0]=done, bit[1]=busy
//   0x008 SHIFT         RW  rescale shift (default 14)
//   0x00C LAYER_ID      RW  0..8
//   0x010 W_LOAD_ADDR   W   flat resident weight load index
//   0x014 W_LOAD_DATA   W   write word, addr auto-increments
//   0x018 S_LOAD_ADDR   W   resident scale load word index
//   0x01C S_LOAD_DATA   W   write word, addr auto-increments
//   0x020 CNT_TOTAL     R
//   0x024 CNT_MAC       R
//   0x028 CNT_STALL     R
//   0x02C CNT_TILES     R
//   0x040..0x0CC        RW  DESC0..8 (M, N, W_BASE, S_BASE per layer, 4 words each)
//   0x100..0x1FC        W   ACT_BUF (64 words, INT8x4 per word)
//   0x200..0x7FC        R   Y_BUF   (384 words, INT32 per word)

module w4a8_icb (
    input              clk,
    input              rst_n,

    // ICB slave
    input              icb_cmd_valid,
    output             icb_cmd_ready,
    input  [31:0]      icb_cmd_addr,
    input              icb_cmd_read,
    input  [31:0]      icb_cmd_wdata,
    input  [3:0]       icb_cmd_wmask,
    output             icb_rsp_valid,
    input              icb_rsp_ready,
    output [31:0]      icb_rsp_rdata,
    output             icb_rsp_err,

    // to core
    output             start_pulse,
    output [15:0]      cfg_m,
    output [15:0]      cfg_n,
    output [15:0]      cfg_w_base,
    output [15:0]      cfg_s_base,
    output [4:0]       cfg_shift,
    input              core_busy,
    input              core_done,
    input  [31:0]      core_cnt_total,
    input  [31:0]      core_cnt_mac,
    input  [31:0]      core_cnt_stall,
    input  [31:0]      core_cnt_tiles,

    // resident weight memory load port
    output             wmem_load_we,
    output [15:0]      wmem_load_flat_addr,
    output [31:0]      wmem_load_wdata,

    // resident scale memory load port
    output             smem_load_we,
    output [9:0]       smem_load_addr,
    output [31:0]      smem_load_wdata,

    // core's ACT_BUF read port
    input              act_read_en,
    input  [5:0]       act_addr,
    output [31:0]      act_rdata,

    // core's Y_BUF write port
    input              ybuf_we,
    input  [8:0]       ybuf_addr,
    input  [31:0]      ybuf_wdata
);

    // ---------------------------------------------------------------
    // Address constants
    // ---------------------------------------------------------------
    localparam REG_CTRL        = 12'h000;
    localparam REG_STATUS      = 12'h004;
    localparam REG_SHIFT       = 12'h008;
    localparam REG_LAYER_ID    = 12'h00C;
    localparam REG_W_LOAD_ADDR = 12'h010;
    localparam REG_W_LOAD_DATA = 12'h014;
    localparam REG_S_LOAD_ADDR = 12'h018;
    localparam REG_S_LOAD_DATA = 12'h01C;
    localparam REG_CNT_TOTAL   = 12'h020;
    localparam REG_CNT_MAC     = 12'h024;
    localparam REG_CNT_STALL   = 12'h028;
    localparam REG_CNT_TILES   = 12'h02C;
    localparam REG_DESC_BASE   = 12'h040;  // 9 layers * 4 words = 0x40..0xCF
    localparam REG_DESC_END    = 12'h0D0;
    localparam REG_ACT_BASE    = 12'h100;
    localparam REG_ACT_END     = 12'h200;  // 64 words
    localparam REG_Y_BASE      = 12'h200;
    localparam REG_Y_END       = 12'h800;  // 384 words

    // ---------------------------------------------------------------
    // ICB cmd/rsp pipeline (mirrors gemv_accel pattern)
    // ---------------------------------------------------------------
    reg        rsp_pending;
    reg        rsp_read_r;
    reg [11:0] rsp_addr_r;

    assign icb_cmd_ready = ~rsp_pending;
    assign icb_rsp_valid = rsp_pending;
    assign icb_rsp_err   = 1'b0;

    wire cmd_fire   = icb_cmd_valid & icb_cmd_ready;
    wire [11:0] cmd_addr12 = icb_cmd_addr[11:0];
    wire cmd_write  = cmd_fire & ~icb_cmd_read;

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------
    reg [4:0]  shift_q;
    reg [3:0]  layer_id_q;
    reg [15:0] w_load_addr_q;
    reg [9:0]  s_load_addr_q;
    reg        start_pulse_q;

    // descriptor table: 9 layers * 4 fields = 36 words (only [0]..[35] used)
    reg [31:0] desc_table [0:35];

    // ACT_BUF: 64 x 32-bit (write-only from CPU; read by core)
    reg [31:0] act_buf [0:63];

    // Y_BUF: 384 x 32-bit (write from core; read-only from CPU)
    reg [31:0] y_buf [0:383];

    assign start_pulse = start_pulse_q;
    assign cfg_shift   = shift_q;

    // descriptor outputs (mux on layer_id)
    wire [5:0] desc_index = {layer_id_q[3:0], 2'b00};  // layer*4
    assign cfg_m      = desc_table[desc_index + 6'd0][15:0];
    assign cfg_n      = desc_table[desc_index + 6'd1][15:0];
    assign cfg_w_base = desc_table[desc_index + 6'd2][15:0];
    assign cfg_s_base = desc_table[desc_index + 6'd3][15:0];

    // ACT_BUF read port: registered (1-cycle latency) so it matches the
    // wmem/smem BRAM-read convention assumed by w4a8_core's pipeline.
    reg [31:0] act_rdata_q;
    always @(posedge clk)
        act_rdata_q <= act_buf[act_addr];
    assign act_rdata = act_rdata_q;

    // weight/scale load ports: combinational pulse on matching cmd_write
    assign wmem_load_we         = cmd_write & (cmd_addr12 == REG_W_LOAD_DATA);
    assign wmem_load_flat_addr  = w_load_addr_q;
    assign wmem_load_wdata      = icb_cmd_wdata;

    assign smem_load_we         = cmd_write & (cmd_addr12 == REG_S_LOAD_DATA);
    assign smem_load_addr       = s_load_addr_q;
    assign smem_load_wdata      = icb_cmd_wdata;

    // ---------------------------------------------------------------
    // Address-range decode (for use in always block)
    // ---------------------------------------------------------------
    wire cmd_in_desc = (cmd_addr12 >= REG_DESC_BASE) && (cmd_addr12 < REG_DESC_END);
    wire cmd_in_act  = (cmd_addr12 >= REG_ACT_BASE)  && (cmd_addr12 < REG_ACT_END);
    wire rsp_in_desc = (rsp_addr_r >= REG_DESC_BASE) && (rsp_addr_r < REG_DESC_END);
    wire rsp_in_y    = (rsp_addr_r >= REG_Y_BASE)    && (rsp_addr_r < REG_Y_END);

    wire [5:0] cmd_desc_index = cmd_addr12[7:2] - 6'h10;  // (addr - 0x40) >> 2
    wire [5:0] rsp_desc_index = rsp_addr_r[7:2] - 6'h10;
    wire [5:0] cmd_act_index  = cmd_addr12[7:2];          // (addr - 0x100) >> 2 = addr[7:2]-0x40 ; but addr[11:2]-0x40 == addr[7:2] when addr in 0x100..0x1FC
    // Wait: 0x100>>2 = 0x40. 0x1FC>>2 = 0x7F. So index = addr[8:2] - 7'h40.
    // Use full 7-bit subtraction to be safe.

    wire [6:0] cmd_act_idx7  = cmd_addr12[8:2] - 7'h40;   // 0..63
    wire [8:0] rsp_y_idx9    = rsp_addr_r[10:2] - 9'h80;  // 0..383

    // ---------------------------------------------------------------
    // Read-data mux
    // ---------------------------------------------------------------
    reg [31:0] rd_data;
    always @(*) begin
        rd_data = 32'b0;
        case (rsp_addr_r)
            REG_CTRL        : rd_data = 32'b0;
            REG_STATUS      : rd_data = {30'b0, core_busy, core_done};
            REG_SHIFT       : rd_data = {27'b0, shift_q};
            REG_LAYER_ID    : rd_data = {28'b0, layer_id_q};
            REG_W_LOAD_ADDR : rd_data = {16'b0, w_load_addr_q};
            REG_W_LOAD_DATA : rd_data = 32'b0;
            REG_S_LOAD_ADDR : rd_data = {22'b0, s_load_addr_q};
            REG_S_LOAD_DATA : rd_data = 32'b0;
            REG_CNT_TOTAL   : rd_data = core_cnt_total;
            REG_CNT_MAC     : rd_data = core_cnt_mac;
            REG_CNT_STALL   : rd_data = core_cnt_stall;
            REG_CNT_TILES   : rd_data = core_cnt_tiles;
            default         : begin
                if (rsp_in_desc)
                    rd_data = desc_table[rsp_desc_index];
                else if (rsp_in_y)
                    rd_data = y_buf[rsp_y_idx9];
                else
                    rd_data = 32'b0;
            end
        endcase
    end

    assign icb_rsp_rdata = rsp_read_r ? rd_data : 32'b0;

    // ---------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_pending   <= 1'b0;
            rsp_read_r    <= 1'b0;
            rsp_addr_r    <= 12'b0;
            shift_q       <= 5'd14;
            layer_id_q    <= 4'b0;
            w_load_addr_q <= 16'b0;
            s_load_addr_q <= 10'b0;
            start_pulse_q <= 1'b0;
            for (i = 0; i < 36; i = i + 1)
                desc_table[i] <= 32'b0;
            // act_buf / y_buf intentionally uninitialized to allow BRAM inference;
            // CPU must populate ACT_BUF before each layer.
        end else begin
            // default: start pulse is one cycle
            start_pulse_q <= 1'b0;

            // ---- rsp lifecycle
            if (icb_rsp_valid & icb_rsp_ready)
                rsp_pending <= 1'b0;

            // ---- core writes to Y_BUF (separate write port; runs even when icb is idle)
            if (ybuf_we)
                y_buf[ybuf_addr] <= ybuf_wdata;

            // ---- cmd handling
            if (cmd_fire) begin
                rsp_pending <= 1'b1;
                rsp_read_r  <= icb_cmd_read;
                rsp_addr_r  <= cmd_addr12;

                if (!icb_cmd_read) begin
                    case (cmd_addr12)
                        REG_CTRL : begin
                            if (icb_cmd_wdata[0] & ~core_busy)
                                start_pulse_q <= 1'b1;
                        end
                        REG_SHIFT : begin
                            if (icb_cmd_wmask[0])
                                shift_q <= icb_cmd_wdata[4:0];
                        end
                        REG_LAYER_ID : begin
                            if (icb_cmd_wmask[0])
                                layer_id_q <= icb_cmd_wdata[3:0];
                        end
                        REG_W_LOAD_ADDR : begin
                            w_load_addr_q <= icb_cmd_wdata[15:0];
                        end
                        REG_W_LOAD_DATA : begin
                            // wmem_load_we asserted combinationally; auto-incr addr
                            w_load_addr_q <= w_load_addr_q + 16'd1;
                        end
                        REG_S_LOAD_ADDR : begin
                            s_load_addr_q <= icb_cmd_wdata[9:0];
                        end
                        REG_S_LOAD_DATA : begin
                            s_load_addr_q <= s_load_addr_q + 10'd1;
                        end
                        default : begin
                            if (cmd_in_desc) begin
                                if (icb_cmd_wmask[0]) desc_table[cmd_desc_index][ 7: 0] <= icb_cmd_wdata[ 7: 0];
                                if (icb_cmd_wmask[1]) desc_table[cmd_desc_index][15: 8] <= icb_cmd_wdata[15: 8];
                                if (icb_cmd_wmask[2]) desc_table[cmd_desc_index][23:16] <= icb_cmd_wdata[23:16];
                                if (icb_cmd_wmask[3]) desc_table[cmd_desc_index][31:24] <= icb_cmd_wdata[31:24];
                            end else if (cmd_in_act) begin
                                if (icb_cmd_wmask[0]) act_buf[cmd_act_idx7[5:0]][ 7: 0] <= icb_cmd_wdata[ 7: 0];
                                if (icb_cmd_wmask[1]) act_buf[cmd_act_idx7[5:0]][15: 8] <= icb_cmd_wdata[15: 8];
                                if (icb_cmd_wmask[2]) act_buf[cmd_act_idx7[5:0]][23:16] <= icb_cmd_wdata[23:16];
                                if (icb_cmd_wmask[3]) act_buf[cmd_act_idx7[5:0]][31:24] <= icb_cmd_wdata[31:24];
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule
