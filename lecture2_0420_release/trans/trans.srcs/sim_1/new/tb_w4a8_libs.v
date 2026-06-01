`timescale 1ns/1ps
// Self-checking testbench for the Step-4 library primitives:
//   w4a8_requant (combinational), w4a8_idiv, w4a8_isqrt (sequential).
// Expected values precomputed by tools/w4a8_block_full.py.
// Run with iverilog for fast iteration.

module tb_w4a8_libs;
    integer errors = 0;

    // ---------------- requant ----------------
    reg  signed [39:0] rq_val;
    reg         [4:0]  rq_shift;
    wire signed [7:0]  rq_out;
    w4a8_requant #(.WIDTH(40)) u_rq (.value(rq_val), .shift(rq_shift), .out(rq_out));

    task check_rq(input signed [39:0] v, input [4:0] s, input signed [7:0] exp);
        begin
            rq_val = v; rq_shift = s; #1;
            if (rq_out !== exp) begin
                $display("RQ FAIL v=%0d s=%0d got=%0d exp=%0d", v, s, rq_out, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- idiv ----------------
    reg          clk = 0;
    reg          rst_n = 0;
    reg          dv_start = 0;
    reg  signed [47:0] dv_num;
    reg         [31:0] dv_den;
    wire         dv_busy, dv_done;
    wire signed [47:0] dv_q;
    w4a8_idiv #(.NUM_W(48), .DEN_W(32)) u_dv (
        .clk(clk), .rst_n(rst_n), .start(dv_start),
        .num(dv_num), .den(dv_den), .busy(dv_busy), .done(dv_done), .q(dv_q));

    // ---------------- isqrt ----------------
    reg         sq_start = 0;
    reg  [63:0] sq_n;
    wire        sq_busy, sq_done;
    wire [31:0] sq_root;
    w4a8_isqrt u_sq (
        .clk(clk), .rst_n(rst_n), .start(sq_start),
        .n(sq_n), .busy(sq_busy), .done(sq_done), .root(sq_root));

    always #5 clk = ~clk;

    task run_idiv(input signed [47:0] n, input [31:0] d, input signed [47:0] exp);
        begin
            @(posedge clk); dv_num = n; dv_den = d; dv_start = 1;
            @(posedge clk); dv_start = 0;
            while (!dv_done) @(posedge clk);
            if (dv_q !== exp) begin
                $display("DV FAIL num=%0d den=%0d got=%0d exp=%0d", n, d, dv_q, exp);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    task run_isqrt(input [63:0] n, input [31:0] exp);
        begin
            @(posedge clk); sq_n = n; sq_start = 1;
            @(posedge clk); sq_start = 0;
            while (!sq_done) @(posedge clk);
            if (sq_root !== exp) begin
                $display("SQ FAIL n=%0d got=%0d exp=%0d", n, sq_root, exp);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        // requant
        check_rq(100, 0, 100);
        check_rq(200, 1, 100);
        check_rq(-200, 1, -100);
        check_rq(255, 1, 127);
        check_rq(-255, 1, -128);
        check_rq(1000, 3, 125);
        check_rq(-1000, 3, -125);
        check_rq(5, 1, 3);
        check_rq(-5, 1, -3);
        check_rq(7, 2, 2);
        check_rq(-7, 2, -2);
        check_rq(130, 0, 127);
        check_rq(-130, 0, -128);

        // sequential resets
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // idiv
        run_idiv(100, 7, 14);
        run_idiv(-100, 7, -14);
        run_idiv(103, 7, 15);
        run_idiv(-103, 7, -15);
        run_idiv(1, 2, 1);
        run_idiv(-1, 2, -1);
        run_idiv(1073709056, 40000, 26843);
        run_idiv(123456, 789, 156);
        run_idiv(-123456, 789, -156);
        run_idiv(0, 5, 0);

        // isqrt
        run_isqrt(0, 0);
        run_isqrt(1, 1);
        run_isqrt(2, 1);
        run_isqrt(3, 1);
        run_isqrt(4, 2);
        run_isqrt(15, 3);
        run_isqrt(16, 4);
        run_isqrt(1000000, 1000);
        run_isqrt(2147483647, 46340);
        run_isqrt(123456789, 11111);
        run_isqrt(64'd9999999999, 99999);

        if (errors == 0) $display("LIBS TB ALL PASS");
        else             $display("LIBS TB FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
