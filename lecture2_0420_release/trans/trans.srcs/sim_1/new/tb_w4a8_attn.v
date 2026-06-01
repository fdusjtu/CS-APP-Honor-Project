`timescale 1ns/1ps
// Unit test for w4a8_attn_unit against Python golden attn_q8.

`define TV "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_block"

module tb_w4a8_attn;
    localparam HD = 128;
    reg clk=0, rst_n=0, start=0;
    reg [4:0] s_scores=12, s_attn=0;
    reg in_we=0; reg [1:0] in_sel=0; reg [7:0] in_addr=0; reg signed [7:0] in_data=0;
    reg [7:0] out_addr=0; wire signed [7:0] out_data;
    wire busy, done;

    w4a8_attn_unit #(.HD(HD)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .s_scores(s_scores), .s_attn_out(s_attn),
        .in_we(in_we), .in_sel(in_sel), .in_addr(in_addr), .in_data(in_data),
        .out_addr(out_addr), .out_data(out_data), .busy(busy), .done(done));

    always #5 clk = ~clk;

    reg signed [7:0] Q [0:HD-1];
    reg signed [7:0] K [0:HD-1];
    reg signed [7:0] V [0:HD-1];
    reg signed [7:0] attn_exp [0:HD-1];
    integer i, errors=0;

    task load(input [1:0] sel, input integer src);
        integer j;
        begin
            for (j=0;j<HD;j=j+1) begin
                @(posedge clk); in_we=1; in_sel=sel; in_addr=j[7:0];
                in_data = (src==0) ? Q[j] : (src==1) ? K[j] : V[j];
            end
        end
    endtask

    initial begin
        $readmemh({`TV, "/Q_q8.hex"},   Q);
        $readmemh({`TV, "/K1_q8.hex"},  K);
        $readmemh({`TV, "/V1_q8.hex"},  V);
        $readmemh({`TV, "/attn_q8.hex"}, attn_exp);

        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        load(2'd0, 0);
        load(2'd1, 1);
        load(2'd2, 2);
        @(posedge clk); in_we=0;
        @(posedge clk); start=1;
        @(posedge clk); start=0;
        while (!done) @(posedge clk);

        for (i=0;i<HD;i=i+1) begin
            out_addr=i[7:0]; #1;
            if (out_data !== attn_exp[i]) begin
                $display("ATTN FAIL i=%0d got=%0d exp=%0d", i, out_data, attn_exp[i]);
                errors=errors+1;
            end
        end
        if (errors==0) $display("ATTN UNIT TB ALL PASS");
        else           $display("ATTN UNIT TB FAIL (%0d)", errors);
        $finish;
    end
endmodule
