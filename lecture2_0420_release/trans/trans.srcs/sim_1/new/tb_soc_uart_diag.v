`timescale 1ns/1ps

module tb_soc_uart_diag;
  reg clk_p;
  reg clk_n;
  reg rst_n;
  wire uart0_txd;

  integer tx_edges;
  integer uart_writes;
  integer w4a8_writes;
  integer pc_changes;
  reg last_txd;
  reg [31:0] last_pc;

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
    rst_n = 1'b0;
    tx_edges = 0;
    uart_writes = 0;
    w4a8_writes = 0;
    pc_changes = 0;
    last_txd = 1'b1;
    last_pc = 32'hffff_ffff;

    $display("[%0t] TB start", $time);
    #500 rst_n = 1'b1;
    @(posedge dut.mmcm_locked);
    repeat (16) @(posedge dut.clk_16M);
    force dut.por_done = 1'b1;
    force dut.por_cnt = 20'hfffff;
    $display("[%0t] TB forced POR done for fast simulation", $time);
    #10000000;
    $display("[%0t] SUMMARY mmcm_locked=%0b por_done=%0b cpu_rst_n=%0b pc=%08x tx_edges=%0d uart_writes=%0d w4a8_writes=%0d gpio_oe17=%0b gpio_oval17=%0b uart0_txd=%0b",
             $time,
             dut.mmcm_locked,
             dut.por_done,
             dut.cpu_rst_n,
             dut.dut.inspect_pc_pass,
             tx_edges,
             uart_writes,
             w4a8_writes,
             dut.gpioA_o_oe[17],
             dut.gpioA_o_oval[17],
             uart0_txd);
    $finish;
  end

  always #2.5 clk_p = ~clk_p;
  always #2.5 clk_n = ~clk_n;

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
      if (tx_edges <= 64) begin
        $display("[%0t] UART TX edge -> %0b oe17=%0b oval17=%0b",
                 $time, uart0_txd, dut.gpioA_o_oe[17], dut.gpioA_o_oval[17]);
      end
    end
  end
endmodule
