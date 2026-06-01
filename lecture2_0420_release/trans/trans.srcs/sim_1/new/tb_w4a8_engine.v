`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// W4A8 Linear Engine testbench.
//
// Covers (in one run, in this order — each layer's PASS is reported separately):
//   * tb_w4a8_single_layer   : layer 1 (proj 128x128), smallest functional case
//   * tb_w4a8_multicol       : layer 3 (ffn_down 128x256), cross-col accumulation
//   * tb_w4a8_nine_layers    : all 9 target-model layers, bit-exact vs golden
//
// Test vector source: tools/w4a8_engine_vectors.py -> test_vectors/w4a8_engine/
//
// Strategy:
//   - Resident wmem/smem are initialized by the RTL $readmemh files used for
//     synthesis, so the TB validates the same BRAM init path as the bitstream.
//   - Write 9 layer descriptors via ICB (validates descriptor write path).
//   - For each layer: write ACT_BUF via ICB, set LAYER_ID, pulse CTRL.start,
//     poll STATUS.done, read Y_BUF and counters via ICB, compare to golden.
//
// Edit TV_DIR if your absolute path differs.
//-----------------------------------------------------------------------------

`define TV_DIR "D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/test_vectors/w4a8_engine"

module tb_w4a8_engine;

    // ----------------------------- DUT pins ---------------------------------
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         icb_cmd_valid = 1'b0;
    wire        icb_cmd_ready;
    reg [31:0]  icb_cmd_addr = 32'b0;
    reg         icb_cmd_read = 1'b0;
    reg [31:0]  icb_cmd_wdata = 32'b0;
    reg [3:0]   icb_cmd_wmask = 4'b0;
    wire        icb_rsp_valid;
    reg         icb_rsp_ready = 1'b1;
    wire [31:0] icb_rsp_rdata;
    wire        icb_rsp_err;

    w4a8_linear_engine dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .icb_cmd_valid(icb_cmd_valid),
        .icb_cmd_ready(icb_cmd_ready),
        .icb_cmd_addr (icb_cmd_addr),
        .icb_cmd_read (icb_cmd_read),
        .icb_cmd_wdata(icb_cmd_wdata),
        .icb_cmd_wmask(icb_cmd_wmask),
        .icb_rsp_valid(icb_rsp_valid),
        .icb_rsp_ready(icb_rsp_ready),
        .icb_rsp_rdata(icb_rsp_rdata),
        .icb_rsp_err  (icb_rsp_err)
    );

    // 100 MHz simulation clock (irrelevant — only edges count)
    always #5 clk = ~clk;

    // ---------------------------- Register map ------------------------------
    localparam REG_CTRL        = 12'h000;
    localparam REG_STATUS      = 12'h004;
    localparam REG_SHIFT       = 12'h008;
    localparam REG_LAYER_ID    = 12'h00C;
    localparam REG_W_LOAD_ADDR = 12'h010;
    localparam REG_W_LOAD_DATA = 12'h014;
    localparam REG_S_LOAD_ADDR = 12'h018;
    localparam REG_S_LOAD_DATA = 12'h01C;
    localparam REG_CNT_TOTAL   = 12'h020;
    localparam REG_CNT_MAC     = 12'h024;
    localparam REG_CNT_STALL   = 12'h028;
    localparam REG_CNT_TILES   = 12'h02C;
    localparam REG_DESC_BASE   = 12'h040;
    localparam REG_ACT_BASE    = 12'h100;
    localparam REG_Y_BASE      = 12'h200;

    // ------------------------------- TB state -------------------------------
    reg [31:0] wmem_words [0:33791];   // resident_w_load.hex
    reg [31:0] smem_words [0:1023];    // resident_s_load.hex (padded to 1024)
    reg [31:0] act_words  [0:63];      // per-layer act.hex
    reg [31:0] y_ref      [0:383];     // per-layer y_ref.hex

    // 9 layers' (M, N, w_base, s_base)
    integer L_M     [0:8];
    integer L_N     [0:8];
    integer L_WBASE [0:8];
    integer L_SBASE [0:8];
    reg [255:0] L_DIR [0:8];           // packed-string directory name (right-aligned)

    integer layer_pass;
    integer layer_fail;
    integer errors_total;

    // ------------------------------ ICB tasks -------------------------------
    task icb_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            icb_cmd_valid <= 1'b1;
            icb_cmd_addr  <= {20'b0, addr};
            icb_cmd_read  <= 1'b0;
            icb_cmd_wdata <= data;
            icb_cmd_wmask <= 4'hF;
            while (!icb_cmd_ready) @(posedge clk);
            @(posedge clk);
            icb_cmd_valid <= 1'b0;
            icb_cmd_addr  <= 32'b0;
            icb_cmd_wdata <= 32'b0;
            icb_cmd_wmask <= 4'b0;
            while (!icb_rsp_valid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task icb_read;
        input  [11:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            icb_cmd_valid <= 1'b1;
            icb_cmd_addr  <= {20'b0, addr};
            icb_cmd_read  <= 1'b1;
            icb_cmd_wdata <= 32'b0;
            icb_cmd_wmask <= 4'b0;
            while (!icb_cmd_ready) @(posedge clk);
            @(posedge clk);
            icb_cmd_valid <= 1'b0;
            icb_cmd_addr  <= 32'b0;
            while (!icb_rsp_valid) @(posedge clk);
            data = icb_rsp_rdata;
            @(posedge clk);
        end
    endtask

    task wait_done;
        integer poll_count;
        reg [31:0] s;
        begin
            poll_count = 0;
            s = 32'b0;
            while (s[0] == 1'b0 && poll_count < 100000) begin
                icb_read(REG_STATUS, s);
                poll_count = poll_count + 1;
            end
            if (s[0] !== 1'b1) begin
                $display("FAIL: timeout waiting for done (polled %0d times, status=%h)",
                         poll_count, s);
                $finish;
            end
        end
    endtask

    // --------------------- Backdoor BRAM preload ----------------------------
    // Distributes flat-indexed wmem stream into 16 banks per project_goal.md
    // layout: bank = flat[3:0], bank_addr = flat[15:4].
    task backdoor_load_wmem;
        integer fi;
        integer ba;
        begin
            $readmemh({`TV_DIR, "/resident_w_load.hex"}, wmem_words);
            for (fi = 0; fi < 33792; fi = fi + 1) begin
                ba = fi >> 4;
                case (fi[3:0])
                    4'd0  : dut.u_wmem.g_bank[0].mem[ba]  = wmem_words[fi];
                    4'd1  : dut.u_wmem.g_bank[1].mem[ba]  = wmem_words[fi];
                    4'd2  : dut.u_wmem.g_bank[2].mem[ba]  = wmem_words[fi];
                    4'd3  : dut.u_wmem.g_bank[3].mem[ba]  = wmem_words[fi];
                    4'd4  : dut.u_wmem.g_bank[4].mem[ba]  = wmem_words[fi];
                    4'd5  : dut.u_wmem.g_bank[5].mem[ba]  = wmem_words[fi];
                    4'd6  : dut.u_wmem.g_bank[6].mem[ba]  = wmem_words[fi];
                    4'd7  : dut.u_wmem.g_bank[7].mem[ba]  = wmem_words[fi];
                    4'd8  : dut.u_wmem.g_bank[8].mem[ba]  = wmem_words[fi];
                    4'd9  : dut.u_wmem.g_bank[9].mem[ba]  = wmem_words[fi];
                    4'd10 : dut.u_wmem.g_bank[10].mem[ba] = wmem_words[fi];
                    4'd11 : dut.u_wmem.g_bank[11].mem[ba] = wmem_words[fi];
                    4'd12 : dut.u_wmem.g_bank[12].mem[ba] = wmem_words[fi];
                    4'd13 : dut.u_wmem.g_bank[13].mem[ba] = wmem_words[fi];
                    4'd14 : dut.u_wmem.g_bank[14].mem[ba] = wmem_words[fi];
                    4'd15 : dut.u_wmem.g_bank[15].mem[ba] = wmem_words[fi];
                endcase
            end
            $display("INFO: backdoor wmem loaded (%0d words across 16 banks)", 33792);
        end
    endtask

    task backdoor_load_smem;
        integer si;
        begin
            $readmemh({`TV_DIR, "/resident_s_load.hex"}, smem_words);
            for (si = 0; si < 928; si = si + 1)
                dut.u_smem.mem[si] = smem_words[si];
            $display("INFO: backdoor smem loaded (%0d words)", 928);
        end
    endtask

    task write_all_descriptors;
        integer i;
        begin
            for (i = 0; i < 9; i = i + 1) begin
                icb_write(REG_DESC_BASE + i*16 + 12'h0, L_M[i]);
                icb_write(REG_DESC_BASE + i*16 + 12'h4, L_N[i]);
                icb_write(REG_DESC_BASE + i*16 + 12'h8, L_WBASE[i]);
                icb_write(REG_DESC_BASE + i*16 + 12'hC, L_SBASE[i]);
            end
            $display("INFO: 9 descriptors written via ICB");
        end
    endtask

    // --------------------------- Per-layer run ------------------------------
    task run_layer;
        input integer id;
        reg [4095:0] act_path;
        reg [4095:0] ref_path;
        integer M, N;
        integer act_word_count;
        integer y_word_count;
        integer i;
        integer mismatches;
        integer expected_mac, expected_tiles;
        reg [31:0] rdata;
        reg [31:0] cnt_total_obs, cnt_mac_obs, cnt_stall_obs, cnt_tiles_obs;
        begin
            M = L_M[id];
            N = L_N[id];
            act_word_count = N >> 2;
            y_word_count   = M;
            expected_mac   = (M >> 4) * (N >> 3) * 8;
            expected_tiles = (M >> 4) * (N >> 6);

            $display("\n--- Layer %0d (%0s) M=%0d N=%0d act_w=%0d y_w=%0d ---",
                     id, L_DIR[id], M, N, act_word_count, y_word_count);

            // Build paths from layer dir name and read TV files
            $sformat(act_path, "%0s/%0s/act.hex",   `TV_DIR, L_DIR[id]);
            $sformat(ref_path, "%0s/%0s/y_ref.hex", `TV_DIR, L_DIR[id]);
            $readmemh(act_path, act_words);
            $readmemh(ref_path, y_ref);

            // Stage activations into ACT_BUF
            for (i = 0; i < act_word_count; i = i + 1)
                icb_write(REG_ACT_BASE + i*4, act_words[i]);

            // Select layer and pulse start
            icb_write(REG_LAYER_ID, id);
            icb_write(REG_SHIFT, 32'd14);
            icb_write(REG_CTRL,  32'd1);

            // Wait until done
            wait_done();

            // Snapshot perf counters
            icb_read(REG_CNT_TOTAL, cnt_total_obs);
            icb_read(REG_CNT_MAC,   cnt_mac_obs);
            icb_read(REG_CNT_STALL, cnt_stall_obs);
            icb_read(REG_CNT_TILES, cnt_tiles_obs);

            // Read Y_BUF and compare bit-exact vs golden
            mismatches = 0;
            for (i = 0; i < y_word_count; i = i + 1) begin
                icb_read(REG_Y_BASE + i*4, rdata);
                if (rdata !== y_ref[i]) begin
                    if (mismatches < 8)
                        $display("  MISMATCH row=%0d  got=%h  ref=%h", i, rdata, y_ref[i]);
                    mismatches = mismatches + 1;
                end
            end

            if (cnt_mac_obs !== expected_mac) begin
                $display("  MISMATCH CNT_MAC obs=%0d expected=%0d", cnt_mac_obs, expected_mac);
                mismatches = mismatches + 1;
            end
            if (cnt_tiles_obs !== expected_tiles) begin
                $display("  MISMATCH CNT_TILES obs=%0d expected=%0d", cnt_tiles_obs, expected_tiles);
                mismatches = mismatches + 1;
            end

            if (mismatches == 0) begin
                $display("  PASS  total=%0d mac=%0d stall=%0d tiles=%0d",
                         cnt_total_obs, cnt_mac_obs, cnt_stall_obs, cnt_tiles_obs);
                layer_pass = layer_pass + 1;
            end else begin
                $display("  LAYER FAIL: %0d mismatches", mismatches);
                layer_fail   = layer_fail + 1;
                errors_total = errors_total + mismatches;
            end
        end
    endtask

    // ------------------------------- Main -----------------------------------
    initial begin
        // Layer descriptor table (matches test_vectors/w4a8_engine/descriptors.txt)
        L_M[0]=384; L_N[0]=128; L_WBASE[0]=0;    L_SBASE[0]=0;
        L_M[1]=128; L_N[1]=128; L_WBASE[1]=384;  L_SBASE[1]=192;
        L_M[2]=256; L_N[2]=128; L_WBASE[2]=512;  L_SBASE[2]=256;
        L_M[3]=128; L_N[3]=256; L_WBASE[3]=768;  L_SBASE[3]=384;
        L_M[4]=384; L_N[4]=128; L_WBASE[4]=1024; L_SBASE[4]=448;
        L_M[5]=128; L_N[5]=128; L_WBASE[5]=1408; L_SBASE[5]=640;
        L_M[6]=256; L_N[6]=128; L_WBASE[6]=1536; L_SBASE[6]=704;
        L_M[7]=128; L_N[7]=256; L_WBASE[7]=1792; L_SBASE[7]=832;
        L_M[8]= 64; L_N[8]=128; L_WBASE[8]=2048; L_SBASE[8]=896;
        L_DIR[0] = "id0_layer0_qkv";
        L_DIR[1] = "id1_layer0_proj";
        L_DIR[2] = "id2_layer0_ffn_up";
        L_DIR[3] = "id3_layer0_ffn_down";
        L_DIR[4] = "id4_layer1_qkv";
        L_DIR[5] = "id5_layer1_proj";
        L_DIR[6] = "id6_layer1_ffn_up";
        L_DIR[7] = "id7_layer1_ffn_down";
        L_DIR[8] = "id8_lm_head";

        layer_pass   = 0;
        layer_fail   = 0;
        errors_total = 0;

        // Reset
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Resident memories are initialized by w4a8_resident_wmem/smem.
        $display("INFO: using RTL resident-memory $readmemh initialization");

        // Descriptors via ICB (validates that path)
        write_all_descriptors();

        $display("\n========== tb_w4a8_single_layer (layer 1) ==========");
        run_layer(1);

        $display("\n========== tb_w4a8_multicol (layer 3, N=256) ==========");
        run_layer(3);

        $display("\n========== tb_w4a8_nine_layers (layers 0,2,4..8) ==========");
        run_layer(0);
        run_layer(2);
        run_layer(4);
        run_layer(5);
        run_layer(6);
        run_layer(7);
        run_layer(8);

        $display("\n=====================================================");
        if (layer_fail == 0 && errors_total == 0)
            $display(" ENGINE TB ALL PASS  (%0d / 9 layers)", layer_pass);
        else
            $display(" ENGINE TB FAIL: %0d layers failed, %0d mismatches total",
                     layer_fail, errors_total);
        $display("=====================================================\n");
        $finish;
    end

    // Watchdog (very generous — biggest layer ~5K cycles, 9 layers + ICB load < 1ms)
    initial begin
        #50_000_000;  // 50 ms sim time
        $display("FAIL: simulation watchdog timeout");
        $finish;
    end

endmodule
