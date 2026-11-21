cmake_minimum_required(VERSION 3.26.5)
project(CacheHierarchyRTL NONE)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(TEST "-1" CACHE STRING "Test index; -1 runs all cases in inputs/")
set(UNITY_ID "your_id" CACHE STRING "ID used to name the submission tarball")
set(DC_CLOCK_PER "10.0" CACHE STRING "Synthesis clock period in ns")

# Geometry used for synthesis (and as the default of `dut`); simulation cases
# take their geometry from inputs/input<N>/config.json instead.
set(DUT_BLOCKSIZE "32"   CACHE STRING "Block size in bytes")
set(DUT_L1_SIZE   "1024" CACHE STRING "L1 size in bytes")
set(DUT_L1_ASSOC  "2"    CACHE STRING "L1 associativity")
set(DUT_L2_SIZE   "8192" CACHE STRING "L2 size in bytes (0 = no L2)")
set(DUT_L2_ASSOC  "4"    CACHE STRING "L2 associativity")
set(DUT_PREF_N    "2"    CACHE STRING "Stream buffers (0 = off), in the last level")
set(DUT_PREF_M    "4"    CACHE STRING "Blocks per stream buffer")

file(READ "${CMAKE_SOURCE_DIR}/student-config.json" CONFIG)
string(JSON FIRST GET "${CONFIG}" tests start)
string(JSON LAST GET "${CONFIG}" tests end)
if(NOT "${TEST}" MATCHES "^-?[0-9]+$")
  message(FATAL_ERROR "TEST must be -1 or a case index")
endif()
if(NOT "${TEST}" EQUAL -1 AND ("${TEST}" LESS FIRST OR "${TEST}" GREATER LAST))
  message(FATAL_ERROR "TEST must be -1 or in ${FIRST}..${LAST}")
endif()
string(JSON SUBMISSION GET "${CONFIG}" compress)
file(WRITE "${CMAKE_BINARY_DIR}/submission-config.json" "${SUBMISSION}")

add_custom_target(compress
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/student_compress.py"
    --root "${CMAKE_SOURCE_DIR}" --config "${CMAKE_BINARY_DIR}/submission-config.json"
    --id "${UNITY_ID}" --output-dir "${CMAKE_BINARY_DIR}" VERBATIM)

# Regenerate traces + golden reports (pure Python, no EDA tools needed).
add_custom_target(ref
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/gen_tests.py" VERBATIM)

option(ENABLE_HDL_TOOLS "Configure simulator and synthesis targets" ON)
if(NOT ENABLE_HDL_TOOLS)
  return()
endif()

find_program(VLOG vlog REQUIRED)
find_program(VSIM vsim REQUIRED)
find_program(VLIB vlib REQUIRED)
include("${CMAKE_SOURCE_DIR}/cmake/Questa.cmake")
configure_questa()

file(GLOB_RECURSE RTL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/srcs/rtl/*.sv" "${CMAKE_SOURCE_DIR}/srcs/rtl/*.v")

set(DEFINES
  +define+CFG_BLOCKSIZE=${DUT_BLOCKSIZE} +define+CFG_L1_SIZE=${DUT_L1_SIZE}
  +define+CFG_L1_ASSOC=${DUT_L1_ASSOC}   +define+CFG_L2_SIZE=${DUT_L2_SIZE}
  +define+CFG_L2_ASSOC=${DUT_L2_ASSOC}   +define+CFG_PREF_N=${DUT_PREF_N}
  +define+CFG_PREF_M=${DUT_PREF_M})

set(WORK "${CMAKE_BINARY_DIR}/dut")
set(LIBRARY "${WORK}/work")
file(MAKE_DIRECTORY "${WORK}")
configure_file("${QUESTA_ROOT}/modelsim.ini" "${WORK}/modelsim.ini" COPYONLY)

# Always compile when invoked so added RTL files are picked up.
add_custom_target(vlog-dut
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${LIBRARY}"
  COMMAND "${VLIB}" "${LIBRARY}"
  COMMAND "${VLOG}" -64 -sv -work "${LIBRARY}" ${DEFINES}
    "+incdir+${CMAKE_SOURCE_DIR}/srcs/rtl" "+incdir+${CMAKE_SOURCE_DIR}/srcs/tb"
    ${RTL} "${CMAKE_SOURCE_DIR}/srcs/tb/tb.sv"
  WORKING_DIRECTORY "${WORK}" VERBATIM)

set(RUNNER "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/run_tests.py" --sim questa
  --test ${TEST} --vsim "${VSIM}" --lib "${LIBRARY}" --ini "${WORK}/modelsim.ini"
  --workdir "${WORK}" --simout "${WORK}/outputs")

# batch: run the selected case(s) and compare with outputs/output<N>/expected.out
add_custom_target(vsim-dut-c COMMAND ${RUNNER} DEPENDS vlog-dut VERBATIM)
# GUI: first selected case, waveforms from do/waves.do
add_custom_target(vsim-dut COMMAND ${RUNNER} --gui DEPENDS vlog-dut VERBATIM)
# stress the request port with random idle cycles
add_custom_target(vsim-dut-bubble COMMAND ${RUNNER} --bubble 30 DEPENDS vlog-dut VERBATIM)

find_program(DC_SHELL dc_shell)
if(DC_SHELL)
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/dc" "${CMAKE_BINARY_DIR}/dc/svf")
  configure_file("${CMAKE_SOURCE_DIR}/synthesis/.synopsys_dc.setup" "${CMAKE_BINARY_DIR}/dc/.synopsys_dc.setup" COPYONLY)
  string(JOIN " " RTL_LIST ${RTL})
  set(SYNTH_DEFINES "CFG_BLOCKSIZE=${DUT_BLOCKSIZE} CFG_L1_SIZE=${DUT_L1_SIZE} CFG_L1_ASSOC=${DUT_L1_ASSOC} CFG_L2_SIZE=${DUT_L2_SIZE} CFG_L2_ASSOC=${DUT_L2_ASSOC} CFG_PREF_N=${DUT_PREF_N} CFG_PREF_M=${DUT_PREF_M}")
  foreach(dir reports gl sdf logs)
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/synth/${dir}")
  endforeach()
  add_custom_target(synth
    COMMAND "${CMAKE_COMMAND}" -E env "DC_CLOCK_PER=${DC_CLOCK_PER}"
      "OUTPUT_DIR=${CMAKE_BINARY_DIR}/synth" "RTL_FILES=" "RTL_SV_FILES=${RTL_LIST}"
      "RTL_SV_DEFINES=${SYNTH_DEFINES}" "MODULE_NAME=dut"
      "${DC_SHELL}" -no_gui -x
      "set_app_var search_path [concat {${CMAKE_SOURCE_DIR}/synthesis} [get_app_var search_path]]; source ${CMAKE_SOURCE_DIR}/synthesis/run_all.tcl"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/dc" VERBATIM)
else()
  add_custom_target(synth COMMAND "${CMAKE_COMMAND}" -E echo "dc_shell not found; source setup.sh and reconfigure"
    COMMAND "${CMAKE_COMMAND}" -E false VERBATIM)
endif()

# Summary of setup/hold slack, area, cells, cycles and total time (run after synth + vsim-dut-c)
add_custom_target(report
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/synth_report.py"
          --build "${CMAKE_BINARY_DIR}" --clk "${DC_CLOCK_PER}" VERBATIM)
