`timescale 1ns/1ps
// 16-bank resident INT4-packed weight memory for w4a8_linear_engine.
//
// Capacity : 16 banks x 4096 x 32-bit = 256 KB (target model uses 132 KB).
// Layout   : bank = flat_addr[3:0], bank_addr = flat_addr >> 4.
//            One 32-bit word holds 8 signed INT4 nibbles (lsn first).
//
// Two phases (load vs run are exclusive):
//   - Load : CPU streams W_LOAD_DATA in fixed order
//              for each layer / row_tile / col_word / bank in 0..15
//            so 16 consecutive writes fill one bank_addr across all banks.
//   - Run  : engine drives bank_addr_r; all 16 banks read in parallel,
//            rdata appears one cycle later (registered) for BRAM inference.
//
// BRAM inference: each bank is a single 32-bit memory with one write port
// and one read port; load and run never overlap, no read-during-write hazard.

module w4a8_resident_wmem #(
    parameter BANK_DEPTH = 4096,
    parameter ADDR_W     = 12
) (
    input               clk,
    // load port (CPU side)
    input               load_we,
    input  [15:0]       load_flat_addr,
    input  [31:0]       load_wdata,
    // run port (engine side) -- bank_addr_r is registered into BRAM read
    input               read_en,
    input  [ADDR_W-1:0] read_bank_addr,
    output [16*32-1:0]  read_rdata_flat
);

    wire [3:0]         load_bank      = load_flat_addr[3:0];
    wire [ADDR_W-1:0]  load_bank_addr = load_flat_addr[ADDR_W+3:4];

    // 16 banks, each a 32-bit-wide BRAM of depth BANK_DEPTH.
    // (* ram_style = "block" *) lets Vivado infer block RAM explicitly.
    genvar b;
    generate
        for (b = 0; b < 16; b = b + 1) begin : g_bank
            (* ram_style = "block" *) reg [31:0] mem [0:BANK_DEPTH-1];
            reg [31:0] rdata_r;

            if (b == 0) begin : g_init0
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank00.hex", mem);
            end else if (b == 1) begin : g_init1
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank01.hex", mem);
            end else if (b == 2) begin : g_init2
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank02.hex", mem);
            end else if (b == 3) begin : g_init3
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank03.hex", mem);
            end else if (b == 4) begin : g_init4
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank04.hex", mem);
            end else if (b == 5) begin : g_init5
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank05.hex", mem);
            end else if (b == 6) begin : g_init6
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank06.hex", mem);
            end else if (b == 7) begin : g_init7
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank07.hex", mem);
            end else if (b == 8) begin : g_init8
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank08.hex", mem);
            end else if (b == 9) begin : g_init9
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank09.hex", mem);
            end else if (b == 10) begin : g_init10
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank10.hex", mem);
            end else if (b == 11) begin : g_init11
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank11.hex", mem);
            end else if (b == 12) begin : g_init12
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank12.hex", mem);
            end else if (b == 13) begin : g_init13
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank13.hex", mem);
            end else if (b == 14) begin : g_init14
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank14.hex", mem);
            end else begin : g_init15
                initial $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/bram_init/wmem_bank15.hex", mem);
            end

            always @(posedge clk) begin
                if (load_we && load_bank == b[3:0])
                    mem[load_bank_addr] <= load_wdata;
                if (read_en)
                    rdata_r <= mem[read_bank_addr];
            end

            assign read_rdata_flat[b*32 +: 32] = rdata_r;
        end
    endgenerate

endmodule
