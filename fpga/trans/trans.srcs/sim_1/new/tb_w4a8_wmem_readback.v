`timescale 1ns/1ps
// CPU weight-readback testbench (Step-4 method-A gate).
//
// Verifies the W_RD_ADDR / W_RD_DATA MMIO path: the CPU sets a flat weight
// address and reads back the bank-selected 32-bit word from resident_wmem,
// with auto-increment on each W_RD_DATA read. Compared bit-exact against the
// same bram_init/wmem_bankNN.hex images the DUT loads.

`define BRAM "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init"

module tb_w4a8_wmem_readback;
    reg         clk=0, rst_n=0;
    reg         icb_cmd_valid=0;
    wire        icb_cmd_ready;
    reg [31:0]  icb_cmd_addr=0;
    reg         icb_cmd_read=0;
    reg [31:0]  icb_cmd_wdata=0;
    reg [3:0]   icb_cmd_wmask=0;
    wire        icb_rsp_valid;
    reg         icb_rsp_ready=1;
    wire [31:0] icb_rsp_rdata;
    wire        icb_rsp_err;

    w4a8_block_engine dut (
        .clk(clk), .rst_n(rst_n),
        .icb_cmd_valid(icb_cmd_valid), .icb_cmd_ready(icb_cmd_ready),
        .icb_cmd_addr(icb_cmd_addr), .icb_cmd_read(icb_cmd_read),
        .icb_cmd_wdata(icb_cmd_wdata), .icb_cmd_wmask(icb_cmd_wmask),
        .icb_rsp_valid(icb_rsp_valid), .icb_rsp_ready(icb_rsp_ready),
        .icb_rsp_rdata(icb_rsp_rdata), .icb_rsp_err(icb_rsp_err));

    always #5 clk = ~clk;

    localparam REG_W_RD_ADDR = 12'h030;
    localparam REG_W_RD_DATA = 12'h034;

    task icb_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            icb_cmd_valid<=1; icb_cmd_addr<={20'b0,addr}; icb_cmd_read<=0;
            icb_cmd_wdata<=data; icb_cmd_wmask<=4'hF;
            while (!icb_cmd_ready) @(posedge clk);
            @(posedge clk);
            icb_cmd_valid<=0; icb_cmd_wmask<=0;
            while (!icb_rsp_valid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task icb_read(input [11:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            icb_cmd_valid<=1; icb_cmd_addr<={20'b0,addr}; icb_cmd_read<=1;
            icb_cmd_wdata<=0; icb_cmd_wmask<=0;
            while (!icb_cmd_ready) @(posedge clk);
            @(posedge clk);
            icb_cmd_valid<=0;
            while (!icb_rsp_valid) @(posedge clk);
            data = icb_rsp_rdata;
            @(posedge clk);
        end
    endtask

    // Reference copies of the 16 bank images (iverilog needs flat 1-D arrays).
    reg [31:0] rb0 [0:4095];  reg [31:0] rb1 [0:4095];
    reg [31:0] rb2 [0:4095];  reg [31:0] rb3 [0:4095];
    reg [31:0] rb4 [0:4095];  reg [31:0] rb5 [0:4095];
    reg [31:0] rb6 [0:4095];  reg [31:0] rb7 [0:4095];
    reg [31:0] rb8 [0:4095];  reg [31:0] rb9 [0:4095];
    reg [31:0] rb10[0:4095];  reg [31:0] rb11[0:4095];
    reg [31:0] rb12[0:4095];  reg [31:0] rb13[0:4095];
    reg [31:0] rb14[0:4095];  reg [31:0] rb15[0:4095];
    initial begin
        $readmemh({`BRAM,"/wmem_bank00.hex"}, rb0);
        $readmemh({`BRAM,"/wmem_bank01.hex"}, rb1);
        $readmemh({`BRAM,"/wmem_bank02.hex"}, rb2);
        $readmemh({`BRAM,"/wmem_bank03.hex"}, rb3);
        $readmemh({`BRAM,"/wmem_bank04.hex"}, rb4);
        $readmemh({`BRAM,"/wmem_bank05.hex"}, rb5);
        $readmemh({`BRAM,"/wmem_bank06.hex"}, rb6);
        $readmemh({`BRAM,"/wmem_bank07.hex"}, rb7);
        $readmemh({`BRAM,"/wmem_bank08.hex"}, rb8);
        $readmemh({`BRAM,"/wmem_bank09.hex"}, rb9);
        $readmemh({`BRAM,"/wmem_bank10.hex"}, rb10);
        $readmemh({`BRAM,"/wmem_bank11.hex"}, rb11);
        $readmemh({`BRAM,"/wmem_bank12.hex"}, rb12);
        $readmemh({`BRAM,"/wmem_bank13.hex"}, rb13);
        $readmemh({`BRAM,"/wmem_bank14.hex"}, rb14);
        $readmemh({`BRAM,"/wmem_bank15.hex"}, rb15);
    end

    integer errors = 0;
    integer n = 0;

    function [31:0] expect_word(input [15:0] flat);
        reg [11:0] a;
        begin
            a = flat[15:4];
            case (flat[3:0])
                4'd0: expect_word = rb0[a];   4'd1: expect_word = rb1[a];
                4'd2: expect_word = rb2[a];   4'd3: expect_word = rb3[a];
                4'd4: expect_word = rb4[a];   4'd5: expect_word = rb5[a];
                4'd6: expect_word = rb6[a];   4'd7: expect_word = rb7[a];
                4'd8: expect_word = rb8[a];   4'd9: expect_word = rb9[a];
                4'd10: expect_word = rb10[a]; 4'd11: expect_word = rb11[a];
                4'd12: expect_word = rb12[a]; 4'd13: expect_word = rb13[a];
                4'd14: expect_word = rb14[a]; default: expect_word = rb15[a];
            endcase
        end
    endfunction

    task check_addr(input [15:0] flat);
        reg [31:0] got, exp;
        begin
            icb_write(REG_W_RD_ADDR, {16'b0, flat});
            icb_read(REG_W_RD_DATA, got);
            exp = expect_word(flat);
            n = n + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  MISMATCH flat=%0d bank=%0d baddr=%0d got=%08x exp=%08x",
                         flat, flat[3:0], flat[15:4], got, exp);
            end
        end
    endtask

    integer k;
    reg [31:0] got, exp;
    reg [15:0] base;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // 1) Explicit address checks across banks and bank_addr rows.
        check_addr(16'd0);     // bank0 baddr0
        check_addr(16'd1);     // bank1 baddr0
        check_addr(16'd15);    // bank15 baddr0
        check_addr(16'd16);    // bank0 baddr1
        check_addr(16'd17);    // bank1 baddr1
        check_addr(16'd255);   // bank15 baddr15
        check_addr(16'd2112);  // mid (layer boundary-ish)
        check_addr(16'd33791); // last used packed word (33792 total)

        // 2) Auto-increment: set base once, read 40 consecutive words.
        base = 16'd512;
        icb_write(REG_W_RD_ADDR, {16'b0, base});
        for (k = 0; k < 40; k = k + 1) begin
            icb_read(REG_W_RD_DATA, got);
            exp = expect_word(base + k[15:0]);
            n = n + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  INC MISMATCH off=%0d flat=%0d got=%08x exp=%08x",
                         k, base + k, got, exp);
            end
        end

        if (errors == 0)
            $display("WMEM READBACK TB PASS (%0d words checked)", n);
        else
            $display("WMEM READBACK TB FAIL (%0d / %0d mismatches)", errors, n);
        $finish;
    end
endmodule
