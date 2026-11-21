# Cache + Stream-Buffer Memory Hierarchy in RTL

A synthesizable SystemVerilog implementation of the ECE 463/563 Project 1 memory
hierarchy (L1, optional L2, LRU, WBWA, stream-buffer prefetch in the last level),
organised like `project-template`: same tool versions (Questa 2026.1, Design
Compiler Y-2026.03), same CMake/preset flow, same `synthesis/` scripts.

It is trace-driven: the testbench feeds `r|w <hex address>` lines to the DUT, then
reads back the final cache / stream-buffer contents and the counters and writes a
report with the same content and ordering as the C++ simulator (spec Sec. 7).

```
trace request ──► L1 ──► [L2] ──► main memory (counted, not modelled)
                  └ prefetch unit lives in the LAST level (L1 if no L2)
```

## Layout

| Path | Purpose |
|------|---------|
| `srcs/rtl/dut.sv` | top: L1 + optional L2, request port, read-back port, 12 counters |
| `srcs/rtl/cache_level.sv` | the generic CACHE (instantiated once per level) |
| `srcs/tb/tb.sv` | trace-driven testbench + report writer (`write_report`) |
| `inputs/input<N>/` | `trace.txt`, `config.json` (geometry) for case N |
| `outputs/output<N>/expected.out` | golden report from the Python reference |
| `scripts/ref_cache.py` | independent reference model of the spec |
| `scripts/gen_tests.py` | regenerates traces + expected outputs (`make ref`) |
| `scripts/run_tests.py` | runs cases on Questa (or Verilator) and diffs (`diff -iw` semantics) |
| `synthesis/` | template DC scripts (unchanged) |

## Flow

```bash
source setup.sh                     # questa/2026.1, syn/Y-2026.03
cmake --preset run                  # or: cmake --preset test3
cmake --build build --target vsim-dut-c     # batch: all cases (TEST=-1) or one
cmake --build build --target vsim-dut       # GUI on one case (waves from do/waves.do)
cmake --build build --target vsim-dut-bubble# same, with 30 % random idle cycles on the request port
cmake --build build --target synth          # Design Compiler, geometry = DUT_* cache variables
cmake --build build --target compress
```

Geometry for **simulation** comes from `inputs/input<N>/config.json`, passed as
`vsim -GT_<NAME>=<value>`. The testbench parameters are deliberately named `T_*`: Questa's `-G`
overrides every parameter of that name anywhere in the hierarchy, even explicitly assigned ones,
so names shared with `dut`/`cache_level` would silently reconfigure the L1. Geometry for **synthesis** (and the default of `dut`) comes from the
`DUT_*` CMake cache variables -> `+define+CFG_*`. Edit them in `CMakePresets.json`
or e.g. `cmake --preset run -DDUT_L2_SIZE=0 -DDUT_PREF_N=0`.
The defaults are deliberately small (1 KB L1 / 8 KB L2): the tag state is modelled
with flops, so a 256 KB L2 would be a very large synthesis run (see "Scaling").

## Spec -> hardware mapping

| Spec | RTL |
|------|-----|
| `sim <BS> <L1_SIZE> <L1_ASSOC> <L2_SIZE> <L2_ASSOC> <PREF_N> <PREF_M> <trace>` | `BLOCKSIZE, L1_SIZE, L1_ASSOC, L2_SIZE, L2_ASSOC, PREF_N, PREF_M` parameters + `+trace=` |
| `L2_SIZE = 0` -> no L2, `PREF_N = 0` -> no prefetch | `generate` removes the L2 / prefetch hardware |
| ASSOC and SIZE need not be powers of two (sets must be) | supported (e.g. 3-way, 6-way; tested) |
| fully associative (`ASSOC = SIZE/BLOCKSIZE`) | one set, zero index bits (tested, L1 and L2) |
| Sec. 3.4 allocate: write-back of dirty victim, then read of X | dn request #1 (write), dn request #2 (read) |
| Scenarios 1-4, MRU-most buffer wins on multi-hit, buffer LRU | `g_sb` in `cache_level.sv` |
| Items a-q | counters -> `write_report`; q = i+k+m+o+p (L2) or b+d+f+g (no L2) |
| Prefetch only tested in the last level; j = k = 0 | `PREF_N > 0` with a cache below is rejected at elaboration; j, k print 0 |

## Microarchitecture

Two-stage pipeline per level, one request per cycle:

* **S0 accept** (`up_valid/up_ready`): request registered, set index = read address.
* **S1 evaluate**: row read, tag compare, victim, stream-buffer lookup, new row,
  write-back and counter update, all in one cycle. A miss that evicts a dirty block
  holds S1 for a second cycle **only when a cache is below** (write-back and fill
  are two separate requests). The last level never stalls, so `up_ready` is a
  constant 1 there.
* No hazard logic: S1 writes the row at the edge that S0 loads the next request, so
  a back-to-back access to the same set reads the updated row.
* No response path: tags are the only state, so a level never waits for the level
  below. Hence L1-only runs sustain exactly 1.000 cycles/request; L1+L2 runs cost
  1.15-1.29 on the regression traces (one extra cycle per dirty-victim miss).

### Area ideas
* **Each set is a move-to-front stack** (way 0 = MRU ... way A-1 = LRU): no LRU
  counters or matrices; victim = last entry; valid entries form a prefix, so
  "free way exists" = "last entry invalid"; the final dump is already in MRU->LRU order.
* **Stream buffers store `{valid, head block}`**, not M blocks: a buffer always holds
  M consecutive blocks and data is never modelled. Hit test = `(X - head) < M`;
  hit at offset k issues k+1 prefetches and sets head = X+1; new stream sets head = X+1
  and issues M. Buffers are also a move-to-front stack (true LRU for free).
* Valid bits are the only reset state; written valid bits are always 1.
* No data array, no counters beyond the 6 per level.

### Power ideas
* Write enables per entry (thermometer mask): only entries that move are written.
* A clean MRU read hit, or a write to an already-dirty MRU block, writes nothing.
* Prefetch hardware and the prefetch counter are generated away when `PREF_N = 0`.
* No latches (the template's `CheckLatches.tcl` aborts on them) and no clock gating
  cells; enable-based registers only.

## Read-back port
`dump_en` selects a set (reusing the S1 read port, so no second read mux), then
`dump_pos` walks the ways in MRU->LRU order; `dump_sb` walks the stream buffers.
Use it only while `idle` is 1.

## Verification status (be aware of what was and was not run)
* Run: all 15 cases (`l1_dm`, 4-way, fully-associative, L1+L2, odd associativities,
  1x4 / 4x8 / 2x1 / 3x3 / 8x16 / 3x10 prefetch shapes, block sizes 16-128,
  fully-associative L2, a tiny thrashing hierarchy) match the Python reference
  **bit-exactly** (contents, order, dirty bits, every counter), also with random
  idle cycles on the request port. This was done with **Verilator 5.020**.
* Not run here: Questa 2026.1 and Design Compiler. The RTL/tb use only standard
  SystemVerilog; the CMake flow was checked with stub tools only. Expect to look at
  DC warnings once (see the next section).
* The report format follows the item list of the spec, but I did not have the
  Moodle validation files. If `diff -iw` against your C++ output complains about
  layout, change only `write_report`/`write_level`/`write_streams` in `tb.sv`
  (and the matching lines in `ref_cache.py`). The best end-to-end check is to run
  your own validated C++ simulator on `inputs/input<N>/trace.txt` and diff it with
  `build/dut/outputs/output<N>/sim.out`.

## Scaling and known limits
* Geometry is an elaboration-time parameter (hardware cannot change it at run time).
* Tag state is modelled with flops and a combinational read mux. That is fine for
  KB-scale caches; for 256 KB-class L2s map `tmem/dmem/vmem` onto SRAM macros
  (the read needs a write-first bypass because macros register the address) and
  expect the S1 path to become array-read + compare + write-back.
* Longest path: S1 array read -> tag compare -> hit/victim -> `up_ready` (L1 with L2).
  Check `build/synth/reports/timing_max_slow.rpt`; raise `DC_CLOCK_PER` if needed.
* Block addresses wrap at `32 - log2(BLOCKSIZE)` bits (stream running off the top
  of the 4 GB address space); irrelevant for the provided traces.
* Counters are 32 bits.
