`timescale 1ns/1ps
// GELU vector unit: requant INT32 -> INT8, then 256-entry signed LUT lookup.
// Bit-exact vs w4a8_block_full.py: ffn_up_q8 = sat8(round_shift(x, shift));
//                                   gelu_out = gelu_lut[ffn_up_q8 + 128].
//
// Streaming: write INT32 inputs via in_*, pulse start with `shift`, wait done,
// read INT8 outputs via out_addr/out_data.

module w4a8_gelu_unit #(
    parameter N      = 256,
    parameter INIT_DIR = "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init"
) (
    input              clk,
    input              rst_n,
    input              start,
    input  [4:0]       shift,

    input              in_we,
    input  [8:0]       in_addr,
    input  signed [31:0] in_data,

    input  [8:0]       out_addr,
    output signed [7:0] out_data,

    output reg         busy,
    output reg         done
);
    integer k;
    reg signed [31:0] x   [0:N-1];
    reg signed [7:0]  y   [0:N-1];
    assign out_data = y[out_addr];

    reg signed [7:0] gelu_lut [0:255];
    initial $readmemh({INIT_DIR, "/gelu_lut.hex"}, gelu_lut);

    reg [8:0] idx;

    wire signed [7:0] q8;
    w4a8_requant #(.WIDTH(32)) u_rq (.value(x[idx]), .shift(shift), .out(q8));
    wire [7:0] lut_addr = q8 + 8'sd128;   // q8 in [-128,127] -> [0,255]

    localparam [1:0] S_IDLE=0, S_RUN=1, S_DONE=2;
    reg [1:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; idx<=0;
            for (k=0;k<N;k=k+1) begin x[k]<=0; y[k]<=0; end
        end else begin
            done<=0;
            if (in_we) x[in_addr] <= in_data;
            case (st)
                S_IDLE: if (start) begin busy<=1; idx<=0; st<=S_RUN; end
                S_RUN: begin
                    y[idx] <= gelu_lut[lut_addr];
                    if (idx == N-1) st<=S_DONE;
                    else idx <= idx + 1'b1;
                end
                S_DONE: begin busy<=0; done<=1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
