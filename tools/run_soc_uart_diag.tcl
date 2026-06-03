set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ".."]]
set proj_path [file join $repo_root "fpga" "trans" "trans.xpr"]
set tb_path [file join $repo_root "fpga" "trans" "trans.srcs" "sim_1" "new" "tb_soc_uart_diag.v"]

if {[info exists ::env(FULL_SOC)] && $::env(FULL_SOC) == "1"} {
  set full_soc 1
} else {
  set full_soc 0
}

if {[info exists ::env(SOC_SIM_DRY_RUN)] && $::env(SOC_SIM_DRY_RUN) == "1"} {
  set dry_run 1
} else {
  set dry_run 0
}

open_project $proj_path

set stale [get_files -quiet *w4a8_linear_engine.v]
if {[llength $stale] > 0} {
  remove_files $stale
}

if {[llength [get_files -quiet $tb_path]] == 0} {
  add_files -fileset sim_1 $tb_path
}

set_property top tb_soc_uart_diag [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

if {$full_soc} {
  set_property -name xsim.simulate.xsim.more_options -value {-testplusarg FULL_SOC} -objects [get_filesets sim_1]
  puts "Running tb_soc_uart_diag in FULL_SOC mode"
} else {
  set_property -name xsim.simulate.xsim.more_options -value {} -objects [get_filesets sim_1]
  puts "Running tb_soc_uart_diag in sanity mode"
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

if {$dry_run} {
  puts "SOC simulation dry run complete"
  close_project
  return
}

launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
