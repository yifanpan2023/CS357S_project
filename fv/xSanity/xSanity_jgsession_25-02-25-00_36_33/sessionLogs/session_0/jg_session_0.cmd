# ----------------------------------------
# Jasper Version Info
# tool      : Jasper 2023.12
# platform  : Linux 3.10.0-1160.el7.x86_64
# version   : 2023.12p001 64 bits
# build date: 2024.01.23 16:09:24 UTC
# ----------------------------------------
# started   : 2025-02-25 00:36:36 PST
# hostname  : cafe-jg.stanford.edu.(none)
# pid       : 14110
# arguments : '-label' 'session_0' '-console' '//127.0.0.1:45497' '-style' 'windows' '-data' 'AAABPHichY+9CsJAEIS/+ANiZekj2ESDIWKRwsZOERXSBok/GMQEI6I2+qi+SRwTIsTGhd2Znbu53TMA95GmKVlU7yotJkxZMFad4QmhjUOfIRYjAlasObAXs3Kf8coR16Acn75SVubPEkK9MBdXasoGJltiLuIdriw19aiZZ270fnqfrjDQTtCUL+ZERKjO++sM2ZGwUSbSIp34+qmjVyyh+eWWdJtBVu1syzcALieF' '-proj' '/sailhome/yifanpan/CS357S_project/fv/xSanity/xSanity_jgsession_25-02-25-00_36_33/sessionLogs/session_0' '-init' '-hidden' '/sailhome/yifanpan/CS357S_project/fv/xSanity/xSanity_jgsession_25-02-25-00_36_33/.tmp/.initCmds.tcl' 'xSanity/xSanity_.tcl'
# Run JG with a TCl file: jg jg_test.tcl
set assert_report_incompletes 1
set RTL_DIR /sailhome/yifanpan/CS357S_project/cva6
set SRCDIR /sailhome/yifanpan/CS357S_project/cva6/core

############
set FPV 1
set REACH 0
set CUSTOMTCL 0
############
exec xSanity/xSanity_update_file_.sh
# Analyze RTL files
analyze -sv09 -f xSanity/xSanity_hdls.f -y $SRCDIR +incdir+$SRCDIR

if {$REACH == 1} {
    puts "test bboxing mfpt" 
    #elaborate -bbox_m  {miss_prediction_fix_table} -bbox_m {reorderbuf}
    elaborate 
    source reach_collect.tcl
}
if {$FPV == 1} {
    puts "fpv" 
    # Elaborates
    #elaborate -bbox_m {wt_cache_subsystem} -bbox_m {frontend}
    #puts "multiplier no-bbox"
    elaborate -bbox_m {frontend}
    #elaborate -bbox_m {frontend}
    #stopat -env {issue_stage_i.i_scoreboard.mem_n[0].sbe.is_compressed}  
    #elaborate


    # Initialization
    # Clock specification
    clock clk_i
    # -both_edges: ridecore 
    reset !rst_ni
    set_proofgrid_per_engine_max_jobs 10
    set_proofgrid_max_jobs 30


    #SOURCE_TCL
    # assume -enable {.*ASSUME_W_R} -regexp
    # assume -disable {.*ASSUME_R_W} -regexp

    task -create mytask -copy_assumes   -regexp
    task -set mytask

    if { $CUSTOMTCL == 1 } {
        puts "=========CUSTOMTCL========="

        #CUSTOMTCL
        
        puts "=========EXIT CUSTOMTCL========="
        ## #exit
        
    } 
    
    puts "=============================================================="
    puts "CHECK ASSUMPTION...."
    puts "=============================================================="
    set CA 0
    set CA 1
    #
    set_prove_time_limit 15m
    #SETPROVETIME
    set_prove_per_property_time_limit 5m 

    set ls [get_property_list -task mytask -include {type {assert cover} }]
    if { [llength $ls] > 10 } { 
        set_prove_time_limit 25m 
        puts "PROVEN TIME 25min" }  

    if { $CA == 1 } { 
        #set_prove_time_limit 10m
        set CONFLICT [check_assumptions -task mytask -conflict]
        puts "=============================================================="
        puts "CHECK ASSUMPTION CONFLICT result? $CONFLICT"
        puts "=============================================================="
    }  else {
        puts "AUTOPROVE:" 
        #set_prove_time_limit 1h
        #set_prove_per_property_time_limit 1h
        puts "=================================================="
        puts " PROVE TIME LIMIT"
        puts [get_prove_time_limit]     
        #puts [get_prove_per_property_time_limit]
        puts "=================================================="
        set_engine_mode {K C Tri I N AD AM Hp B}

        prove -task mytask
        #prove -all
    }
    
    puts "END"
    report -task mytask -csv -results -file "xSanity/xSanity.csv" -force
    ## #exit
}

