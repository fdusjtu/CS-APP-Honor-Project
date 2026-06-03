`timescale 1ns/1ps
// Transformer block controller: sequences the full Step-4 block on FPGA.
// Reuses w4a8_core (Linear) externally and the ln/attn/gelu/residual vector
// units internally. Bit-exact vs tools/w4a8_block_full.py::run_full_block_py.
//
// Stage order (each per-element loop is one cycle/element):
//   LN1 -> qkv -> attn -> proj -> res1 -> LN2 -> ffn_up -> GELU -> ffn_dn -> res2
//
// Timing discipline: only st / ei / pack_word / res1 / issued / cnt / busy are
// registered. All *_we / *_data / *_addr / *_start are combinational functions
// of (st, ei) so the consumer latches the correct element on each clock edge.

module w4a8_block_ctrl #(
    parameter HIDDEN = 128,
    parameter FFN    = 256
) (
    input              clk,
    input              rst_n,

    input              start,
    output reg         busy,
    output reg         done,
    output reg [31:0]  cnt,
    output [7:0]       stage,

    output [4:0]       hin_word_addr,
    input  [31:0]      hin_word_rdata,

    output reg         bo_we,
    output [6:0]       bo_addr,
    output [31:0]      bo_wdata,

    output reg         act_we,
    output [5:0]       act_addr,
    output [31:0]      act_wdata,

    output [8:0]       y_addr,
    input  [31:0]      y_rdata,

    output reg [3:0]   desc_id,
    input  [15:0]      desc_m,
    input  [15:0]      desc_n,
    input  [15:0]      desc_wbase,
    input  [15:0]      desc_sbase,

    output reg         core_start,
    output [15:0]      core_m,
    output [15:0]      core_n,
    output [15:0]      core_wbase,
    output [15:0]      core_sbase,
    output [4:0]       core_shift,
    input              core_busy,
    input              core_done
);
`include "w4a8_block_consts.vh"

    localparam DEFAULT_SHIFT = 14;
    integer kk;

    reg signed [31:0] res1 [0:HIDDEN-1];
    reg [8:0]  ei;
    reg [31:0] pack_word;
    reg        issued;

    // ---- state ----
    localparam [4:0]
        S_IDLE=0, S_LN1_LOAD=1, S_LN1_RUN=2, S_QKV_PACK=3, S_QKV_CORE=4,
        S_ATTN_Q=5, S_ATTN_K=6, S_ATTN_V=7, S_ATTN_RUN=8, S_PROJ_PACK=9,
        S_PROJ_CORE=10, S_RES1=11, S_LN2_LOAD=12, S_LN2_RUN=13, S_FUP_PACK=14,
        S_FUP_CORE=15, S_GELU_LOAD=16, S_GELU_RUN=17, S_FDN_PACK=18,
        S_FDN_CORE=19, S_RES2=20, S_DONE=21;
    reg [4:0] st;
    assign stage = {3'b0, st};

    assign core_m     = desc_m;
    assign core_n     = desc_n;
    assign core_wbase = desc_wbase;
    assign core_sbase = desc_sbase;
    assign core_shift = DEFAULT_SHIFT;

    // ---- hidden_in byte (combinational) ----
    assign hin_word_addr = ei[6:2];
    reg signed [7:0] hbyte;
    always @(*) begin
        case (ei[1:0])
            2'd0: hbyte = hin_word_rdata[7:0];
            2'd1: hbyte = hin_word_rdata[15:8];
            2'd2: hbyte = hin_word_rdata[23:16];
            2'd3: hbyte = hin_word_rdata[31:24];
        endcase
    end
    wire signed [31:0] hidden_se = {{24{hbyte[7]}}, hbyte};

    // ---- y_buf address ----
    reg [8:0] y_base;
    always @(*) begin
        case (st)
            S_ATTN_K: y_base = 9'd128;
            S_ATTN_V: y_base = 9'd256;
            default : y_base = 9'd0;
        endcase
    end
    assign y_addr = y_base + ei;

    // ---- ln_unit ----
    wire        ln_busy, ln_done;
    wire signed [31:0] ln_out_data;
    reg         ln_start, ln_which, ln_in_we;
    reg signed [31:0] ln_in_data;
    w4a8_ln_unit #(.N(HIDDEN)) u_ln (
        .clk(clk), .rst_n(rst_n), .start(ln_start), .which_ln(ln_which),
        .in_we(ln_in_we), .in_addr(ei[7:0]), .in_data(ln_in_data),
        .out_addr(ei[7:0]), .out_data(ln_out_data),
        .busy(ln_busy), .done(ln_done));

    // ---- attn_unit ----
    wire        attn_busy, attn_done;
    wire signed [7:0] attn_out_data;
    reg         attn_start, attn_in_we;
    reg [1:0]   attn_sel;
    reg signed [7:0] attn_in_data;
    w4a8_attn_unit #(.HD(HIDDEN)) u_attn (
        .clk(clk), .rst_n(rst_n), .start(attn_start),
        .s_scores(BC_S_SCORES[4:0]), .s_attn_out(BC_S_ATTN_OUT[4:0]),
        .in_we(attn_in_we), .in_sel(attn_sel), .in_addr(ei[7:0]), .in_data(attn_in_data),
        .out_addr(ei[7:0]), .out_data(attn_out_data),
        .busy(attn_busy), .done(attn_done));

    // ---- gelu_unit ----
    wire        gelu_busy, gelu_done;
    wire signed [7:0] gelu_out_data;
    reg         gelu_start, gelu_in_we;
    reg signed [31:0] gelu_in_data;
    w4a8_gelu_unit #(.N(FFN)) u_gelu (
        .clk(clk), .rst_n(rst_n), .start(gelu_start), .shift(BC_S_FFN_UP_OUT[4:0]),
        .in_we(gelu_in_we), .in_addr(ei[8:0]), .in_data(gelu_in_data),
        .out_addr(ei[8:0]), .out_data(gelu_out_data),
        .busy(gelu_busy), .done(gelu_done));

    // ---- shared requant (combinational) ----
    reg signed [31:0] rq_val;
    reg [4:0]         rq_sh;
    wire signed [7:0] rq_out;
    w4a8_requant #(.WIDTH(32)) u_rq (.value(rq_val), .shift(rq_sh), .out(rq_out));
    always @(*) begin
        case (st)
            S_QKV_PACK: begin rq_val = ln_out_data; rq_sh = BC_S_LN1_OUT[4:0]; end
            S_FUP_PACK: begin rq_val = ln_out_data; rq_sh = BC_S_LN2_OUT[4:0]; end
            S_ATTN_Q:   begin rq_val = y_rdata;     rq_sh = BC_S_Q_REQUANT[4:0]; end
            S_ATTN_K:   begin rq_val = y_rdata;     rq_sh = BC_S_K_REQUANT[4:0]; end
            S_ATTN_V:   begin rq_val = y_rdata;     rq_sh = BC_S_V_REQUANT[4:0]; end
            default:    begin rq_val = 32'b0;       rq_sh = 5'b0; end
        endcase
    end

    // ---- residual unit (combinational) ----
    reg signed [31:0] res_a, res_b;
    reg [4:0]         res_sh;
    reg               res_trim;
    wire signed [31:0] res_out;
    w4a8_residual_unit u_res (.a(res_a), .b(res_b), .shamt(res_sh),
                              .is_trim(res_trim), .out(res_out));
    always @(*) begin
        if (st == S_RES1) begin
            res_a = hidden_se; res_b = y_rdata; res_sh = BC_S_LIFT[4:0]; res_trim = 1'b0;
        end else begin
            res_a = res1[ei[6:0]]; res_b = y_rdata; res_sh = BC_S_BLK_TRIM[4:0]; res_trim = 1'b1;
        end
    end

    // ---- byte to pack into act_buf ----
    reg signed [7:0] pack_byte;
    always @(*) begin
        case (st)
            S_QKV_PACK, S_FUP_PACK: pack_byte = rq_out;
            S_PROJ_PACK:            pack_byte = attn_out_data;
            S_FDN_PACK:             pack_byte = gelu_out_data;
            default:                pack_byte = 8'b0;
        endcase
    end

    wire is_pack = (st==S_QKV_PACK)||(st==S_PROJ_PACK)||(st==S_FUP_PACK)||(st==S_FDN_PACK);
    assign act_addr  = ei[7:2];
    assign act_wdata = {pack_byte, pack_word[23:0]};
    assign bo_addr   = ei[6:0];
    assign bo_wdata  = res_out;

    // ---- combinational control signals ----
    always @(*) begin
        // defaults
        ln_start=0; ln_which=0; ln_in_we=0; ln_in_data=32'b0;
        attn_start=0; attn_in_we=0; attn_sel=2'b0; attn_in_data=8'b0;
        gelu_start=0; gelu_in_we=0; gelu_in_data=32'b0;
        core_start=0; desc_id=4'b0; act_we=0; bo_we=0;

        case (st)
            S_LN1_LOAD: begin ln_in_we=1; ln_in_data=hidden_se; ln_which=0; end
            S_LN1_RUN:  begin ln_which=0; ln_start = ~issued; end
            S_QKV_PACK: begin act_we = (ei[1:0]==2'd3); end
            S_QKV_CORE: begin desc_id=4'd0; core_start = ~issued; end
            S_ATTN_Q:   begin attn_in_we=1; attn_sel=2'd0; attn_in_data=rq_out; end
            S_ATTN_K:   begin attn_in_we=1; attn_sel=2'd1; attn_in_data=rq_out; end
            S_ATTN_V:   begin attn_in_we=1; attn_sel=2'd2; attn_in_data=rq_out; end
            S_ATTN_RUN: begin attn_start = ~issued; end
            S_PROJ_PACK:begin act_we = (ei[1:0]==2'd3); end
            S_PROJ_CORE:begin desc_id=4'd1; core_start = ~issued; end
            S_RES1:     begin end
            S_LN2_LOAD: begin ln_in_we=1; ln_in_data=res1[ei[6:0]]; ln_which=1; end
            S_LN2_RUN:  begin ln_which=1; ln_start = ~issued; end
            S_FUP_PACK: begin act_we = (ei[1:0]==2'd3); end
            S_FUP_CORE: begin desc_id=4'd2; core_start = ~issued; end
            S_GELU_LOAD:begin gelu_in_we=1; gelu_in_data=y_rdata; end
            S_GELU_RUN: begin gelu_start = ~issued; end
            S_FDN_PACK: begin act_we = (ei[1:0]==2'd3); end
            S_FDN_CORE: begin desc_id=4'd3; core_start = ~issued; end
            S_RES2:     begin bo_we = 1'b1; end
            default: ;
        endcase
    end

    // ---- sequential FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; cnt<=0; ei<=0; pack_word<=0; issued<=0;
            for (kk=0;kk<HIDDEN;kk=kk+1) res1[kk]<=0;
        end else begin
            // block_done is a LEVEL: it is set when the block reaches S_DONE and
            // held until the next start clears it (mirrors w4a8_core's done_q).
            // A 1-cycle pulse here was invisible to the firmware's slow MMIO poll
            // and caused the on-board "block FPGA TIMEOUT status=0" failure.
            if (busy) cnt <= cnt + 1'b1;

            // pack byte accumulation (bytes 0..2; byte3 goes straight to act_wdata)
            if (is_pack) begin
                case (ei[1:0])
                    2'd0: pack_word[7:0]   <= pack_byte;
                    2'd1: pack_word[15:8]  <= pack_byte;
                    2'd2: pack_word[23:16] <= pack_byte;
                    default: ;
                endcase
            end

            case (st)
                S_IDLE: if (start) begin busy<=1; done<=0; cnt<=0; ei<=0; st<=S_LN1_LOAD; end

                S_LN1_LOAD: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_LN1_RUN; end
                            else ei<=ei+1'b1;
                S_LN1_RUN:  begin if (!issued) issued<=1;
                                  else if (ln_done) begin ei<=0; st<=S_QKV_PACK; end end

                S_QKV_PACK: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_QKV_CORE; end
                            else ei<=ei+1'b1;
                S_QKV_CORE: begin if (!issued) issued<=1;
                                  else if (core_done) begin ei<=0; st<=S_ATTN_Q; end end

                S_ATTN_Q: if (ei==HIDDEN-1) begin ei<=0; st<=S_ATTN_K; end else ei<=ei+1'b1;
                S_ATTN_K: if (ei==HIDDEN-1) begin ei<=0; st<=S_ATTN_V; end else ei<=ei+1'b1;
                S_ATTN_V: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_ATTN_RUN; end
                          else ei<=ei+1'b1;
                S_ATTN_RUN: begin if (!issued) issued<=1;
                                  else if (attn_done) begin ei<=0; st<=S_PROJ_PACK; end end

                S_PROJ_PACK: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_PROJ_CORE; end
                             else ei<=ei+1'b1;
                S_PROJ_CORE: begin if (!issued) issued<=1;
                                   else if (core_done) begin ei<=0; st<=S_RES1; end end

                S_RES1: begin res1[ei[6:0]] <= res_out;
                              if (ei==HIDDEN-1) begin ei<=0; st<=S_LN2_LOAD; end
                              else ei<=ei+1'b1; end

                S_LN2_LOAD: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_LN2_RUN; end
                            else ei<=ei+1'b1;
                S_LN2_RUN:  begin if (!issued) issued<=1;
                                  else if (ln_done) begin ei<=0; st<=S_FUP_PACK; end end

                S_FUP_PACK: if (ei==HIDDEN-1) begin ei<=0; issued<=0; st<=S_FUP_CORE; end
                            else ei<=ei+1'b1;
                S_FUP_CORE: begin if (!issued) issued<=1;
                                  else if (core_done) begin ei<=0; st<=S_GELU_LOAD; end end

                S_GELU_LOAD: if (ei==FFN-1) begin ei<=0; issued<=0; st<=S_GELU_RUN; end
                             else ei<=ei+1'b1;
                S_GELU_RUN:  begin if (!issued) issued<=1;
                                   else if (gelu_done) begin ei<=0; st<=S_FDN_PACK; end end

                S_FDN_PACK: if (ei==FFN-1) begin ei<=0; issued<=0; st<=S_FDN_CORE; end
                            else ei<=ei+1'b1;
                S_FDN_CORE: begin if (!issued) issued<=1;
                                  else if (core_done) begin ei<=0; st<=S_RES2; end end

                S_RES2: if (ei==HIDDEN-1) begin ei<=0; st<=S_DONE; end else ei<=ei+1'b1;

                S_DONE: begin busy<=0; done<=1'b1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
