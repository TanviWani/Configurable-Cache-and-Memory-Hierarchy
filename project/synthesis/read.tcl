#------------------------------------------------------------
#
# Basic Synthesis Script (TCL format)
#                                  
# Revision History                
#   1/15/03  : Author Shane T. Gehring - from class example
#   2/09/07  : Author Zhengtao Yu      - from class example
#   12/14/07 : Author Ravi Jenkal      - updated to 180 nm & tcl
#
#------------------------------------------------------------

#---------------------------------------------------------
# Read in Verilog file and map (synthesize) onto a generic
# library.
# MAKE SURE THAT YOU CORRECT ALL WARNINGS THAT APPEAR
# during the execution of the read command are fixed 
# or understood to have no impact.
# ALSO CHECK your latch/flip-flop list for unintended 
# latches                                            
#---------------------------------------------------------

#read_verilog -rtl $::env(RTL_FILES)
#read_sverilog -rtl $::env(RTL_SV_FILES)
if {[info exists ::env(RTL_SV_DEFINES)]} {
  analyze -format sverilog -define [split $::env(RTL_SV_DEFINES)] $::env(RTL_SV_FILES)
} else {
  analyze -format sverilog $::env(RTL_SV_FILES)
}
elaborate $modname

if {[info exists ::env(SRAM_PATH)] && $::env(SRAM_PATH) ne ""} {
  link
  set sram_cells [get_cells -hierarchical -filter "ref_name =~ sram_*x32_1r*"]
  if {[sizeof_collection $sram_cells] == 0} {
    error "SRAM DUT has no linked SRAM macro instances"
  }
  set_dont_touch $sram_cells true
}
