`timescale 1ns/1ps
// Top-level W4A8 Transformer Block Engine.
//
// Drop-in replacement for w4a8_linear_engine at the SoC level (same ICB
// pinout, same base 0x1004_1000). Superset: the legacy per-layer Linear MMIO
// still works; new BLOCK_* registers run a whole transformer block in FPGA.
//
// The reused w4a8_core's start/descriptor inputs are muxed between the CPU
// Linear path (icb) and the block controller; act_buf/y_buf live in icb and
// are shared (block_ctrl owns them while a block runs).

module w4a8_block_engine (
    input              clk,
    input              rst_n,

    input              icb_cmd_valid,
    output             icb_cmd_ready,
    input  [31:0]      icb_cmd_addr,
    input              icb_cmd_read,
    input  [31:0]      icb_cmd_wdata,
    input  [3:0]       icb_cmd_wmask,
    output             icb_rsp_valid,
    input              icb_rsp_ready,
    output [31:0]      icb_rsp_rdata,
    output             icb_rsp_err
);
    // icb <-> core (CPU Linear path)
    wire             cpu_start;
    wire [15:0]      cpu_m, cpu_n, cpu_wbase, cpu_sbase;
    wire [4:0]       cpu_shift;
    wire             core_busy, core_done;
    wire [31:0]      cnt_total, cnt_mac, cnt_stall, cnt_tiles;

    wire             wmem_load_we;
    wire [15:0]      wmem_load_flat_addr;
    wire [31:0]      wmem_load_wdata;
    wire             smem_load_we;
    wire [9:0]       smem_load_addr;
    wire [31:0]      smem_load_wdata;

    wire             act_read_en;
    wire [5:0]       act_addr;
    wire [31:0]      act_rdata;
    wire             ybuf_we;
    wire [8:0]       ybuf_addr;
    wire [31:0]      ybuf_wdata;

    wire             wmem_read_en;
    wire [11:0]      wmem_bank_addr;
    wire [16*32-1:0] wmem_rdata_flat;
    wire             smem_read_en;
    wire [9:0]       smem_addr;
    wire [31:0]      smem_rdata;

    // block_ctrl <-> icb
    wire             block_start, block_busy, block_done;
    wire [31:0]      block_cnt;
    wire [7:0]       block_stage;
    wire [3:0]       bdesc_id;
    wire [15:0]      bdesc_m, bdesc_n, bdesc_wbase, bdesc_sbase;
    wire [4:0]       hin_word_addr;
    wire [31:0]      hin_word_rdata;
    wire             bo_we;
    wire [6:0]       bo_addr;
    wire [31:0]      bo_wdata;
    wire             bact_we;
    wire [5:0]       bact_addr;
    wire [31:0]      bact_wdata;
    wire [8:0]       by_addr;
    wire [31:0]      by_rdata;

    // block_ctrl core control
    wire             bc_core_start;
    wire [15:0]      bc_m, bc_n, bc_wbase, bc_sbase;
    wire [4:0]       bc_shift;

    // ---- core input mux: block has priority while running ----
    wire             core_start = block_busy ? bc_core_start : cpu_start;
    wire [15:0]      core_m     = block_busy ? bc_m     : cpu_m;
    wire [15:0]      core_n     = block_busy ? bc_n     : cpu_n;
    wire [15:0]      core_wbase = block_busy ? bc_wbase : cpu_wbase;
    wire [15:0]      core_sbase = block_busy ? bc_sbase : cpu_sbase;
    wire [4:0]       core_shift = block_busy ? bc_shift : cpu_shift;

    // ---------------------------------------------------------------
    w4a8_icb u_icb (
        .clk(clk), .rst_n(rst_n),
        .icb_cmd_valid(icb_cmd_valid), .icb_cmd_ready(icb_cmd_ready),
        .icb_cmd_addr(icb_cmd_addr), .icb_cmd_read(icb_cmd_read),
        .icb_cmd_wdata(icb_cmd_wdata), .icb_cmd_wmask(icb_cmd_wmask),
        .icb_rsp_valid(icb_rsp_valid), .icb_rsp_ready(icb_rsp_ready),
        .icb_rsp_rdata(icb_rsp_rdata), .icb_rsp_err(icb_rsp_err),

        .start_pulse(cpu_start),
        .cfg_m(cpu_m), .cfg_n(cpu_n), .cfg_w_base(cpu_wbase), .cfg_s_base(cpu_sbase),
        .cfg_shift(cpu_shift),
        .core_busy(core_busy), .core_done(core_done),
        .core_cnt_total(cnt_total), .core_cnt_mac(cnt_mac),
        .core_cnt_stall(cnt_stall), .core_cnt_tiles(cnt_tiles),

        .wmem_load_we(wmem_load_we), .wmem_load_flat_addr(wmem_load_flat_addr),
        .wmem_load_wdata(wmem_load_wdata),
        .smem_load_we(smem_load_we), .smem_load_addr(smem_load_addr),
        .smem_load_wdata(smem_load_wdata),

        .act_read_en(act_read_en), .act_addr(act_addr), .act_rdata(act_rdata),
        .ybuf_we(ybuf_we), .ybuf_addr(ybuf_addr), .ybuf_wdata(ybuf_wdata),

        .block_start(block_start), .block_busy(block_busy), .block_done(block_done),
        .block_cnt(block_cnt), .block_stage(block_stage),
        .block_desc_id(bdesc_id),
        .block_desc_m(bdesc_m), .block_desc_n(bdesc_n),
        .block_desc_wbase(bdesc_wbase), .block_desc_sbase(bdesc_sbase),
        .hin_word_addr(hin_word_addr), .hin_word_rdata(hin_word_rdata),
        .bo_we(bo_we), .bo_addr(bo_addr), .bo_wdata(bo_wdata),
        .block_act_we(bact_we), .block_act_addr(bact_addr), .block_act_wdata(bact_wdata),
        .block_y_addr(by_addr), .block_y_rdata(by_rdata)
    );

    w4a8_resident_wmem #(.BANK_DEPTH(4096), .ADDR_W(12)) u_wmem (
        .clk(clk),
        .load_we(wmem_load_we), .load_flat_addr(wmem_load_flat_addr),
        .load_wdata(wmem_load_wdata),
        .read_en(wmem_read_en), .read_bank_addr(wmem_bank_addr),
        .read_rdata_flat(wmem_rdata_flat)
    );

    w4a8_resident_smem #(.DEPTH(1024), .ADDR_W(10)) u_smem (
        .clk(clk),
        .load_we(smem_load_we), .load_addr(smem_load_addr), .load_wdata(smem_load_wdata),
        .read_en(smem_read_en), .read_addr(smem_addr), .read_rdata(smem_rdata)
    );

    w4a8_core u_core (
        .clk(clk), .rst_n(rst_n),
        .start(core_start),
        .cfg_m(core_m), .cfg_n(core_n), .cfg_w_base(core_wbase),
        .cfg_s_base(core_sbase), .cfg_shift(core_shift),
        .busy(core_busy), .done(core_done),
        .wmem_read_en(wmem_read_en), .wmem_bank_addr(wmem_bank_addr),
        .wmem_rdata_flat(wmem_rdata_flat),
        .smem_read_en(smem_read_en), .smem_addr(smem_addr), .smem_rdata(smem_rdata),
        .act_read_en(act_read_en), .act_addr(act_addr), .act_rdata(act_rdata),
        .ybuf_we(ybuf_we), .ybuf_addr(ybuf_addr), .ybuf_wdata(ybuf_wdata),
        .cnt_total(cnt_total), .cnt_mac(cnt_mac),
        .cnt_stall(cnt_stall), .cnt_tiles(cnt_tiles)
    );

    w4a8_block_ctrl #(.HIDDEN(128), .FFN(256)) u_block_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(block_start), .busy(block_busy), .done(block_done),
        .cnt(block_cnt), .stage(block_stage),
        .hin_word_addr(hin_word_addr), .hin_word_rdata(hin_word_rdata),
        .bo_we(bo_we), .bo_addr(bo_addr), .bo_wdata(bo_wdata),
        .act_we(bact_we), .act_addr(bact_addr), .act_wdata(bact_wdata),
        .y_addr(by_addr), .y_rdata(by_rdata),
        .desc_id(bdesc_id), .desc_m(bdesc_m), .desc_n(bdesc_n),
        .desc_wbase(bdesc_wbase), .desc_sbase(bdesc_sbase),
        .core_start(bc_core_start), .core_m(bc_m), .core_n(bc_n),
        .core_wbase(bc_wbase), .core_sbase(bc_sbase), .core_shift(bc_shift),
        .core_busy(core_busy), .core_done(core_done)
    );

endmodule
