set_property PACKAGE_PIN AE5 [get_ports CLK200MHZ_P]
set_property PACKAGE_PIN AF5 [get_ports CLK200MHZ_N]
set_property PACKAGE_PIN AF12 [get_ports fpga_rst]
set_property PACKAGE_PIN AH12 [get_ports uart0_txd]
set_property PACKAGE_PIN AH11 [get_ports uart0_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_rst]
set_property IOSTANDARD LVCMOS33 [get_ports uart0_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart0_rxd]
set_property PULLUP true [get_ports uart0_rxd]


set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK200MHZ_P]
set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK200MHZ_N]

