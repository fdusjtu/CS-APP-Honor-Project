`timescale 1ns / 1ps

module tb(

    );
    
    reg clk_p, clk_n, rst_n;
    wire uart0_txd;
    
    system dut(
        .CLK200MHZ_P(clk_p),
        .CLK200MHZ_N(clk_n),
        .fpga_rst(rst_n),
        .uart0_rxd(1'b1),
        .uart0_txd(uart0_txd)
    );
    
    localparam PERIOD = 5;
    initial begin
        rst_n = 1'b0;
        clk_p = 1'b1;
        clk_n = 1'b0;
        #(PERIOD * 100) rst_n = 1'b1;
    end
    
    always #(PERIOD/2) clk_p = ~clk_p;
    always #(PERIOD/2) clk_n = ~clk_n;
    
endmodule
