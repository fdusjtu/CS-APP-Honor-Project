`timescale 1ns/1ps
// Unit test for w4a8_softmax_unit against Python golden (scores_q8 -> probs_q15).

`define TV "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_block"

module tb_w4a8_softmax;
    reg clk=0, rst_n=0, start=0;
    reg [3:0] n=2;
    reg in_we=0; reg [2:0] in_addr=0; reg signed [7:0] in_data=0;
    reg [2:0] out_addr=0; wire signed [15:0] out_data;
    wire busy, done;

    w4a8_softmax_unit dut (
        .clk(clk), .rst_n(rst_n), .start(start), .n(n),
        .in_we(in_we), .in_addr(in_addr), .in_data(in_data),
        .out_addr(out_addr), .out_data(out_data), .busy(busy), .done(done));

    always #5 clk = ~clk;

    reg signed [7:0]  scores [0:1];
    reg signed [15:0] probs  [0:1];
    integer i, errors=0;

    initial begin
        $readmemh({`TV, "/scores_q8.hex"}, scores);
        $readmemh({`TV, "/probs_q15.hex"}, probs);

        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        for (i=0;i<2;i=i+1) begin
            @(posedge clk); in_we=1; in_addr=i[2:0]; in_data=scores[i];
        end
        @(posedge clk); in_we=0;
        @(posedge clk); n=2; start=1;
        @(posedge clk); start=0;
        while (!done) @(posedge clk);

        for (i=0;i<2;i=i+1) begin
            out_addr=i[2:0]; #1;
            if (out_data !== probs[i]) begin
                $display("SOFTMAX FAIL i=%0d got=%0d exp=%0d", i, out_data, probs[i]);
                errors=errors+1;
            end
        end
        if (errors==0) $display("SOFTMAX UNIT TB ALL PASS");
        else           $display("SOFTMAX UNIT TB FAIL (%0d)", errors);
        $finish;
    end
endmodule
