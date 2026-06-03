`timescale 1ns/1ps

module row_rescale (
    input  signed [31:0] acc,
    input  signed [15:0] scale,
    input  [4:0]         shift,
    output signed [31:0] y
);
    wire signed [47:0] product;
    wire signed [47:0] shifted;

    assign product = acc * scale;
    assign shifted = product >>> shift;
    assign y = shifted[31:0];
endmodule
