# Configurable Cache and Memory Hierarchy 

## Overview

A synthesizable SystemVerilog implementation of a configurable cache hierarchy featuring an L1 cache, optional L2 cache, and stream-buffer-based prefetching.

The design models cache behavior using trace-driven memory requests and supports configurable block sizes, cache capacities, associativity, and prefetch parameters.

Each cache level implements tag lookup, hit/miss detection, LRU replacement, dirty-bit tracking, and write-back/write-allocate behavior. A stream-buffer prefetching mechanism is integrated into the last-level cache to exploit spatial locality and reduce subsequent memory misses.

The architecture is parameterized to support both single-level and two-level cache configurations.

## Key Features

- Configurable L1 and optional L2 cache hierarchy.
- Parameterized cache block size, capacity, and associativity.
- Write-back and write-allocate cache policy.
- LRU replacement implemented using move-to-front ordering.
- Dirty-victim write-back handling on cache misses.
- Stream-buffer-based prefetching in the last-level cache.
- Support for direct-mapped, set-associative, and fully associative configurations.
- Valid-bit, dirty-bit, and cache-counter tracking.
- Trace-driven verification against a Python reference model.
- Design Compiler synthesis and timing analysis.

## Architecture

```text
                  Memory Request
                        |
                        v
                  +-----------+
                  |   L1      |
                  |   Cache   |
                  +-----------+
                        |
              +---------+---------+
              |                   |
           L1 Only             L1 + L2
              |                   |
              v                   v
       Main Memory          +-----------+
       Interface            |    L2     |
                            |   Cache   |
                            +-----------+
                                  |
                                  v
                           Main Memory
                           Interface
```

The stream buffer is instantiated in the last-level cache:

- In an L1-only configuration, prefetching is implemented in L1.
- In an L1+L2 configuration, prefetching is implemented in L2.
- Prefetching can be disabled through the `PREF_N` parameter.

### Cache-Level Microarchitecture

Each cache level uses a two-stage request pipeline:

1. **S0 – Request Acceptance:** Accepts a request through the valid-ready interface and registers the tag and set index.
2. **S1 – Cache Evaluation:** Performs tag comparison, hit detection, victim selection, stream-buffer lookup, replacement updates, and miss handling.

On a miss, a dirty victim is written back before the requested block is fetched from the lower level. The request controller uses a two-phase mechanism to sequence these operations.

### Replacement and Prefetching

- Each cache set maintains entries in MRU-to-LRU order.
- The least-recently-used entry is selected as the replacement victim.
- Valid and dirty bits track cache-line state.
- Stream buffers track sequential block streams using their head block and valid state.
- Multiple stream-buffer matches are resolved using the most-recently-used buffer.

The design models cache metadata and block addresses rather than storing actual cache-line data.

## Repository Structure

```text
project/
├── srcs/
│   ├── rtl/
│   │   ├── dut.sv
│   │   └── cache_level.sv
│   └── tb/
│       └── tb.sv
│
├── inputs/
│   ├── input0/
│   │   ├── config.json
│   │   └── trace.txt
│   ├── input1/
│   └── ...
│
├── outputs/
│   ├── output0/
│   │   └── expected.out
│   ├── output1/
│   └── ...
│
├── scripts/
│   ├── ref_cache.py
│   ├── gen_tests.py
│   ├── run_tests.py
│   ├── synth_report.py
│   └── student_compress.py
│
├── synthesis/
│   ├── CompileAnalyze.tcl
│   ├── Constraints.tcl
│   ├── CheckLatches.tcl
│   └── run_all.tcl
│
├── cmake/
│   └── Questa.cmake
├── do/
│   └── waves.do
├── CMakeLists.txt
├── CMakePresets.json
└── setup.sh
```

### Important RTL Modules

| Module           | Description                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------ |
| `dut.sv`         | Top-level hierarchy integrating L1, optional L2, request routing, and performance counters                   |
| `cache_level.sv` | Parameterized cache-level implementation containing lookup, replacement, write-back, and stream-buffer logic |
| `tb.sv`          | Trace-driven testbench that drives requests and generates cache-state and counter reports                    |
| `ref_cache.py`   | Python reference model used for functional comparison                                                        |
| `run_tests.py`   | Runs simulation cases and compares DUT reports against expected outputs                                      |

## Technology Stack

- **HDL:** SystemVerilog
- **Simulation:** Siemens Questa / ModelSim
- **Synthesis:** Synopsys Design Compiler
- **Verification:** Python reference model and trace-driven testbench
- **Build System:** CMake
- **Scripting:** Python, Bash, Tcl
- **Design Concepts:** Cache hierarchy, LRU replacement, write-back/write-allocate, stream-buffer prefetching, valid-ready handshaking, pipelined control logic

## Getting Started

### Prerequisites

- Linux environment
- CMake 3.26.5 or later
- Python 3
- Siemens Questa 2026.1
- Synopsys Design Compiler Y-2026.03

The provided `setup.sh` loads the configured course tool versions.

### 1. Configure the Environment

```bash
cd project
source setup.sh
```

### 2. Configure the Build

```bash
mkdir -p build
cd build
cmake .. --preset run
```

The `run` preset configures the build to execute all available test cases.

### 3. Run Functional Simulation

For batch simulation:

```bash
cmake --build . --target vsim-dut-c
```

For GUI-based simulation:

```bash
cmake --build . --target vsim-dut
```

To run the testbench with random idle cycles on the request interface:

```bash
cmake --build . --target vsim-dut-bubble
```

### 4. Run an Individual Test

For example, to execute test case 3:

```bash
cmake .. -DTEST=3
cmake --build . --target vsim-dut-c
```

Alternatively, configure directly using the available preset:

```bash
cmake .. --preset test3
cmake --build . --target vsim-dut-c
```

### 5. Run Synthesis

```bash
cmake --build . --target synth
```

Synthesis reports are generated under:

```text
build/synth/reports/
```

### 6. Generate a Summary Report

After running simulation and synthesis:

```bash
cmake --build . --target report
```

The report summarizes available simulation and synthesis metrics, including area and timing information.

## Configuration

The cache geometry can be configured through CMake variables:

| Parameter       | Description                                        |
| --------------- | -------------------------------------------------- |
| `DUT_BLOCKSIZE` | Cache block size in bytes                          |
| `DUT_L1_SIZE`   | L1 cache capacity in bytes                         |
| `DUT_L1_ASSOC`  | L1 associativity                                   |
| `DUT_L2_SIZE`   | L2 cache capacity in bytes; `0` disables L2        |
| `DUT_L2_ASSOC`  | L2 associativity                                   |
| `DUT_PREF_N`    | Number of stream buffers; `0` disables prefetching |
| `DUT_PREF_M`    | Number of blocks per stream buffer                 |

For example, to configure an L1-only hierarchy with prefetching disabled:

```bash
cmake .. --preset run -DDUT_L2_SIZE=0 -DDUT_PREF_N=0
```

Simulation geometry is loaded from each test case's `config.json`, while synthesis geometry is configured through the `DUT_*` CMake variables.

## Verification

The verification environment uses memory-access traces to evaluate cache behavior across multiple configurations.

The testbench reads requests, executes them through the RTL hierarchy, and reads back the final cache and stream-buffer state along with performance counters.

The generated reports are compared against expected outputs from the Python reference model.

The test configurations exercise:

- Direct-mapped and set-associative caches.
- Fully associative caches.
- Single-level and two-level hierarchies.
- Dirty-victim write-back behavior.
- Stream-buffer prefetching.
- Different block sizes and associativities.
- Back-to-back requests and random idle cycles.

## Synthesis and Implementation Analysis

The RTL can be synthesized using Synopsys Design Compiler.

The synthesis flow checks for inferred latches and generates timing and area reports. The cache metadata is implemented using registers and combinational read logic, making the design suitable for studying the area and timing trade-offs of parameterized cache architectures.

Important reports include:

- `timing_max_slow.rpt` – setup timing analysis.
- `timing_min_fast_holdcheck_*.rpt` – hold timing analysis.
- `cell_report_final.rpt` – cell and area information.
