`timescale 1ns/1ps

module tb_soc_uart_diag;
  reg clk_p;
  reg clk_n;
  reg sim_clk16;
  reg rst_n;
  wire uart0_txd;

  integer tx_edges;
  integer uart_writes;
  integer w4a8_writes;
  integer pc_changes;
  integer full_soc;
  integer pass_idx;
  reg last_txd;
  reg [31:0] last_pc;
  reg full_pass_seen;

  function [7:0] full_pass_char;
    input integer idx;
    begin
      case (idx)
        0:  full_pass_char = 8'h46; // F
        1:  full_pass_char = 8'h55; // U
        2:  full_pass_char = 8'h4c; // L
        3:  full_pass_char = 8'h4c; // L
        4:  full_pass_char = 8'h20; // space
        5:  full_pass_char = 8'h42; // B
        6:  full_pass_char = 8'h4c; // L
        7:  full_pass_char = 8'h4f; // O
        8:  full_pass_char = 8'h43; // C
        9:  full_pass_char = 8'h4b; // K
        10: full_pass_char = 8'h20; // space
        11: full_pass_char = 8'h50; // P
        12: full_pass_char = 8'h41; // A
        13: full_pass_char = 8'h53; // S
        14: full_pass_char = 8'h53; // S
        default: full_pass_char = 8'h00;
      endcase
    end
  endfunction

  task observe_uart_byte;
    input [7:0] ch;
    begin
      if (ch == full_pass_char(pass_idx)) begin
        pass_idx = pass_idx + 1;
      end else if (ch == full_pass_char(0)) begin
        pass_idx = 1;
      end else begin
        pass_idx = 0;
      end

      if (pass_idx == 15) begin
        full_pass_seen = 1'b1;
        $display("[%0t] FULL BLOCK PASS seen on UART writes", $time);
        print_summary();
        $finish;
      end
    end
  endtask

  task print_summary;
    begin
      $display("[%0t] SUMMARY mmcm_locked=%0b por_done=%0b cpu_rst_n=%0b hfclkrst=%0b corerst=%0b pc_rtvec=%08x pc=%08x tx_edges=%0d uart_writes=%0d w4a8_writes=%0d block_busy=%0b block_done=%0b block_stage=%0d block_cnt=%0d core_busy=%0b core_done=%0b gpio_oe17=%0b gpio_oval17=%0b uart0_txd=%0b",
               $time,
               dut.mmcm_locked,
               dut.por_done,
               dut.cpu_rst_n,
               dut.dut.u_e203_subsys_top.hfclkrst,
               dut.dut.u_e203_subsys_top.corerst,
               dut.dut.u_e203_subsys_top.pc_rtvec,
               dut.dut.inspect_pc_pass,
               tx_edges,
               uart_writes,
               w4a8_writes,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.block_busy,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.block_done,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.block_stage,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.block_cnt,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.core_busy,
               dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_w4a8_engine.core_done,
               dut.gpioA_o_oe[17],
               dut.gpioA_o_oval[17],
               uart0_txd);
    end
  endtask

  system dut (
    .CLK200MHZ_P(clk_p),
    .CLK200MHZ_N(clk_n),
    .fpga_rst(rst_n),
    .uart0_rxd(1'b1),
    .uart0_txd(uart0_txd)
  );

  initial begin
    clk_p = 1'b1;
    clk_n = 1'b0;
    sim_clk16 = 1'b0;
    rst_n = 1'b0;
    tx_edges = 0;
    uart_writes = 0;
    w4a8_writes = 0;
    pc_changes = 0;
    full_soc = $test$plusargs("FULL_SOC");
    pass_idx = 0;
    last_txd = 1'b1;
    last_pc = 32'hffff_ffff;
    full_pass_seen = 1'b0;

    $display("[%0t] TB start full_soc=%0d", $time, full_soc);
    #500 rst_n = 1'b1;
    #100;
    force dut.clk_16M = sim_clk16;
    force dut.CLK32768KHZ = sim_clk16;
    force dut.mmcm_locked = 1'b1;
    $display("[%0t] TB forced 16MHz clock/MMCM lock for fast simulation", $time);
    #1000;
    force dut.por_done = 1'b1;
    force dut.por_cnt = 20'hfffff;
    force dut.dut.u_e203_subsys_top.hfclkrst = 1'b0;
    force dut.dut.u_e203_subsys_top.corerst = 1'b0;
    force dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.u_perips_apb_uart0.tx_ready = 1'b1;
    $display("[%0t] TB forced POR done for fast simulation", $time);
    if (full_soc) begin
      repeat (20) begin
        #10000000;
        $display("[%0t] FULL_SOC heartbeat", $time);
        print_summary();
      end
      $display("[%0t] FULL_SOC timeout full_pass_seen=%0b", $time, full_pass_seen);
    end else begin
      #2000000;
    end
    print_summary();
    $finish;
  end

  always #2.5 clk_p = ~clk_p;
  always #2.5 clk_n = ~clk_n;
  always #31.25 sim_clk16 = ~sim_clk16;

  always @(posedge dut.clk_16M) begin
    if (dut.mmcm_locked && dut.por_done && (dut.dut.inspect_pc_pass !== last_pc)) begin
      pc_changes = pc_changes + 1;
      last_pc = dut.dut.inspect_pc_pass;
      if (pc_changes <= 32) begin
        $display("[%0t] PC %08x", $time, dut.dut.inspect_pc_pass);
      end
    end

    if (dut.cpu_rst_n &&
        dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_valid &&
        dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_ready) begin
      uart_writes = uart_writes + (!dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_read);
      if (!dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_read && uart_writes <= 32) begin
        $display("[%0t] UART ICB write addr=%08x data=%08x wmask=%x",
                 $time,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_addr,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_wdata,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_wmask);
      end
      if (!dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_read &&
          dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_addr == 32'h1001_3000) begin
        observe_uart_byte(dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.uart0_apb_icb_cmd_wdata[7:0]);
      end
    end

    if (dut.cpu_rst_n &&
        dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_valid &&
        dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_ready &&
        !dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_read) begin
      w4a8_writes = w4a8_writes + 1;
      if (w4a8_writes <= 32) begin
        $display("[%0t] W4A8 ICB write addr=%08x data=%08x wmask=%x",
                 $time,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_addr,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_wdata,
                 dut.dut.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips.expl_axi_icb_cmd_wmask);
      end
      if (!full_soc && w4a8_writes == 8) begin
        print_summary();
        $finish;
      end
    end
  end

  always @(posedge dut.mmcm_locked) begin
    $display("[%0t] MMCM locked", $time);
  end

  always @(posedge dut.por_done) begin
    $display("[%0t] POR done", $time);
  end

  always @(posedge dut.cpu_rst_n) begin
    $display("[%0t] CPU reset released", $time);
  end

  always @(uart0_txd) begin
    if (uart0_txd !== last_txd) begin
      tx_edges = tx_edges + 1;
      last_txd = uart0_txd;
      if (!full_soc && tx_edges <= 64) begin
        $display("[%0t] UART TX edge -> %0b oe17=%0b oval17=%0b",
                 $time, uart0_txd, dut.gpioA_o_oe[17], dut.gpioA_o_oval[17]);
      end
    end
  end
endmodule
