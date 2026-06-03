`timescale 1ns/1ps
// ICB slave + MMIO register file for w4a8_block_engine.
//
// Superset of the original w4a8_linear_engine register file: all legacy
// per-layer Linear MMIO (0x000..0x7FC) is preserved unchanged, plus the
// Step-4 block-engine interface.
//
// Legacy map (unchanged):
//   0x000 CTRL  0x004 STATUS  0x008 SHIFT  0x00C LAYER_ID
//   0x010 W_LOAD_ADDR 0x014 W_LOAD_DATA 0x018 S_LOAD_ADDR 0x01C S_LOAD_DATA
//   0x020 CNT_TOTAL 0x024 CNT_MAC 0x028 CNT_STALL 0x02C CNT_TILES
//   0x040..0x0CC DESC0..8   0x100..0x1FC ACT_BUF   0x200..0x7FC Y_BUF
//
// New block map:
//   0x800 BLOCK_CTRL   W  bit0=start
//   0x804 BLOCK_STATUS R  bit0=done, bit1=busy
//   0x808 BLOCK_CNT    R  total cycles start->done
//   0x80C BLOCK_STAGE  R  current/last stage id (debug)
//   0x900..0x97C HIDDEN_IN W  128 INT8 packed (32 words)
//   0xA00..0xBFC BLOCK_OUT R  128 INT32 (128 words)

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

    // to core (legacy CPU Linear path)
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

    // resident weight / scale load ports
    output             wmem_load_we,
    output [15:0]      wmem_load_flat_addr,
    output [31:0]      wmem_load_wdata,
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
    input  [31:0]      ybuf_wdata,

    // CPU weight readback (boot-time): drive the shared wmem read port and
    // return one bank-selected 32-bit word per W_RD_DATA read.
    input  [16*32-1:0] wmem_rdata_flat,
    output             wrd_read_en,
    output [11:0]      wrd_bank_addr,

    // ---- Step-4 block-engine interface ----
    output             block_start,
    input              block_busy,
    input              block_done,
    input  [31:0]      block_cnt,
    input  [7:0]       block_stage,

    // descriptor read for block_ctrl
    input  [3:0]       block_desc_id,
    output [15:0]      block_desc_m,
    output [15:0]      block_desc_n,
    output [15:0]      block_desc_wbase,
    output [15:0]      block_desc_sbase,

    // hidden_in word read for block_ctrl
    input  [4:0]       hin_word_addr,
    output [31:0]      hin_word_rdata,

    // block_out write from block_ctrl
    input              bo_we,
    input  [6:0]       bo_addr,
    input  [31:0]      bo_wdata,

    // ACT_BUF write from block_ctrl (feeds core during block)
    input              block_act_we,
    input  [5:0]       block_act_addr,
    input  [31:0]      block_act_wdata,

    // Y_BUF read for block_ctrl
    input  [8:0]       block_y_addr,
    output [31:0]      block_y_rdata
);

    // ---------------------------------------------------------------
    localparam REG_CTRL        = 12'h000;
    localparam REG_STATUS      = 12'h004;
    localparam REG_SHIFT       = 12'h008;
    localparam REG_LAYER_ID    = 12'h00C;
    localparam REG_W_LOAD_ADDR = 12'h010;
    localparam REG_W_LOAD_DATA = 12'h014;
    localparam REG_S_LOAD_ADDR = 12'h018;
    localparam REG_S_LOAD_DATA = 12'h01C;
    localparam REG_W_RD_ADDR   = 12'h030;   // CPU weight readback: set flat addr
    localparam REG_W_RD_DATA   = 12'h034;   // CPU weight readback: read+auto-inc
    localparam REG_CNT_TOTAL   = 12'h020;
    localparam REG_CNT_MAC     = 12'h024;
    localparam REG_CNT_STALL   = 12'h028;
    localparam REG_CNT_TILES   = 12'h02C;
    localparam REG_DESC_BASE   = 12'h040;
    localparam REG_DESC_END    = 12'h0D0;
    localparam REG_ACT_BASE    = 12'h100;
    localparam REG_ACT_END     = 12'h200;
    localparam REG_Y_BASE      = 12'h200;
    localparam REG_Y_END       = 12'h800;
    localparam REG_BLOCK_CTRL  = 12'h800;
    localparam REG_BLOCK_STATUS= 12'h804;
    localparam REG_BLOCK_CNT   = 12'h808;
    localparam REG_BLOCK_STAGE = 12'h80C;
    localparam REG_HIN_BASE    = 12'h900;
    localparam REG_HIN_END     = 12'h980;   // 32 words
    localparam REG_BO_BASE     = 12'hA00;
    localparam REG_BO_END      = 12'hC00;    // 128 words

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
    reg [4:0]  shift_q;
    reg [3:0]  layer_id_q;
    reg [15:0] w_load_addr_q;
    reg [9:0]  s_load_addr_q;
    reg        start_pulse_q;
    reg        block_start_q;
    reg [15:0] wrd_flat_q;     // CPU weight readback flat pointer
    reg [31:0] wrd_data_q;     // bank-selected word, registered

    reg [31:0] desc_table [0:35];
    reg [31:0] act_buf [0:63];
    reg [31:0] y_buf [0:383];
    reg [31:0] hidden_in [0:31];
    reg [31:0] block_out [0:127];

    assign start_pulse = start_pulse_q;
    assign block_start = block_start_q;
    assign cfg_shift   = shift_q;

    // legacy CPU descriptor mux
    wire [5:0] desc_index = {layer_id_q[3:0], 2'b00};
    assign cfg_m      = desc_table[desc_index + 6'd0][15:0];
    assign cfg_n      = desc_table[desc_index + 6'd1][15:0];
    assign cfg_w_base = desc_table[desc_index + 6'd2][15:0];
    assign cfg_s_base = desc_table[desc_index + 6'd3][15:0];

    // block descriptor mux
    wire [5:0] bdesc_index = {block_desc_id[3:0], 2'b00};
    assign block_desc_m     = desc_table[bdesc_index + 6'd0][15:0];
    assign block_desc_n     = desc_table[bdesc_index + 6'd1][15:0];
    assign block_desc_wbase = desc_table[bdesc_index + 6'd2][15:0];
    assign block_desc_sbase = desc_table[bdesc_index + 6'd3][15:0];

    // ACT_BUF read port: registered (1-cycle) for core pipeline
    reg [31:0] act_rdata_q;
    always @(posedge clk)
        act_rdata_q <= act_buf[act_addr];
    assign act_rdata = act_rdata_q;

    // block read ports (combinational)
    assign hin_word_rdata = hidden_in[hin_word_addr];
    assign block_y_rdata  = y_buf[block_y_addr];

    // CPU weight readback: continuously present the current pointer's bank_addr
    // to the (idle-arbitrated) wmem read port. The top level only routes this
    // when no run is active, so this is harmless during normal operation.
    assign wrd_read_en   = 1'b1;
    assign wrd_bank_addr = wrd_flat_q[15:4];     // bank_addr = flat >> 4

    // weight/scale load ports
    assign wmem_load_we         = cmd_write & (cmd_addr12 == REG_W_LOAD_DATA);
    assign wmem_load_flat_addr  = w_load_addr_q;
    assign wmem_load_wdata      = icb_cmd_wdata;
    assign smem_load_we         = cmd_write & (cmd_addr12 == REG_S_LOAD_DATA);
    assign smem_load_addr       = s_load_addr_q;
    assign smem_load_wdata      = icb_cmd_wdata;

    // ---------------------------------------------------------------
    wire cmd_in_desc = (cmd_addr12 >= REG_DESC_BASE) && (cmd_addr12 < REG_DESC_END);
    wire cmd_in_act  = (cmd_addr12 >= REG_ACT_BASE)  && (cmd_addr12 < REG_ACT_END);
    wire cmd_in_hin  = (cmd_addr12 >= REG_HIN_BASE)  && (cmd_addr12 < REG_HIN_END);
    wire rsp_in_desc = (rsp_addr_r >= REG_DESC_BASE) && (rsp_addr_r < REG_DESC_END);
    wire rsp_in_y    = (rsp_addr_r >= REG_Y_BASE)    && (rsp_addr_r < REG_Y_END);
    wire rsp_in_bo   = (rsp_addr_r >= REG_BO_BASE)   && (rsp_addr_r < REG_BO_END);

    wire [5:0] cmd_desc_index = cmd_addr12[7:2] - 6'h10;
    wire [5:0] rsp_desc_index = rsp_addr_r[7:2] - 6'h10;
    wire [6:0] cmd_act_idx7  = cmd_addr12[8:2] - 7'h40;
    wire [8:0] rsp_y_idx9    = rsp_addr_r[10:2] - 9'h80;
    wire [4:0] cmd_hin_idx   = cmd_addr12[6:2] - 5'h00;   // 0x900>>2 low 5 bits
    wire [6:0] rsp_bo_idx    = rsp_addr_r[8:2];           // 0xA00>>2 low 7 bits

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
            REG_S_LOAD_ADDR : rd_data = {22'b0, s_load_addr_q};
            REG_W_RD_ADDR   : rd_data = {16'b0, wrd_flat_q};
            REG_W_RD_DATA   : rd_data = wrd_data_q;
            REG_CNT_TOTAL   : rd_data = core_cnt_total;
            REG_CNT_MAC     : rd_data = core_cnt_mac;
            REG_CNT_STALL   : rd_data = core_cnt_stall;
            REG_CNT_TILES   : rd_data = core_cnt_tiles;
            REG_BLOCK_STATUS: rd_data = {30'b0, block_busy, block_done};
            REG_BLOCK_CNT   : rd_data = block_cnt;
            REG_BLOCK_STAGE : rd_data = {24'b0, block_stage};
            default         : begin
                if (rsp_in_desc)     rd_data = desc_table[rsp_desc_index];
                else if (rsp_in_y)   rd_data = y_buf[rsp_y_idx9];
                else if (rsp_in_bo)  rd_data = block_out[rsp_bo_idx];
                else                 rd_data = 32'b0;
            end
        endcase
    end

    assign icb_rsp_rdata = rsp_read_r ? rd_data : 32'b0;

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
            block_start_q <= 1'b0;
            wrd_flat_q    <= 16'b0;
            wrd_data_q    <= 32'b0;
            for (i = 0; i < 36; i = i + 1)
                desc_table[i] <= 32'b0;
        end else begin
            start_pulse_q <= 1'b0;
            block_start_q <= 1'b0;

            // CPU weight readback: latch the bank-selected word every cycle.
            // wmem read latency is 1 cycle and CPU MMIO accesses are tens of
            // cycles apart, so wrd_data_q is always settled before a read.
            wrd_data_q <= wmem_rdata_flat[wrd_flat_q[3:0]*32 +: 32];

            if (icb_rsp_valid & icb_rsp_ready)
                rsp_pending <= 1'b0;

            // core writes Y_BUF
            if (ybuf_we)
                y_buf[ybuf_addr] <= ybuf_wdata;

            // block_ctrl writes ACT_BUF (priority) and BLOCK_OUT
            if (block_act_we)
                act_buf[block_act_addr] <= block_act_wdata;
            if (bo_we)
                block_out[bo_addr] <= bo_wdata;

            if (cmd_fire) begin
                rsp_pending <= 1'b1;
                rsp_read_r  <= icb_cmd_read;
                rsp_addr_r  <= cmd_addr12;

                // Reading W_RD_DATA returns wrd_data_q (already settled) and
                // advances the pointer so the next read fetches the next word.
                if (icb_cmd_read && cmd_addr12 == REG_W_RD_DATA)
                    wrd_flat_q <= wrd_flat_q + 16'd1;

                if (!icb_cmd_read) begin
                    case (cmd_addr12)
                        REG_CTRL : begin
                            if (icb_cmd_wdata[0] & ~core_busy)
                                start_pulse_q <= 1'b1;
                        end
                        REG_SHIFT : if (icb_cmd_wmask[0]) shift_q <= icb_cmd_wdata[4:0];
                        REG_LAYER_ID : if (icb_cmd_wmask[0]) layer_id_q <= icb_cmd_wdata[3:0];
                        REG_W_LOAD_ADDR : w_load_addr_q <= icb_cmd_wdata[15:0];
                        REG_W_LOAD_DATA : w_load_addr_q <= w_load_addr_q + 16'd1;
                        REG_S_LOAD_ADDR : s_load_addr_q <= icb_cmd_wdata[9:0];
                        REG_S_LOAD_DATA : s_load_addr_q <= s_load_addr_q + 10'd1;
                        REG_W_RD_ADDR   : wrd_flat_q <= icb_cmd_wdata[15:0];
                        REG_BLOCK_CTRL  : begin
                            if (icb_cmd_wdata[0] & ~block_busy & ~core_busy)
                                block_start_q <= 1'b1;
                        end
                        default : begin
                            if (cmd_in_desc) begin
                                if (icb_cmd_wmask[0]) desc_table[cmd_desc_index][ 7: 0] <= icb_cmd_wdata[ 7: 0];
                                if (icb_cmd_wmask[1]) desc_table[cmd_desc_index][15: 8] <= icb_cmd_wdata[15: 8];
                                if (icb_cmd_wmask[2]) desc_table[cmd_desc_index][23:16] <= icb_cmd_wdata[23:16];
                                if (icb_cmd_wmask[3]) desc_table[cmd_desc_index][31:24] <= icb_cmd_wdata[31:24];
                            end else if (cmd_in_act && !block_busy) begin
                                if (icb_cmd_wmask[0]) act_buf[cmd_act_idx7[5:0]][ 7: 0] <= icb_cmd_wdata[ 7: 0];
                                if (icb_cmd_wmask[1]) act_buf[cmd_act_idx7[5:0]][15: 8] <= icb_cmd_wdata[15: 8];
                                if (icb_cmd_wmask[2]) act_buf[cmd_act_idx7[5:0]][23:16] <= icb_cmd_wdata[23:16];
                                if (icb_cmd_wmask[3]) act_buf[cmd_act_idx7[5:0]][31:24] <= icb_cmd_wdata[31:24];
                            end else if (cmd_in_hin) begin
                                if (icb_cmd_wmask[0]) hidden_in[cmd_hin_idx][ 7: 0] <= icb_cmd_wdata[ 7: 0];
                                if (icb_cmd_wmask[1]) hidden_in[cmd_hin_idx][15: 8] <= icb_cmd_wdata[15: 8];
                                if (icb_cmd_wmask[2]) hidden_in[cmd_hin_idx][23:16] <= icb_cmd_wdata[23:16];
                                if (icb_cmd_wmask[3]) hidden_in[cmd_hin_idx][31:24] <= icb_cmd_wdata[31:24];
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule
