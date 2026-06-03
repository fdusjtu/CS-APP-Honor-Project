`timescale 1ns/1ps
// Fixed-point LayerNorm vector unit (bit-exact vs w4a8_block_full.py).
//
//   mean  = round_shift(sum(x), 7)
//   diff  = x - mean
//   var   = round_shift(sum(diff*diff), 7)
//   sigma = isqrt(max(var, 1))
//   y[i]  = round_div_signed(diff[i]*gamma_q[i], sigma) + beta_q[i]
//
// Streaming interface: block_ctrl writes the INT32 input vector via the
// in_* port, pulses `start` (with which_ln selecting LN1/LN2 gamma+beta),
// waits `done`, then reads the INT32 output vector via out_addr/out_data.
//
// gamma (INT8) and beta (INT16) tables come from $readmemh, same files the
// firmware header and Python golden use.

module w4a8_ln_unit #(
    parameter N      = 128,
    parameter LOG2N  = 7,
    parameter INIT_DIR = "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init"
) (
    input              clk,
    input              rst_n,
    input              start,
    input              which_ln,        // 0 = LN1, 1 = LN2

    // input vector load port (INT32)
    input              in_we,
    input  [7:0]       in_addr,
    input  signed [31:0] in_data,

    // output vector read port (INT32, combinational)
    input  [7:0]       out_addr,
    output signed [31:0] out_data,

    output reg         busy,
    output reg         done
);
    integer k;
    reg        [7:0]  idx;

    // ---- input / output vector storage ----
    reg signed [31:0] x   [0:N-1];
    reg signed [31:0] y   [0:N-1];
    assign out_data = y[out_addr];

    // ---- constant tables ----
    reg signed [7:0]  gamma1 [0:N-1];
    reg signed [15:0] beta1  [0:N-1];
    reg signed [7:0]  gamma2 [0:N-1];
    reg signed [15:0] beta2  [0:N-1];
    initial begin
        $readmemh({INIT_DIR, "/ln1_gamma.hex"}, gamma1);
        $readmemh({INIT_DIR, "/ln1_beta.hex"},  beta1);
        $readmemh({INIT_DIR, "/ln2_gamma.hex"}, gamma2);
        $readmemh({INIT_DIR, "/ln2_beta.hex"},  beta2);
    end

    wire signed [7:0]  gamma_i = which_ln ? gamma2[idx] : gamma1[idx];
    wire signed [15:0] beta_i  = which_ln ? beta2[idx]  : beta1[idx];

    // ---- round_shift by LOG2N (constant 7) ----
    function signed [47:0] rshiftN(input signed [63:0] v);
        reg signed [63:0] half;
        begin
            half = 64'sd1 <<< (LOG2N - 1);
            if (v >= 0) rshiftN = (v + half) >>> LOG2N;
            else        rshiftN = -((-v + half) >>> LOG2N);
        end
    endfunction

    // ---- datapath registers ----
    reg signed [63:0] sum_q;
    reg signed [31:0] mean_q;
    reg signed [63:0] sumsq_q;
    reg signed [31:0] var_q;

    wire signed [31:0] diff_i = x[idx] - mean_q;

    // ---- isqrt ----
    reg          sq_start;
    reg  [63:0]  sq_n;
    wire         sq_busy, sq_done;
    wire [31:0]  sq_root;
    w4a8_isqrt u_sqrt (.clk(clk), .rst_n(rst_n), .start(sq_start),
                       .n(sq_n), .busy(sq_busy), .done(sq_done), .root(sq_root));

    // ---- idiv ----
    reg               dv_start;
    reg  signed [47:0] dv_num;
    reg         [31:0] dv_den;
    wire              dv_busy, dv_done;
    wire signed [47:0] dv_q;
    w4a8_idiv #(.NUM_W(48), .DEN_W(32)) u_div (
        .clk(clk), .rst_n(rst_n), .start(dv_start),
        .num(dv_num), .den(dv_den), .busy(dv_busy), .done(dv_done), .q(dv_q));

    // ---- FSM ----
    localparam [3:0] S_IDLE=0, S_SUM=1, S_MEAN=2, S_SUMSQ=3, S_VAR=4,
                     S_SQWAIT=5, S_DIV_ISSUE=6, S_DIV_WAIT=7, S_DONE=8;
    reg [3:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            sum_q <= 0; mean_q <= 0; sumsq_q <= 0; var_q <= 0; idx <= 0;
            sq_start <= 1'b0; sq_n <= 0; dv_start <= 1'b0; dv_num <= 0; dv_den <= 0;
            for (k=0;k<N;k=k+1) begin x[k]<=0; y[k]<=0; end
        end else begin
            done <= 1'b0; sq_start <= 1'b0; dv_start <= 1'b0;

            // input load (allowed while idle)
            if (in_we) x[in_addr] <= in_data;

            case (st)
                S_IDLE: if (start) begin
                    busy <= 1'b1; sum_q <= 0; idx <= 0; st <= S_SUM;
                end
                S_SUM: begin
                    sum_q <= sum_q + x[idx];
                    if (idx == N-1) begin idx <= 0; st <= S_MEAN; end
                    else idx <= idx + 1'b1;
                end
                S_MEAN: begin
                    mean_q <= rshiftN(sum_q);
                    sumsq_q <= 0; idx <= 0; st <= S_SUMSQ;
                end
                S_SUMSQ: begin
                    sumsq_q <= sumsq_q + $signed(diff_i) * $signed(diff_i);
                    if (idx == N-1) begin idx <= 0; st <= S_VAR; end
                    else idx <= idx + 1'b1;
                end
                S_VAR: begin
                    var_q <= rshiftN(sumsq_q);
                    sq_n  <= (rshiftN(sumsq_q) <= 0) ? 64'd1 : rshiftN(sumsq_q);
                    sq_start <= 1'b1;
                    st <= S_SQWAIT;
                end
                S_SQWAIT: if (sq_done) begin
                    idx <= 0; st <= S_DIV_ISSUE;
                end
                S_DIV_ISSUE: begin
                    dv_num   <= diff_i * gamma_i;     // INT32 * INT8
                    dv_den   <= sq_root;
                    dv_start <= 1'b1;
                    st <= S_DIV_WAIT;
                end
                S_DIV_WAIT: if (dv_done) begin
                    y[idx] <= $signed(dv_q[31:0]) + beta_i;
                    if (idx == N-1) st <= S_DONE;
                    else begin idx <= idx + 1'b1; st <= S_DIV_ISSUE; end
                end
                S_DONE: begin
                    busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                end
            endcase
        end
    end
endmodule
