`timescale 1ns/1ps
module clk_div(
   input  clk,
   input  rst_n,
   output reg  clk_div
);
	parameter NUM_DIV = 9'd488; //16M / 32.768K = 488.28
    reg    [8:0] cnt;
    
always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        cnt     <= 'd0;
        clk_div <= 'b0;
    end
    else if(cnt < NUM_DIV / 2 - 1) begin
        cnt     <= cnt + 1'b1;
        clk_div <= clk_div;
    end
    else begin
        cnt     <= 'd0;
        clk_div <= ~clk_div;
    end
endmodule
