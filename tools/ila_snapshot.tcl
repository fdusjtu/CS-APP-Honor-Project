set ltx_file [file normalize "lecture2_0420_release/trans/trans.runs/impl_1/system.ltx"]
set out_dir  [file normalize "tmp/ila_debug"]
file mkdir $out_dir

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xczu3_0] 0]
if {$dev eq ""} {
    set dev [lindex [get_hw_devices] 0]
}
current_hw_device $dev
if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file $dev
}
refresh_hw_device $dev

foreach ila [get_hw_ilas] {
    puts "SNAPSHOT_ILA=$ila CELL=[get_property CELL_NAME $ila]"
    set_property CONTROL.TRIGGER_POSITION 16 $ila
    set rc [catch {run_hw_ila -trigger_now $ila} msg]
    puts "RUN_TRIGGER_NOW_RC=$rc MSG=$msg"
    if {$rc != 0} {
        continue
    }
    after 3000
    set data_rc [catch {upload_hw_ila_data $ila} data_obj]
    puts "UPLOAD_RC=$data_rc OBJ=$data_obj"
    if {$data_rc == 0} {
        set csv_file [file join $out_dir "[get_property NAME $ila]_snapshot.csv"]
        write_hw_ila_data -csv_file -force $csv_file $data_obj
        puts "WROTE_CSV=$csv_file"
    }
}
