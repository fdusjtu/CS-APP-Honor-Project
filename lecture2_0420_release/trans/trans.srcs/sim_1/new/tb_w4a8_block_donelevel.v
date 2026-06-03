`timescale 1ns/1ps
// Regression for the on-board "block FPGA TIMEOUT status=0x00000000" bug.
//
// Root cause: block_done was a 1-cycle pulse, so the firmware's slow C-level
// MMIO poll (tens of CPU cycles per BLOCK_STATUS read) stepped over it and
// timed out, even though the block had completed. The fix is to latch
// block_done as a LEVEL that stays asserted after the block finishes until the
// next BLOCK_CTRL.start (mirroring how w4a8_core latches its done).
//
// This testbench runs a real block, detects the block_busy falling edge, then
// samples block_done 10 cycles LATER (emulating a late/slow poller). With the
// 1-cycle pulse it reads 0 -> FAIL; with the latched level it reads 1 -> PASS.

`define TV "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_block"

module tb_w4a8_block_donelevel;
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

    task write_desc(input [3:0] id, input [31:0] m, input [31:0] n,
                    input [31:0] wb, input [31:0] sb);
        reg [11:0] base;
        begin
            base = 12'h040 + id*12'h10;
            icb_write(base+0, m);
            icb_write(base+4, n);
            icb_write(base+8, wb);
            icb_write(base+12, sb);
        end
    endtask

    reg [7:0]  hidden_in [0:127];
    reg signed [31:0] golden [0:127];
    integer i, errors=0;
    reg [31:0] rd, cyc, word;
    integer late_status;

    initial begin
        $readmemh({`TV, "/hidden_in.hex"},        hidden_in);
        $readmemh({`TV, "/block_out_golden.hex"}, golden);

        rst_n=0; repeat(5) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

        write_desc(4'd0, 384, 128,   0,   0);
        write_desc(4'd1, 128, 128, 384, 192);
        write_desc(4'd2, 256, 128, 512, 256);
        write_desc(4'd3, 128, 256, 768, 384);

        for (i=0;i<32;i=i+1) begin
            word = {hidden_in[i*4+3], hidden_in[i*4+2], hidden_in[i*4+1], hidden_in[i*4+0]};
            icb_write(12'h900 + i*4, word);
        end

        icb_write(12'h800, 32'h1);

        // wait for the block to actually start, then for it to finish
        @(posedge clk);
        while (dut.block_busy !== 1'b1) @(posedge clk);
        while (dut.block_busy !== 1'b0) @(posedge clk);

        // a slow poller would only get here some cycles after busy fell.
        // emulate that latency, then sample BLOCK_STATUS the way firmware does.
        repeat (10) @(posedge clk);
        icb_read(12'h804, rd);
        late_status = rd[0];

        if (late_status !== 1) begin
            $display("DONELEVEL TB FAIL: block_done not latched (status=%h 10 cycles after busy fell)", rd);
            $display("  -> firmware slow poll would miss done -> on-board TIMEOUT");
            $finish;
        end

        // sanity: result is still correct + readable
        icb_read(12'h808, cyc);
        for (i=0;i<128;i=i+1) begin
            icb_read(12'hA00 + i*4, rd);
            if ($signed(rd) !== golden[i]) errors = errors + 1;
        end
        if (errors==0)
            $display("DONELEVEL TB PASS: block_done latched, block_out bit-exact (cycles=%0d)", cyc);
        else
            $display("DONELEVEL TB FAIL: %0d/128 mismatches", errors);
        $finish;
    end

    initial begin
        #50000000;
        $display("DONELEVEL TB FAIL: global timeout");
        $finish;
    end
endmodule
