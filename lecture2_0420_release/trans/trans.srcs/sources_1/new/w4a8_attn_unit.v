`timescale 1ns/1ps
// Attention vector unit (seq_len=2, single head), bit-exact vs
// w4a8_block_full.py attention stage:
//
//   K_seq = [kv_prev_k, K1_q8],  V_seq = [kv_prev_v, V1_q8]
//   scores[t]  = sum_d Q[d] * K_seq[t][d]                       (INT32)
//   scores_q8  = sat8(round_shift(scores, S_SCORES))
//   probs      = softmax(scores_q8)                             (Q0.15)
//   attn[d]    = sum_t probs[t] * V_seq[t][d]                   (INT32)
//   back[d]    = round_shift(attn[d], 15)
//   attn_q8[d] = sat8(round_shift(back[d], S_ATTN_OUT))
//
// Streaming: write Q/K1/V1 (sel 0/1/2) via in_*, pulse start with the two
// shift amounts, wait done, read INT8 attn_q8 via out_addr/out_data.
// kv_prev_k / kv_prev_v are resident $readmemh constants.

module w4a8_attn_unit #(
    parameter HD     = 128,                 // head dim
    parameter INIT_DIR = "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init"
) (
    input              clk,
    input              rst_n,
    input              start,
    input  [4:0]       s_scores,
    input  [4:0]       s_attn_out,

    input              in_we,
    input  [1:0]       in_sel,             // 0=Q, 1=K1, 2=V1
    input  [7:0]       in_addr,
    input  signed [7:0] in_data,

    input  [7:0]       out_addr,
    output signed [7:0] out_data,

    output reg         busy,
    output reg         done
);
    integer k;

    reg signed [7:0] Q   [0:HD-1];
    reg signed [7:0] K1  [0:HD-1];
    reg signed [7:0] V1  [0:HD-1];
    reg signed [7:0] attn[0:HD-1];
    assign out_data = attn[out_addr];

    reg signed [7:0] kprev [0:HD-1];
    reg signed [7:0] vprev [0:HD-1];
    initial begin
        $readmemh({INIT_DIR, "/kv_prev_k.hex"}, kprev);
        $readmemh({INIT_DIR, "/kv_prev_v.hex"}, vprev);
    end

    reg signed [31:0] acc0_q, acc1_q;      // scores[0], scores[1]
    reg signed [15:0] prob0_q, prob1_q;
    reg [7:0] idx;

    // round_shift by 15 (constant) for the weighted-sum back-scale
    function signed [31:0] rshift15(input signed [47:0] v);
        reg signed [47:0] half;
        begin
            half = 48'sd1 <<< 14;          // 1 << (15-1)
            if (v >= 0) rshift15 = (v + half) >>> 15;
            else        rshift15 = -((-v + half) >>> 15);
        end
    endfunction

    // dedicated combinational requant instances (no shared-instance skew)
    wire signed [7:0] sc0_q8, sc1_q8, attn_q8;
    w4a8_requant #(.WIDTH(32)) u_rq_sc0 (.value(acc0_q), .shift(s_scores), .out(sc0_q8));
    w4a8_requant #(.WIDTH(32)) u_rq_sc1 (.value(acc1_q), .shift(s_scores), .out(sc1_q8));

    wire signed [47:0] wsum =
        $signed(prob0_q) * $signed(vprev[idx]) +
        $signed(prob1_q) * $signed(V1[idx]);
    wire signed [31:0] back = rshift15(wsum);
    w4a8_requant #(.WIDTH(32)) u_rq_attn (.value(back), .shift(s_attn_out), .out(attn_q8));

    // softmax submodule
    reg               sm_start;
    reg  [3:0]        sm_n;
    reg               sm_in_we;
    reg  [2:0]        sm_in_addr;
    reg  signed [7:0] sm_in_data;
    reg  [2:0]        sm_out_addr;
    wire signed [15:0] sm_out_data;
    wire              sm_busy, sm_done;
    w4a8_softmax_unit u_sm (
        .clk(clk), .rst_n(rst_n), .start(sm_start), .n(sm_n),
        .in_we(sm_in_we), .in_addr(sm_in_addr), .in_data(sm_in_data),
        .out_addr(sm_out_addr), .out_data(sm_out_data),
        .busy(sm_busy), .done(sm_done));

    localparam [3:0] S_IDLE=0, S_SC0=1, S_SC1=2, S_SMLD0=3, S_SMLD1=4,
                     S_SMRUN=5, S_SMWAIT=6, S_RDP0=7, S_RDP1=8, S_RDP2=9,
                     S_WSUM=10, S_DONE=11;
    reg [3:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; idx<=0; acc0_q<=0; acc1_q<=0;
            prob0_q<=0; prob1_q<=0;
            sm_start<=0; sm_n<=0; sm_in_we<=0; sm_in_addr<=0; sm_in_data<=0; sm_out_addr<=0;
            for (k=0;k<HD;k=k+1) begin Q[k]<=0; K1[k]<=0; V1[k]<=0; attn[k]<=0; end
        end else begin
            done<=0; sm_start<=0; sm_in_we<=0;

            if (in_we) begin
                case (in_sel)
                    2'd0: Q[in_addr]  <= in_data;
                    2'd1: K1[in_addr] <= in_data;
                    2'd2: V1[in_addr] <= in_data;
                endcase
            end

            case (st)
                S_IDLE: if (start) begin
                    busy<=1; idx<=0; acc0_q<=0; st<=S_SC0;
                end
                S_SC0: begin
                    acc0_q <= acc0_q + $signed(Q[idx]) * $signed(kprev[idx]);
                    if (idx==HD-1) begin idx<=0; acc1_q<=0; st<=S_SC1; end
                    else idx<=idx+1'b1;
                end
                S_SC1: begin
                    acc1_q <= acc1_q + $signed(Q[idx]) * $signed(K1[idx]);
                    if (idx==HD-1) st<=S_SMLD0;
                    else idx<=idx+1'b1;
                end
                S_SMLD0: begin
                    sm_in_we<=1; sm_in_addr<=3'd0; sm_in_data<=sc0_q8; st<=S_SMLD1;
                end
                S_SMLD1: begin
                    sm_in_we<=1; sm_in_addr<=3'd1; sm_in_data<=sc1_q8; st<=S_SMRUN;
                end
                S_SMRUN: begin
                    sm_n<=4'd2; sm_start<=1'b1; st<=S_SMWAIT;
                end
                S_SMWAIT: if (sm_done) begin
                    sm_out_addr<=3'd0; st<=S_RDP0;
                end
                S_RDP0: begin
                    sm_out_addr<=3'd0; st<=S_RDP1;     // settle addr 0
                end
                S_RDP1: begin
                    prob0_q<=sm_out_data; sm_out_addr<=3'd1; st<=S_RDP2;
                end
                S_RDP2: begin
                    prob1_q<=sm_out_data; idx<=0; st<=S_WSUM;
                end
                S_WSUM: begin
                    attn[idx] <= attn_q8;
                    if (idx==HD-1) st<=S_DONE;
                    else idx<=idx+1'b1;
                end
                S_DONE: begin busy<=0; done<=1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
