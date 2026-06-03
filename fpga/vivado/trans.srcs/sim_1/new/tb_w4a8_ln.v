`timescale 1ns/1ps
// Unit test for w4a8_ln_unit against Python golden intermediates.
//   LN1: input hidden_in (INT8 sign-extended), output == ln1_out
//   LN2: input res1 (INT32),                    output == ln2_out

`define TV "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_block"

module tb_w4a8_ln;
    localparam N = 128;
    reg clk=0, rst_n=0, start=0, which=0;
    reg in_we=0; reg [7:0] in_addr=0; reg signed [31:0] in_data=0;
    reg [7:0] out_addr=0; wire signed [31:0] out_data;
    wire busy, done;

    w4a8_ln_unit #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .which_ln(which),
        .in_we(in_we), .in_addr(in_addr), .in_data(in_data),
        .out_addr(out_addr), .out_data(out_data), .busy(busy), .done(done));

    always #5 clk = ~clk;

    reg [7:0]  hidden_in [0:N-1];
    reg signed [31:0] res1 [0:N-1];
    reg signed [31:0] ln1_out [0:N-1];
    reg signed [31:0] ln2_out [0:N-1];
    integer i, errors=0;

    task load_i8_se(input [8*64-1:0] dummy);  // placeholder, unused
    endtask

    task run_ln(input w, input integer is_int32);
        integer j;
        begin
            which = w;
            for (j=0;j<N;j=j+1) begin
                @(posedge clk);
                in_we = 1; in_addr = j[7:0];
                if (is_int32) in_data = (w==0) ? 0 : res1[j];
                else          in_data = $signed({{24{hidden_in[j][7]}}, hidden_in[j]});
            end
            @(posedge clk); in_we = 0;
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            while (!done) @(posedge clk);
        end
    endtask

    task check(input integer is_ln2);
        integer j; reg signed [31:0] exp;
        begin
            for (j=0;j<N;j=j+1) begin
                out_addr = j[7:0]; #1;
                exp = is_ln2 ? ln2_out[j] : ln1_out[j];
                if (out_data !== exp) begin
                    $display("LN%0d FAIL i=%0d got=%0d exp=%0d", is_ln2?2:1, j, out_data, exp);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        $readmemh({`TV, "/hidden_in.hex"}, hidden_in);
        $readmemh({`TV, "/res1.hex"},      res1);
        $readmemh({`TV, "/ln1_out.hex"},   ln1_out);
        $readmemh({`TV, "/ln2_out.hex"},   ln2_out);

        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

        // LN1 over hidden_in
        run_ln(1'b0, 0);
        check(0);

        // LN2 over res1
        run_ln(1'b1, 1);
        check(1);

        if (errors == 0) $display("LN UNIT TB ALL PASS");
        else             $display("LN UNIT TB FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
