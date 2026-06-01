`timescale 1ns/1ps
// Resident per-row scale memory for w4a8_linear_engine.
//
// Capacity : 1024 x 32-bit = 4 KB (target model uses 928 words).
// Layout   : each 32-bit word holds 2 signed INT16 scales,
//            for row r: word_addr = s_base + (r >> 1), half = r[0].
//
// Single port (read or write per cycle). Engine pre-loads a 16-row
// scale_tile[16] before RESCALE by issuing 8 consecutive reads.

module w4a8_resident_smem #(
    parameter DEPTH   = 1024,
    parameter ADDR_W  = 10
) (
    input                clk,
    // load port (CPU side)
    input                load_we,
    input  [ADDR_W-1:0]  load_addr,
    input  [31:0]        load_wdata,
    // run port (engine side)
    input                read_en,
    input  [ADDR_W-1:0]  read_addr,
    output reg [31:0]    read_rdata
);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];

    initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/smem.hex", mem);

    always @(posedge clk) begin
        if (load_we)
            mem[load_addr] <= load_wdata;
        if (read_en)
            read_rdata <= mem[read_addr];
    end

endmodule
