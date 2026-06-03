# Run the W4A8 Linear Engine testbench end-to-end in Vivado XSIM.
#
# Usage (any of these):
#   - Vivado GUI Tcl console:  source D:/.../trans/run_engine_tb.tcl
#   - Vivado batch:            vivado -mode batch -source run_engine_tb.tcl
#
# Output:
#   PASS/FAIL lines per layer in the Tcl console, plus a final summary.
#   Full log: trans/run_engine_tb.log

open_project D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/trans/trans.xpr

# Make sure the 5 new RTL files and the TB are in the project filesets.
# `add_files` is idempotent for files already in the project.
set src_dir D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/trans/trans.srcs/sources_1/new
set sim_dir D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/trans/trans.srcs/sim_1/new
add_files -quiet -fileset sources_1 \
    $src_dir/w4a8_resident_wmem.v \
    $src_dir/w4a8_resident_smem.v \
    $src_dir/w4a8_core.v \
    $src_dir/w4a8_icb.v \
    $src_dir/w4a8_linear_engine.v
add_files -quiet -fileset sim_1 $sim_dir/tb_w4a8_engine.v
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Pick the engine TB as sim top
set_property -name {top}           -value {tb_w4a8_engine} -objects [get_filesets sim_1]
set_property -name {top_auto_set}  -value {0}              -objects [get_filesets sim_1]

# Disable Vivado's "auto-run for runtime" so we control with `run -all`
set_property -name {xsim.simulate.runtime} -value {0us} -objects [get_filesets sim_1]

# Launch
launch_simulation -mode behavioral

# Run until $finish in TB (TB has its own watchdog at 50 ms sim time)
run -all

puts "=== run_engine_tb.tcl: simulation finished ==="
