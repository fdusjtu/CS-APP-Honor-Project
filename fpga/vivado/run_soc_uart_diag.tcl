set origin_dir [file dirname [info script]]
open_project [file join $origin_dir trans.xpr]

set old_top [get_property top [get_filesets sim_1]]
set old_source_mgmt_mode [get_property source_mgmt_mode [current_project]]
set tb_file [file normalize [file join $origin_dir trans.srcs sim_1 new tb_soc_uart_diag.v]]

if {[llength [get_files -quiet $tb_file]] == 0} {
  add_files -fileset sim_1 $tb_file
}

set_property source_mgmt_mode None [current_project]
set_property top tb_soc_uart_diag [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
run 20 ms

close_sim

if {$old_top ne ""} {
  set_property top $old_top [get_filesets sim_1]
}
if {$old_source_mgmt_mode ne ""} {
  set_property source_mgmt_mode $old_source_mgmt_mode [current_project]
}
close_project
