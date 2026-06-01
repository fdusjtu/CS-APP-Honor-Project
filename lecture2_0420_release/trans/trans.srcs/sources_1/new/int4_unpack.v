`timescale 1ns/1ps

module int4_unpack (
    input  [31:0] word,
    input  [2:0]  index,
    output signed [7:0] value
);
    wire [3:0] nibble;

    assign nibble = word[index*4 +: 4];
    assign value = {{4{nibble[3]}}, nibble};
endmodule
