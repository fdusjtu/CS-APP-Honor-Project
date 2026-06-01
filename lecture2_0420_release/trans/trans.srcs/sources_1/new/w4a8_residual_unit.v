`timescale 1ns/1ps
// Combinational residual add. Bit-exact vs w4a8_block_full.py:
//   lift (is_trim=0): out = (a << shamt) + b     [residual 1: hidden<<S_LIFT + proj]
//   trim (is_trim=1): out = (a >>> shamt) + b    [residual 2: res1>>S_BLK_TRIM + ffn_dn]
// The trim shift is a raw arithmetic right shift (no rounding), matching the
// Python `res1 >> S_BLK_TRIM` and the C signed `>>`.

module w4a8_residual_unit (
    input  signed [31:0] a,
    input  signed [31:0] b,
    input         [4:0]  shamt,
    input                is_trim,
    output signed [31:0] out
);
    wire signed [31:0] a_sh = is_trim ? (a >>> shamt) : (a <<< shamt);
    assign out = a_sh + b;
endmodule
