`timescale 1ns/1ps
// Top-level W4A8 Linear Engine.
//
// Drop-in replacement for gemv_accel at the SoC level: same ICB slave
// interface, same base address (0x1004_1000) is mapped by the SoC
// wrapper. Internally executes a full Linear layer per CTRL.start
// using the descriptor selected by LAYER_ID.
//
// Submodules:
//   w4a8_icb            ICB slave, register file, descriptor table,
//                       ACT_BUF (64 words), Y_BUF (384 words).
//   w4a8_resident_wmem  16-bank INT4-packed weight memory (256 KB cap).
//   w4a8_resident_smem  Packed INT16x2 per-row scale memory (4 KB cap).
//   w4a8_core           Linear-layer FSM, 16-row parallel MAC, rescale,
//                       performance counters.

module w4a8_linear_engine (
    input              clk,
    input              rst_n,

    // ICB slave (matches gemv_accel pinout for drop-in replacement)
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

    // ---------------------------------------------------------------
    // icb <-> core / memories
    // ---------------------------------------------------------------
    wire             start_pulse;
    wire [15:0]      cfg_m, cfg_n, cfg_w_base, cfg_s_base;
    wire [4:0]       cfg_shift;
    wire             core_busy, core_done;
    wire [31:0]      core_cnt_total, core_cnt_mac, core_cnt_stall, core_cnt_tiles;

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

    // ---------------------------------------------------------------
    // ICB slave + register file
    // ---------------------------------------------------------------
    w4a8_icb u_icb (
        .clk                  (clk),
        .rst_n                (rst_n),

        .icb_cmd_valid        (icb_cmd_valid),
        .icb_cmd_ready        (icb_cmd_ready),
        .icb_cmd_addr         (icb_cmd_addr),
        .icb_cmd_read         (icb_cmd_read),
        .icb_cmd_wdata        (icb_cmd_wdata),
        .icb_cmd_wmask        (icb_cmd_wmask),
        .icb_rsp_valid        (icb_rsp_valid),
        .icb_rsp_ready        (icb_rsp_ready),
        .icb_rsp_rdata        (icb_rsp_rdata),
        .icb_rsp_err          (icb_rsp_err),

        .start_pulse          (start_pulse),
        .cfg_m                (cfg_m),
        .cfg_n                (cfg_n),
        .cfg_w_base           (cfg_w_base),
        .cfg_s_base           (cfg_s_base),
        .cfg_shift            (cfg_shift),
        .core_busy            (core_busy),
        .core_done            (core_done),
        .core_cnt_total       (core_cnt_total),
        .core_cnt_mac         (core_cnt_mac),
        .core_cnt_stall       (core_cnt_stall),
        .core_cnt_tiles       (core_cnt_tiles),

        .wmem_load_we         (wmem_load_we),
        .wmem_load_flat_addr  (wmem_load_flat_addr),
        .wmem_load_wdata      (wmem_load_wdata),

        .smem_load_we         (smem_load_we),
        .smem_load_addr       (smem_load_addr),
        .smem_load_wdata      (smem_load_wdata),

        .act_read_en          (act_read_en),
        .act_addr             (act_addr),
        .act_rdata            (act_rdata),

        .ybuf_we              (ybuf_we),
        .ybuf_addr            (ybuf_addr),
        .ybuf_wdata           (ybuf_wdata)
    );

    // ---------------------------------------------------------------
    // Resident weight memory (16-bank, 256 KB cap)
    // ---------------------------------------------------------------
    w4a8_resident_wmem #(
        .BANK_DEPTH (4096),
        .ADDR_W     (12)
    ) u_wmem (
        .clk             (clk),
        .load_we         (wmem_load_we),
        .load_flat_addr  (wmem_load_flat_addr),
        .load_wdata      (wmem_load_wdata),
        .read_en         (wmem_read_en),
        .read_bank_addr  (wmem_bank_addr),
        .read_rdata_flat (wmem_rdata_flat)
    );

    // ---------------------------------------------------------------
    // Resident scale memory (single port)
    // ---------------------------------------------------------------
    w4a8_resident_smem #(
        .DEPTH  (1024),
        .ADDR_W (10)
    ) u_smem (
        .clk         (clk),
        .load_we     (smem_load_we),
        .load_addr   (smem_load_addr),
        .load_wdata  (smem_load_wdata),
        .read_en     (smem_read_en),
        .read_addr   (smem_addr),
        .read_rdata  (smem_rdata)
    );

    // ---------------------------------------------------------------
    // Linear-layer core (FSM, MAC array, rescale, perf counters)
    // ---------------------------------------------------------------
    w4a8_core u_core (
        .clk              (clk),
        .rst_n            (rst_n),

        .start            (start_pulse),
        .cfg_m            (cfg_m),
        .cfg_n            (cfg_n),
        .cfg_w_base       (cfg_w_base),
        .cfg_s_base       (cfg_s_base),
        .cfg_shift        (cfg_shift),

        .busy             (core_busy),
        .done             (core_done),

        .wmem_read_en     (wmem_read_en),
        .wmem_bank_addr   (wmem_bank_addr),
        .wmem_rdata_flat  (wmem_rdata_flat),

        .smem_read_en     (smem_read_en),
        .smem_addr        (smem_addr),
        .smem_rdata       (smem_rdata),

        .act_read_en      (act_read_en),
        .act_addr         (act_addr),
        .act_rdata        (act_rdata),

        .ybuf_we          (ybuf_we),
        .ybuf_addr        (ybuf_addr),
        .ybuf_wdata       (ybuf_wdata),

        .cnt_total        (core_cnt_total),
        .cnt_mac          (core_cnt_mac),
        .cnt_stall        (core_cnt_stall),
        .cnt_tiles        (core_cnt_tiles)
    );

endmodule
