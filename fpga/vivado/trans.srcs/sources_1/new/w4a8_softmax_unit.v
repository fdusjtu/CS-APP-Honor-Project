`timescale 1ns/1ps
// Fixed-point softmax over a short INT8 score vector (bit-exact vs
// w4a8_block_full.py::int_softmax_py). Produces Q0.15 INT16 probabilities.
//
//   m       = max(scores)
//   y_clip  = clamp(scores - m, -16, 0)
//   exp_q   = exp_lut[y_clip + 16]            (INT16, Q0.15)
//   sum_exp = sum(exp_q)
//   prob[t] = min(32767, round_div(exp_q[t] << 15, sum_exp))
//   (degenerate sum_exp <= 0 -> uniform 32768 / n)
//
// Streaming interface: write n INT8 scores via in_*, pulse start with `n`,
// wait done, read INT16 probs via out_addr/out_data.

module w4a8_softmax_unit #(
    parameter MAXL    = 8,
    parameter INIT_DIR = "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init"
) (
    input              clk,
    input              rst_n,
    input              start,
    input  [3:0]       n,                // number of scores (<= MAXL)

    input              in_we,
    input  [2:0]       in_addr,
    input  signed [7:0] in_data,

    input  [2:0]       out_addr,
    output signed [15:0] out_data,

    output reg         busy,
    output reg         done
);
    integer k;

    reg signed [7:0]  scores [0:MAXL-1];
    reg signed [15:0] probs  [0:MAXL-1];
    assign out_data = probs[out_addr];

    // exp LUT (17 entries, INT16 Q0.15)
    reg signed [15:0] exp_lut [0:16];
    initial $readmemh({INIT_DIR, "/exp_lut.hex"}, exp_lut);

    reg signed [7:0]  max_q;
    reg signed [31:0] sum_exp_q;
    reg signed [15:0] exp_q [0:MAXL-1];
    reg [3:0]  n_q;
    reg [3:0]  idx;

    // clip(scores[idx]-max, -16, 0) + 16
    wire signed [15:0] sub_i  = scores[idx] - max_q;          // <= 0
    wire signed [15:0] clip_i = (sub_i < -16) ? -16 : sub_i;  // [-16,0]
    wire [4:0] lut_idx = clip_i[4:0] + 5'd16;                 // 0..16

    // idiv for the normalising division
    reg               dv_start;
    reg  signed [47:0] dv_num;
    reg         [31:0] dv_den;
    wire              dv_busy, dv_done;
    wire signed [47:0] dv_q;
    w4a8_idiv #(.NUM_W(48), .DEN_W(32)) u_div (
        .clk(clk), .rst_n(rst_n), .start(dv_start),
        .num(dv_num), .den(dv_den), .busy(dv_busy), .done(dv_done), .q(dv_q));

    localparam [3:0] S_IDLE=0, S_MAX=1, S_EXP=2, S_SUM=3, S_DIV_ISSUE=4,
                     S_DIV_WAIT=5, S_UNIFORM=6, S_DONE=7;
    reg [3:0] st;

    wire signed [47:0] prob_clamped = (dv_q > 32767) ? 48'sd32767 : dv_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; max_q<=0; sum_exp_q<=0; n_q<=0; idx<=0;
            dv_start<=0; dv_num<=0; dv_den<=0;
            for (k=0;k<MAXL;k=k+1) begin scores[k]<=0; probs[k]<=0; exp_q[k]<=0; end
        end else begin
            done<=0; dv_start<=0;
            if (in_we) scores[in_addr] <= in_data;

            case (st)
                S_IDLE: if (start) begin
                    busy<=1; n_q<=n; idx<=0;
                    max_q<=scores[0]; st<=S_MAX;
                end
                S_MAX: begin
                    if (scores[idx] > max_q) max_q <= scores[idx];
                    if (idx == n_q-1) begin idx<=0; sum_exp_q<=0; st<=S_EXP; end
                    else idx <= idx + 1'b1;
                end
                S_EXP: begin
                    exp_q[idx] <= exp_lut[lut_idx];
                    sum_exp_q  <= sum_exp_q + exp_lut[lut_idx];
                    if (idx == n_q-1) begin idx<=0; st<=S_SUM; end
                    else idx <= idx + 1'b1;
                end
                S_SUM: begin
                    if (sum_exp_q <= 0) st <= S_UNIFORM;
                    else st <= S_DIV_ISSUE;
                end
                S_DIV_ISSUE: begin
                    dv_num   <= $signed({exp_q[idx], 15'b0});   // exp_q << 15
                    dv_den   <= sum_exp_q;
                    dv_start <= 1'b1;
                    st <= S_DIV_WAIT;
                end
                S_DIV_WAIT: if (dv_done) begin
                    probs[idx] <= prob_clamped[15:0];
                    if (idx == n_q-1) st <= S_DONE;
                    else begin idx <= idx + 1'b1; st <= S_DIV_ISSUE; end
                end
                S_UNIFORM: begin
                    probs[idx] <= 32768 / {28'b0, n_q};   // never hit on real data
                    if (idx == n_q-1) st <= S_DONE;
                    else idx <= idx + 1'b1;
                end
                S_DONE: begin busy<=0; done<=1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
