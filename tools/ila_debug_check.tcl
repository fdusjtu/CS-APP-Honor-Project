set bit_file [file normalize "lecture2_0420_release/trans/trans.runs/impl_1/system.bit"]
set ltx_file [file normalize "lecture2_0420_release/trans/trans.runs/impl_1/system.ltx"]
set out_dir  [file normalize "tmp/ila_debug"]
file mkdir $out_dir

puts "BIT=$bit_file"
puts "LTX=$ltx_file"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set devs [get_hw_devices]
puts "HW_DEVICES=$devs"

set dev [lindex [get_hw_devices xczu3_0] 0]
if {$dev eq ""} {
    set dev [lindex $devs 0]
}
current_hw_device $dev
puts "CURRENT_DEVICE=$dev"

if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file $dev
}
refresh_hw_device $dev

set ilas [get_hw_ilas]
puts "HW_ILAS=$ilas"

foreach ila $ilas {
    puts ""
    puts "ILA=$ila"
    puts "  CELL=[get_property CELL_NAME $ila]"
    set probes [get_hw_probes -of_objects $ila]
    foreach p $probes {
        puts "  PROBE=$p NAME=[get_property NAME $p] WIDTH=[get_property WIDTH $p]"
    }
}

set target_ila ""
foreach ila $ilas {
    foreach p [get_hw_probes -of_objects $ila] {
        set pname [get_property NAME $p]
        if {[string match "*mem_icb_cmd_addr*" $pname] || [string match "*probe0*" $pname]} {
            set target_ila $ila
            set addr_probe $p
            break
        }
    }
    if {$target_ila ne ""} { break }
}

if {$target_ila eq ""} {
    puts "NO_TARGET_ILA_WITH_ADDR_PROBE"
    exit 0
}

puts ""
puts "TARGET_ILA=$target_ila"
puts "ADDR_PROBE=$addr_probe NAME=[get_property NAME $addr_probe]"

# First prove the ILA/bus path using current GEMV demo firmware:
# main.c writes GEMV_W_REG(0) at 0x10041010 early in hw_gemv().
set_property CONTROL.TRIGGER_POSITION 256 $target_ila
set_property TRIGGER_COMPARE_VALUE eq32'h10041010 $addr_probe
run_hw_ila $target_ila

set wait_rc [catch {wait_on_hw_ila -timeout 20 $target_ila} wait_msg]
puts "WAIT_RC=$wait_rc"
puts "WAIT_MSG=$wait_msg"

set final_status [get_property CORE_STATUS $target_ila]
puts "FINAL_STATUS=$final_status"

set csv_file [file join $out_dir "gemv_addr_10041010.csv"]
if {$wait_rc == 0} {
    write_hw_ila_data -csv_file -force $csv_file [upload_hw_ila_data $target_ila]
    puts "WROTE_CSV=$csv_file"
} else {
    puts "NO_TRIGGER_WITHIN_20S"
}
