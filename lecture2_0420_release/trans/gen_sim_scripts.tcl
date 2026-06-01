open_project D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/trans/trans.xpr
set_property -name {top} -value {tb} -objects [get_filesets sim_1]
set_property -name {top_auto_set} -value {0} -objects [get_filesets sim_1]
launch_simulation -scripts_only -mode behavioral
puts "SCRIPTS_GENERATED_OK"
quit
