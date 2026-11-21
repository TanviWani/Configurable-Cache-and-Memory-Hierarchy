add wave -noupdate -group tb sim:/tb/*
add wave -noupdate -group dut sim:/tb/dut_inst/*
add wave -noupdate -group l1  sim:/tb/dut_inst/u_l1/*
add wave -noupdate -group l2  sim:/tb/dut_inst/g_l2/u_l2/*
run -all
