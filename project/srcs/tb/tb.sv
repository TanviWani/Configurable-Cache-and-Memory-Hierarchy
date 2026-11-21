`timescale 1ns/1ps
//==============================================================================
// tb : trace-driven testbench for the cache-hierarchy RTL
//
//   plusargs:  +trace=<file>      trace ("r|w <hex address>" per line)   [required]
//              +out=<file>        report file                            [sim.out]
//              +tracename=<str>   name printed in the report              [= +trace]
//              +bubble=<pct>      % of requests preceded by 1-4 idle cycles [0]
//              +seed=<n>          seed for the bubble generator           [1]
//
//   The cache geometry is given by the parameters below (override with
//   vsim -GT_<NAME>=<value>); the report format is produced by task write_report,
//   which is the only place to touch if the format has to be adapted.
//==============================================================================
module tb;
  parameter int T_BLOCKSIZE = 32;
  parameter int T_L1_SIZE   = 1024;
  parameter int T_L1_ASSOC  = 2;
  parameter int T_L2_SIZE   = 8192;      // 0 = no L2
  parameter int T_L2_ASSOC  = 4;
  parameter int T_PREF_N    = 2;         // 0 = no prefetch unit
  parameter int T_PREF_M    = 4;

  localparam bit HAS_L2    = (T_L2_SIZE > 0);
  localparam int OFFSET_W  = $clog2(T_BLOCKSIZE);
  localparam int L1_SETS   = T_L1_SIZE / (T_L1_ASSOC * T_BLOCKSIZE);
  localparam int L2_SETS   = HAS_L2 ? T_L2_SIZE / (T_L2_ASSOC * T_BLOCKSIZE) : 1;
  localparam int L1_IDXD_W = ($clog2(L1_SETS) < 1) ? 1 : $clog2(L1_SETS);
  localparam int L2_IDXD_W = ($clog2(L2_SETS) < 1) ? 1 : $clog2(L2_SETS);
  localparam int L1_POSD_W = ($clog2(T_L1_ASSOC) < 1) ? 1 : $clog2(T_L1_ASSOC);
  localparam int L2_POSD_W = (!HAS_L2 || $clog2(T_L2_ASSOC) < 1) ? 1 : $clog2(T_L2_ASSOC);
  localparam int SBD_W     = ($clog2(T_PREF_N) < 1) ? 1 : $clog2(T_PREF_N);
  localparam int DSET_W    = (L1_IDXD_W > L2_IDXD_W) ? L1_IDXD_W : L2_IDXD_W;
  localparam int DPOS_W    = (L1_POSD_W > L2_POSD_W) ? L1_POSD_W : L2_POSD_W;

  //--------------------------------------------------------------------------
  // Clock @ 100 MHz, reset
  //--------------------------------------------------------------------------
  parameter CLK_PHASE = 5;
  logic clk;
  logic reset_n;
  initial begin
    clk = 1'b1;
    forever #CLK_PHASE clk = ~clk;
  end

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  logic        req_valid, req_wr;
  logic [31:0] req_addr;
  wire         req_ready, idle;
  logic        dump_en, dump_l2;
  logic [DSET_W-1:0] dump_set;
  logic [DPOS_W-1:0] dump_pos;
  wire         dump_valid, dump_dirty;
  wire  [31:0] dump_tag;
  logic [SBD_W-1:0]  dump_sb;
  wire         dump_sb_valid;
  wire  [31:0] dump_sb_base;
  wire  [31:0] l1_reads, l1_rmiss, l1_writes, l1_wmiss, l1_wb, l1_pref;
  wire  [31:0] l2_reads, l2_rmiss, l2_writes, l2_wmiss, l2_wb, l2_pref;

  dut #(
    .BLOCKSIZE (T_BLOCKSIZE),
    .L1_SIZE   (T_L1_SIZE),  .L1_ASSOC (T_L1_ASSOC),
    .L2_SIZE   (T_L2_SIZE),  .L2_ASSOC (T_L2_ASSOC),
    .PREF_N    (T_PREF_N),   .PREF_M   (T_PREF_M)
  ) dut_inst (
    .clk, .reset_n,
    .req_valid, .req_wr, .req_addr, .req_ready, .idle,
    .dump_en, .dump_l2, .dump_set, .dump_pos,
    .dump_valid, .dump_dirty, .dump_tag,
    .dump_sb, .dump_sb_valid, .dump_sb_base,
    .l1_reads, .l1_rmiss, .l1_writes, .l1_wmiss, .l1_wb, .l1_pref,
    .l2_reads, .l2_rmiss, .l2_writes, .l2_wmiss, .l2_wb, .l2_pref
  );

  //--------------------------------------------------------------------------
  // Bookkeeping
  //--------------------------------------------------------------------------
  string  trace_file, out_file, trace_name;
  integer bubble_pct, seed_arg;
  integer n_req, n_cycles, fd_in, fd_out;
  logic [31:0] lfsr;

  // cycle counter + watchdog
  longint unsigned cyc;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc > 64'd400_000_000) $fatal(1, "tb: watchdog timeout");
  end

  function automatic logic [31:0] next_rand(input logic [31:0] s);
    logic [31:0] x;
    x = s;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  //--------------------------------------------------------------------------
  // One request: hold valid until the DUT accepts it
  //--------------------------------------------------------------------------
  task automatic send_req(input logic w, input logic [31:0] a);
    if (bubble_pct > 0) begin
      lfsr = next_rand(lfsr);
      if ((lfsr % 100) < bubble_pct) begin
        req_valid <= 1'b0;
        lfsr = next_rand(lfsr);
        repeat (1 + (lfsr % 4)) @(posedge clk);
      end
    end
    req_valid <= 1'b1;
    req_wr    <= w;
    req_addr  <= a;
    do @(posedge clk); while (!req_ready);   // accepted at this edge
    n_req++;
  endtask

  //--------------------------------------------------------------------------
  // Read-back helpers (inputs driven on the falling edge, no races)
  //--------------------------------------------------------------------------
  task automatic write_level(input integer fd, input logic lvl, input integer sets, input integer assoc);
    for (integer s = 0; s < sets; s++) begin
      @(negedge clk);
      dump_l2 = lvl; dump_set = s; dump_en = 1'b1;
      @(negedge clk);
      dump_en = 1'b0;                          // set latched at the edge in between
      begin
        logic any;
        any = 1'b0;
        for (integer p = 0; p < assoc; p++) begin
          dump_pos = p;
          #1;
          if (dump_valid) begin
            if (!any) $fwrite(fd, "set %0d:", s);
            any = 1'b1;
            $fwrite(fd, " %0x", dump_tag);
            if (dump_dirty) $fwrite(fd, " D");
          end
        end
        if (any) $fwrite(fd, "\n");
      end
    end
  endtask

  task automatic write_streams(input integer fd);
    for (integer i = 0; i < T_PREF_N; i++) begin
      dump_sb = i;
      #1;
      if (dump_sb_valid) begin
        for (integer b = 0; b < T_PREF_M; b++) $fwrite(fd, " %0x", dump_sb_base + b);
        $fwrite(fd, "\n");
      end
    end
  endtask

  function automatic real rate(input longint unsigned num, input longint unsigned den);
    return (den == 0) ? 0.0 : (1.0 * num) / (1.0 * den);
  endfunction

  //--------------------------------------------------------------------------
  // Report (same content/ordering as the simulator output of the spec, Sec. 7)
  //--------------------------------------------------------------------------
  task automatic write_report(input integer fd);
    longint unsigned traffic;
    traffic = HAS_L2 ? (l2_rmiss + l2_wmiss + l2_wb + l2_pref)
                     : (l1_rmiss + l1_wmiss + l1_wb + l1_pref);

    $fwrite(fd, "===== Simulator configuration =====\n");
    $fwrite(fd, "BLOCKSIZE:  %0d\n", T_BLOCKSIZE);
    $fwrite(fd, "L1_SIZE:    %0d\n", T_L1_SIZE);
    $fwrite(fd, "L1_ASSOC:   %0d\n", T_L1_ASSOC);
    $fwrite(fd, "L2_SIZE:    %0d\n", T_L2_SIZE);
    $fwrite(fd, "L2_ASSOC:   %0d\n", HAS_L2 ? T_L2_ASSOC : 0);
    $fwrite(fd, "PREF_N:     %0d\n", T_PREF_N);
    $fwrite(fd, "PREF_M:     %0d\n", T_PREF_N > 0 ? T_PREF_M : 0);
    $fwrite(fd, "trace_file: %0s\n", trace_name);
    $fwrite(fd, "\n");

    $fwrite(fd, "===== L1 contents =====\n");
    write_level(fd, 1'b0, L1_SETS, T_L1_ASSOC);
    $fwrite(fd, "\n");
    if (HAS_L2) begin
      $fwrite(fd, "===== L2 contents =====\n");
      write_level(fd, 1'b1, L2_SETS, T_L2_ASSOC);
      $fwrite(fd, "\n");
    end
    if (T_PREF_N > 0) begin
      $fwrite(fd, "===== Stream Buffer(s) contents =====\n");
      write_streams(fd);
      $fwrite(fd, "\n");
    end

    $fwrite(fd, "===== Measurements =====\n");
    $fwrite(fd, "a. L1 reads:                                   %0d\n", l1_reads);
    $fwrite(fd, "b. L1 read misses:                             %0d\n", l1_rmiss);
    $fwrite(fd, "c. L1 writes:                                  %0d\n", l1_writes);
    $fwrite(fd, "d. L1 write misses:                            %0d\n", l1_wmiss);
    $fwrite(fd, "e. L1 miss rate:                               %.4f\n",
            rate(l1_rmiss + l1_wmiss, l1_reads + l1_writes));
    $fwrite(fd, "f. L1 writebacks:                              %0d\n", l1_wb);
    $fwrite(fd, "g. L1 prefetches:                              %0d\n", l1_pref);
    $fwrite(fd, "h. L2 reads (demand):                          %0d\n", l2_reads);
    $fwrite(fd, "i. L2 read misses (demand):                    %0d\n", l2_rmiss);
    $fwrite(fd, "j. L2 reads (prefetch):                        %0d\n", 0);
    $fwrite(fd, "k. L2 read misses (prefetch):                  %0d\n", 0);
    $fwrite(fd, "l. L2 writes:                                  %0d\n", l2_writes);
    $fwrite(fd, "m. L2 write misses:                            %0d\n", l2_wmiss);
    $fwrite(fd, "n. L2 miss rate:                               %.4f\n", rate(l2_rmiss, l2_reads));
    $fwrite(fd, "o. L2 writebacks:                              %0d\n", l2_wb);
    $fwrite(fd, "p. L2 prefetches:                              %0d\n", l2_pref);
    $fwrite(fd, "q. memory traffic:                             %0d\n", traffic);
  endtask

  //--------------------------------------------------------------------------
  // Main sequence
  //--------------------------------------------------------------------------
  initial begin : main
    logic [7:0]  op;
    logic [31:0] a;
    integer      rc;
    longint unsigned t0;

    cyc = 0; n_req = 0;
    req_valid = 1'b0; req_wr = 1'b0; req_addr = '0;
    dump_en = 1'b0; dump_l2 = 1'b0; dump_set = '0; dump_pos = '0; dump_sb = '0;
    reset_n = 1'b0;

    if (!$value$plusargs("trace=%s", trace_file)) $fatal(1, "tb: +trace=<file> is required");
    if (!$value$plusargs("out=%s", out_file))     out_file   = "sim.out";
    if (!$value$plusargs("tracename=%s", trace_name)) trace_name = trace_file;
    if (!$value$plusargs("bubble=%d", bubble_pct)) bubble_pct = 0;
    if (!$value$plusargs("seed=%d", seed_arg))     seed_arg = 1;
    lfsr = 32'h9E3779B9 ^ seed_arg;
    if (lfsr == 0) lfsr = 32'h1;

    fd_in = $fopen(trace_file, "r");
    if (fd_in == 0) $fatal(1, "tb: cannot open trace %s", trace_file);

    repeat (4) @(posedge clk);
    reset_n <= 1'b1;
    repeat (2) @(posedge clk);

    t0 = cyc;
    while (1) begin
      rc = $fscanf(fd_in, " %c %h", op, a);
      if (rc != 2) break;
      send_req((op == "w" || op == "W"), a);
    end
    $fclose(fd_in);

    req_valid <= 1'b0;
    repeat (3) @(posedge clk);
    while (!idle) @(posedge clk);
    n_cycles = cyc - t0;

    fd_out = $fopen(out_file, "w");
    if (fd_out == 0) $fatal(1, "tb: cannot write %s", out_file);
    write_report(fd_out);
    $fclose(fd_out);

    // internal consistency of the hierarchy (spec Sec. 7, items h and l)
    if (HAS_L2) begin
      if (l2_reads  !== l1_rmiss + l1_wmiss) $error("tb: L2 reads (%0d) != L1 misses (%0d)", l2_reads, l1_rmiss + l1_wmiss);
      if (l2_writes !== l1_wb)               $error("tb: L2 writes (%0d) != L1 writebacks (%0d)", l2_writes, l1_wb);
    end
    $display("INFO[tb]: %0d requests in %0d cycles (%0.3f cycles/request), report: %0s",
             n_req, n_cycles, (n_req == 0) ? 0.0 : (1.0 * n_cycles) / n_req, out_file);
    if ($test$plusargs("stop")) $stop;     // GUI: keep the waveforms
    else                        $finish;
  end
endmodule
