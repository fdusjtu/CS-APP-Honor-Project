`timescale 1ns/1ps
// Sequential integer floor-sqrt: result = floor(sqrt(n)).
//
// Bit-exact match to tools/w4a8_block_full.py::isqrt_floor (== math.isqrt).
// Classic base-4 digit-by-digit algorithm, one iteration per cycle.
//
// Handshake: pulse `start` with `n` valid. `busy` high while computing.
// `done` pulses for one cycle when `root` holds floor(sqrt(n)).
//
// n is treated as unsigned up to 64 bits. NOTE: the running `res` transiently
// reaches the largest power-of-four <= n (up to ~2^62), so res/bit are kept
// 64-bit wide; the final root fits 32 bits (n < 2^62 => root < 2^31).

module w4a8_isqrt (
    input              clk,
    input              rst_n,
    input              start,
    input  [63:0]      n,
    output reg         busy,
    output reg         done,
    output reg [31:0]  root
);
    reg [63:0] num_q;
    reg [63:0] res_q;
    reg [63:0] bit_q;     // current power-of-four, 1<<(2k)
    reg [5:0]  iter_q;    // 32 iterations: k = 31..0

    wire [63:0] res_plus_bit = res_q + bit_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            done   <= 1'b0;
            root   <= 32'b0;
            num_q  <= 64'b0;
            res_q  <= 64'b0;
            bit_q  <= 64'b0;
            iter_q <= 6'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                num_q  <= n;
                res_q  <= 64'b0;
                bit_q  <= 64'h4000_0000_0000_0000;  // 1 << 62
                iter_q <= 6'd32;
                busy   <= 1'b1;
            end else if (busy) begin
                if (iter_q != 6'd0) begin
                    if (num_q >= res_plus_bit) begin
                        num_q <= num_q - res_plus_bit;
                        res_q <= (res_q >> 1) + bit_q;
                    end else begin
                        res_q <= res_q >> 1;
                    end
                    bit_q  <= bit_q >> 2;
                    iter_q <= iter_q - 6'd1;
                end else begin
                    root <= res_q[31:0];
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
