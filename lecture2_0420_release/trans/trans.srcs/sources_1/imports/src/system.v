`timescale 1ns/1ps

module system
(
  input wire CLK200MHZ_P,
  input wire CLK200MHZ_N,
  input wire fpga_rst,
  input wire uart0_rxd,
  output wire uart0_txd
);

  wire mmcm_locked;
  wire ck_rst;
  wire cpu_rst_n;
  reg  [19:0] por_cnt = 20'b0;
  reg         por_done = 1'b0;
  //=================================================
  // Clock & Reset

  wire clk_16M;

  wire CLK32768KHZ;
  
  clk_div u_clk_div(
    .clk(clk_16M),
    .rst_n(cpu_rst_n),
    .clk_div(CLK32768KHZ)
  );
  
  mmcm ip_mmcm
  (
    .resetn(1'b1),
    .clk_in1_p(CLK200MHZ_P),
    .clk_in1_n(CLK200MHZ_N),
    .clk_out1(clk_16M), // 16 MHz, this clock we set to 16MHz 
    .locked(mmcm_locked)
  );

  always @(posedge clk_16M) begin
    if (!mmcm_locked) begin
      por_cnt  <= 20'b0;
      por_done <= 1'b0;
    end else if (!por_done) begin
      por_cnt  <= por_cnt + 1'b1;
      por_done <= &por_cnt;
    end
  end

  assign ck_rst    = fpga_rst;
  assign cpu_rst_n = mmcm_locked & por_done;

  wire [31:0] gpioA_i_ival;
  wire [31:0] gpioA_o_oval;
  wire [31:0] gpioA_o_oe;

  assign gpioA_i_ival = {14'b0, 1'b1, uart0_rxd, 16'b0};
  assign uart0_txd = gpioA_o_oe[17] ? gpioA_o_oval[17] : 1'b1;


  e203_soc_top dut
  (
    .hfextclk(clk_16M),
    .hfxoscen(),

    .lfextclk(CLK32768KHZ), 
    .lfxoscen(),

       // Note: this is the real SoC top AON domain slow clock
    .io_pads_jtag_TCK_i_ival(),
    .io_pads_jtag_TMS_i_ival(),
    .io_pads_jtag_TDI_i_ival(),
    .io_pads_jtag_TDO_o_oval(),
    .io_pads_jtag_TDO_o_oe  (),

    .io_pads_gpioA_i_ival(gpioA_i_ival),
    .io_pads_gpioA_o_oval(gpioA_o_oval),
    .io_pads_gpioA_o_oe  (gpioA_o_oe),

    .io_pads_gpioB_i_ival(),
    .io_pads_gpioB_o_oval(),
    .io_pads_gpioB_o_oe  (),

    .io_pads_qspi0_sck_o_oval (),
    .io_pads_qspi0_cs_0_o_oval(),
    .io_pads_qspi0_dq_0_i_ival(),
    .io_pads_qspi0_dq_0_o_oval(),
    .io_pads_qspi0_dq_0_o_oe  (),
    .io_pads_qspi0_dq_1_i_ival(),
    .io_pads_qspi0_dq_1_o_oval(),
    .io_pads_qspi0_dq_1_o_oe  (),
    .io_pads_qspi0_dq_2_i_ival(),
    .io_pads_qspi0_dq_2_o_oval(),
    .io_pads_qspi0_dq_2_o_oe  (),
    .io_pads_qspi0_dq_3_i_ival(),
    .io_pads_qspi0_dq_3_o_oval(),
    .io_pads_qspi0_dq_3_o_oe  (),

       // Note: this is the real SoC top level reset signal
    .io_pads_aon_erst_n_i_ival(cpu_rst_n),
    .io_pads_aon_pmu_dwakeup_n_i_ival(),

    .io_pads_aon_pmu_vddpaden_o_oval(),
    .io_pads_aon_pmu_padrst_o_oval    ( ),

    .io_pads_bootrom_n_i_ival       (1'b0),
    .io_pads_dbgmode0_n_i_ival       (1'b1),
    .io_pads_dbgmode1_n_i_ival       (1'b1),
    .io_pads_dbgmode2_n_i_ival       (1'b1)
  );




endmodule
