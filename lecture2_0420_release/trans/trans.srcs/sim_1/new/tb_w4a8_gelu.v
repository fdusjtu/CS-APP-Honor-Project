`timescale 1ns/1ps
// Unit test for w4a8_gelu_unit: ffn_up_out (INT32) -> gelu_out (INT8), S=0.

`define TV "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_block"

module tb_w4a8_gelu;
    localparam N = 256;
    reg clk=0, rst_n=0, start=0; reg [4:0] shift=0;
    reg in_we=0; reg [8:0] in_addr=0; reg signed [31:0] in_data=0;
    reg [8:0] out_addr=0; wire signed [7:0] out_data;
    wire busy, done;

    w4a8_gelu_unit #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .shift(shift),
        .in_we(in_we), .in_addr(in_addr), .in_data(in_data),
        .out_addr(out_addr), .out_data(out_data), .busy(busy), .done(done));

    always #5 clk = ~clk;

    reg signed [31:0] ffn_up_out [0:N-1];
    reg signed [7:0]  gelu_exp   [0:N-1];
    integer i, errors=0;

    initial begin
        $readmemh({`TV, "/ffn_up_out.hex"}, ffn_up_out);
        $readmemh({`TV, "/gelu_out.hex"},   gelu_exp);

        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        for (i=0;i<N;i=i+1) begin
            @(posedge clk); in_we=1; in_addr=i[8:0]; in_data=ffn_up_out[i];
        end
        @(posedge clk); in_we=0;
        @(posedge clk); shift=0; start=1;
        @(posedge clk); start=0;
        while (!done) @(posedge clk);

        for (i=0;i<N;i=i+1) begin
            out_addr=i[8:0]; #1;
            if (out_data !== gelu_exp[i]) begin
                $display("GELU FAIL i=%0d got=%0d exp=%0d", i, out_data, gelu_exp[i]);
                errors=errors+1;
            end
        end
        if (errors==0) $display("GELU UNIT TB ALL PASS");
        else           $display("GELU UNIT TB FAIL (%0d)", errors);
        $finish;
    end
endmodule
