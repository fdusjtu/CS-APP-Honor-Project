`timescale 1ns/1ps
// Combinational round-to-nearest (ties up) right shift + INT8 saturate.
//
// Bit-exact match to tools/w4a8_block_full.py::round_shift then sat8:
//   shift == 0 : r = value
//   shift  > 0 : half = 1 << (shift-1)
//                value >= 0 : r = (value + half) >> shift
//                value <  0 : r = -((-value + half) >> shift)
//   out = sat8(r)
//
// WIDTH is the signed input width (must cover all callers: LN diff up to
// INT32, scores up to INT32, attention/ffn requant up to INT32). 40 bits
// covers every Step-4 requant input with margin.

module w4a8_requant #(
    parameter WIDTH = 40
) (
    input  signed [WIDTH-1:0] value,
    input         [4:0]       shift,     // 0..31, non-negative
    output signed [7:0]       out
);
    // half = 1 << (shift-1), zero when shift==0
    wire signed [WIDTH-1:0] half =
        (shift == 5'd0) ? {WIDTH{1'b0}}
                        : (({{(WIDTH-1){1'b0}}, 1'b1}) << (shift - 5'd1));

    wire signed [WIDTH-1:0] neg_value = -value;
    wire signed [WIDTH-1:0] mag_pos   = (value + half) >>> shift;        // value>=0 path
    wire signed [WIDTH-1:0] mag_neg   = (neg_value + half) >>> shift;    // -((-value+half)>>shift)

    wire signed [WIDTH-1:0] r =
        (shift == 5'd0) ? value
      : (value >= 0)    ? mag_pos
                        : -mag_neg;

    // saturate to INT8 (signed literals sign-extend to r's width)
    assign out = (r > 127)   ? 8'sd127
               : (r < -128)  ? -8'sd128
                             : r[7:0];
endmodule
