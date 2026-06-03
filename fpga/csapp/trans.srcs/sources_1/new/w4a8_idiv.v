`timescale 1ns/1ps
// Sequential signed divide, round-to-nearest ties up. den must be positive.
//
// Bit-exact match to tools/w4a8_block_full.py::round_div_signed:
//   if num >= 0: q =  (num + den/2) / den
//   else:        q = -((-num + den/2) / den)
//   (den/2 == den>>1 floor; the magnitude division floors toward zero.)
//
// Used by LayerNorm (num = diff*gamma up to ~40b, den = sigma up to ~28b)
// and softmax (num = exp<<15 up to ~30b, den = sum_exp up to ~18b, num>=0).
//
// Handshake: pulse `start` with num/den valid. `busy` while computing.
// `done` pulses one cycle when `q` is valid. Raw num/den are registered on
// the start pulse and the dividend is formed one cycle later, so there is no
// dependence on combinational settling of the inputs at the start edge.

module w4a8_idiv #(
    parameter NUM_W = 48,    // signed numerator width
    parameter DEN_W = 32     // positive denominator width
) (
    input                     clk,
    input                     rst_n,
    input                     start,
    input  signed [NUM_W-1:0] num,
    input         [DEN_W-1:0] den,
    output reg                busy,
    output reg                done,
    output reg signed [NUM_W-1:0] q
);
    localparam ABITS = NUM_W + 1;   // dividend = |num| + den/2, one guard bit

    localparam [1:0] S_IDLE = 2'd0,
                     S_LOAD = 2'd1,
                     S_RUN  = 2'd2,
                     S_FIN  = 2'd3;
    reg [1:0] st;

    reg  signed [NUM_W-1:0] num_q;
    reg         [DEN_W-1:0] den_q;
    reg              sign_q;
    reg  [ABITS-1:0] a_q;           // dividend, shifted left each iteration
    reg  [DEN_W:0]   rem_q;         // remainder (one extra bit)
    reg  [ABITS-1:0] quo_q;
    reg  [6:0]       iter_q;

    wire [NUM_W-1:0] num_abs  = num_q[NUM_W-1] ? (-num_q) : num_q;
    wire [ABITS-1:0] dividend = {1'b0, num_abs} + {1'b0, (den_q >> 1)};

    wire [DEN_W:0] rem_shift = {rem_q[DEN_W-1:0], a_q[ABITS-1]};
    wire           rem_ge    = (rem_shift >= {1'b0, den_q});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            q      <= {NUM_W{1'b0}};
            num_q  <= {NUM_W{1'b0}};
            den_q  <= {DEN_W{1'b0}};
            sign_q <= 1'b0;
            a_q    <= {ABITS{1'b0}};
            rem_q  <= {(DEN_W+1){1'b0}};
            quo_q  <= {ABITS{1'b0}};
            iter_q <= 7'd0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (start) begin
                        num_q <= num;
                        den_q <= den;
                        busy  <= 1'b1;
                        st    <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    sign_q <= num_q[NUM_W-1];
                    a_q    <= dividend;
                    rem_q  <= {(DEN_W+1){1'b0}};
                    quo_q  <= {ABITS{1'b0}};
                    iter_q <= ABITS[6:0];
                    st     <= S_RUN;
                end
                S_RUN: begin
                    if (iter_q != 7'd0) begin
                        if (rem_ge) begin
                            rem_q <= rem_shift - {1'b0, den_q};
                            quo_q <= {quo_q[ABITS-2:0], 1'b1};
                        end else begin
                            rem_q <= rem_shift;
                            quo_q <= {quo_q[ABITS-2:0], 1'b0};
                        end
                        a_q    <= {a_q[ABITS-2:0], 1'b0};
                        iter_q <= iter_q - 7'd1;
                    end else begin
                        st <= S_FIN;
                    end
                end
                S_FIN: begin
                    q    <= sign_q ? -$signed({1'b0, quo_q[NUM_W-1:0]})
                                   :  $signed({1'b0, quo_q[NUM_W-1:0]});
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end
            endcase
        end
    end
endmodule
