`timescale 1ns/1ps
//==============================================================================
// cache_level : one generic CACHE of the memory hierarchy (tags only, no data)
//
//   * LRU replacement, WBWA write policy, optional stream-buffer prefetch unit
//   * Trace-driven: only block addresses, read/write and tag state are modelled,
//     exactly what the C++ simulator tracks (no data array).
//
// Microarchitecture
//   S0 (accept) : up_valid/up_ready handshake, request registered into S1.
//   S1 (evaluate): the set row is read, hit/miss/victim/stream-buffer decisions
//                  are made, the new row is written back and the counters are
//                  updated -- all in ONE cycle  =>  1 request / cycle sustained.
//                  A miss that must evict a dirty block uses a 2nd cycle in S1
//                  (phase 1) only when a cache sits below, because the write-
//                  back and the fill are two separate requests on dn_*.
//
// Area / power ideas used here
//   * Each set is a MOVE-TO-FRONT STACK: way 0 = MRU ... way ASSOC-1 = LRU.
//     No LRU counters/matrix at all; the victim is always the last entry; the
//     final-contents dump is already in MRU->LRU order; valid entries always
//     form a prefix, so "an invalid block exists" == "last entry is invalid".
//   * Only entries that actually move get a write enable (thermometer mask);
//     a clean MRU read hit (the most common case) writes nothing.
//   * Valid bits are the only reset state (no per-bit reset on tag/dirty).
//   * A stream buffer always holds M CONSECUTIVE blocks, so it is stored as a
//     single {valid, head-block} pair, not M blocks (data is never modelled).
//   * Stream buffers are also a move-to-front stack (true LRU for free).
//
// Restriction (as in the spec: "prefetching is only tested and explored in the
// last-level cache"): PREF_N > 0 requires HAS_DN == 0.
//==============================================================================
module cache_level #(
  parameter int BLOCKSIZE = 32,          // bytes, power of two
  parameter int SIZE      = 1024,        // total bytes
  parameter int ASSOC     = 2,           // any value >= 1
  parameter int PREF_N    = 0,           // # stream buffers, 0 = prefetch off
  parameter int PREF_M    = 4,           // blocks per stream buffer
  parameter bit HAS_DN    = 1'b0,        // 1: another CACHE sits below
  // ---- derived values: do not override ------------------------------------
  parameter int OFFSET_W  = $clog2(BLOCKSIZE),
  parameter int BLK_W     = 32 - OFFSET_W,
  parameter int SETS      = SIZE / (ASSOC * BLOCKSIZE),
  parameter int IDX_W     = $clog2(SETS),
  parameter int TAG_W     = BLK_W - IDX_W,
  parameter int IDXD_W    = (IDX_W < 1) ? 1 : IDX_W,
  parameter int POSD_W    = ($clog2(ASSOC) < 1) ? 1 : $clog2(ASSOC),
  parameter int SBD_W     = ($clog2(PREF_N) < 1) ? 1 : $clog2(PREF_N),
  parameter int INC_W     = ($clog2(PREF_M + 1) < 1) ? 1 : $clog2(PREF_M + 1),
  parameter int CNT_W     = 32
)(
  input  logic                clk,
  input  logic                reset_n,

  // request from above (CPU/trace or upper cache), block address
  input  logic                up_valid,
  input  logic                up_wr,
  input  logic [BLK_W-1:0]    up_blk,
  output logic                up_ready,

  // request to the level below (only meaningful when HAS_DN)
  output logic                dn_valid,
  output logic                dn_wr,
  output logic [BLK_W-1:0]    dn_blk,
  input  logic                dn_ready,

  output logic                busy,           // S1 occupied

  // read-back of final state (use only while busy == 0)
  input  logic                dump_en,        // 1-cycle pulse: select a set
  input  logic [IDXD_W-1:0]   dump_set,
  input  logic [POSD_W-1:0]   dump_pos,       // 0 = MRU
  output logic                dump_valid,
  output logic                dump_dirty,
  output logic [TAG_W-1:0]    dump_tag,
  input  logic [SBD_W-1:0]    dump_sb,        // 0 = MRU stream buffer
  output logic                dump_sb_valid,
  output logic [BLK_W-1:0]    dump_sb_base,   // first block of the stream

  // measurements
  output logic [CNT_W-1:0]    st_reads,
  output logic [CNT_W-1:0]    st_rmiss,       // excludes stream-buffer hits
  output logic [CNT_W-1:0]    st_writes,
  output logic [CNT_W-1:0]    st_wmiss,       // excludes stream-buffer hits
  output logic [CNT_W-1:0]    st_wb,          // dirty evictions
  output logic [CNT_W-1:0]    st_pref         // prefetch requests issued
);

  // synopsys translate_off
  initial begin
    if ((BLOCKSIZE & (BLOCKSIZE - 1)) != 0) $fatal(1, "cache_level: BLOCKSIZE must be a power of two");
    if (SETS < 1 || (SETS & (SETS - 1)) != 0 || SETS * ASSOC * BLOCKSIZE != SIZE)
      $fatal(1, "cache_level: SIZE/(ASSOC*BLOCKSIZE) must be a power of two (SIZE=%0d ASSOC=%0d BLOCKSIZE=%0d)", SIZE, ASSOC, BLOCKSIZE);
    if (PREF_N > 0 && HAS_DN) $fatal(1, "cache_level: prefetch unit is supported in the last-level cache only");
    if (PREF_N > 0 && PREF_M < 1) $fatal(1, "cache_level: PREF_M must be >= 1");
  end
  // synopsys translate_on

  //----------------------------------------------------------------------------
  // S0 : accept
  //----------------------------------------------------------------------------
  logic                s1_valid, s1_wr, s1_ph, s1_done;
  logic [TAG_W-1:0]    s1_tag;
  logic [IDXD_W-1:0]   idx_q;            // set index of S1 (also the read address)
  logic [IDXD_W-1:0]   up_idx;
  logic [IDXD_W-1:0]   ridx;
  logic [BLK_W-1:0]    s1_blk, vic_blk;

  wire [TAG_W-1:0]     up_tag = up_blk[BLK_W-1:IDX_W];
  wire                 acc    = up_valid & up_ready;

  generate
    if (IDX_W > 0) begin : g_idx
      assign up_idx = up_blk[IDX_W-1:0];
      assign ridx   = idx_q;
      assign s1_blk = {s1_tag, idx_q};
    end else begin : g_noidx            // fully associative: one set
      assign up_idx = 1'b0;
      assign ridx   = 1'b0;
      assign s1_blk = s1_tag;
    end
  endgenerate

  assign up_ready = ~s1_valid | s1_done;
  assign busy     = s1_valid;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n)      s1_valid <= 1'b0;
    else if (acc)      s1_valid <= 1'b1;
    else if (s1_done)  s1_valid <= 1'b0;
  end

  always_ff @(posedge clk) begin
    if (acc) begin
      s1_tag <= up_tag;
      s1_wr  <= up_wr;
    end
    if (acc | dump_en) idx_q <= dump_en ? dump_set : up_idx;
  end

  //----------------------------------------------------------------------------
  // Tag state.   Per set: ASSOC entries, entry 0 = MRU ... entry ASSOC-1 = LRU
  //----------------------------------------------------------------------------
  logic [ASSOC-1:0][TAG_W-1:0] tmem [SETS];
  logic [ASSOC-1:0]            dmem [SETS];
  logic [ASSOC-1:0]            vmem [SETS];

  wire [ASSOC-1:0][TAG_W-1:0]  r_t = tmem[ridx];
  wire [ASSOC-1:0]             r_d = dmem[ridx];
  wire [ASSOC-1:0]             r_v = vmem[ridx];

  //----------------------------------------------------------------------------
  // S1 : hit / victim
  //----------------------------------------------------------------------------
  logic [ASSOC-1:0] r_hv;                // per-entry hit (at most one is set)
  logic [ASSOC-1:0] sfx;                 // sfx[e] = a hit exists at entry >= e
  logic             cache_hit;
  logic             hit_d;               // dirty bit of the hit entry

  always_comb begin
    for (int e = 0; e < ASSOC; e++) r_hv[e] = r_v[e] & (r_t[e] == s1_tag);
    cache_hit = |r_hv;
    hit_d     = |(r_hv & r_d);
    sfx[ASSOC-1] = r_hv[ASSOC-1];
    for (int e = ASSOC - 2; e >= 0; e--) sfx[e] = sfx[e+1] | r_hv[e];
  end

  // victim = last stack entry; a dirty valid one must be written back
  wire                 vic_dirty = r_v[ASSOC-1] & r_d[ASSOC-1];
  wire [TAG_W-1:0]     vic_tag   = r_t[ASSOC-1];
  wire                 evict     = ~cache_hit & vic_dirty;

  generate
    if (IDX_W > 0) begin : g_vic
      assign vic_blk = {vic_tag, idx_q};
    end else begin : g_novic
      assign vic_blk = vic_tag;
    end
  endgenerate

  //----------------------------------------------------------------------------
  // S1 : new row (move-to-front) and write enables
  //----------------------------------------------------------------------------
  logic [ASSOC-1:0][TAG_W-1:0] n_t;
  logic [ASSOC-1:0]            n_d, we_e;

  always_comb begin
    // new MRU entry: the accessed block
    n_t[0]  = s1_tag;
    n_d[0]  = s1_wr | (cache_hit & hit_d);
    we_e[0] = 1'b1;
    // entries above the hit (or all valid ones on a miss) move one step down
    for (int e = 1; e < ASSOC; e++) begin
      n_t[e]  = r_t[e-1];
      n_d[e]  = r_d[e-1];
      we_e[e] = cache_hit ? sfx[e] : r_v[e-1];
    end
  end

  // a clean MRU read hit, or a write to an already-dirty MRU block, changes nothing
  wire row_we = s1_done & ~(r_hv[0] & (~s1_wr | r_d[0]));

  always_ff @(posedge clk) begin
    if (row_we) begin
      for (int e = 0; e < ASSOC; e++) begin
        if (we_e[e]) begin
          tmem[ridx][e] <= n_t[e];
          dmem[ridx][e] <= n_d[e];
        end
      end
    end
  end

  // valid bits only ever go 0 -> 1 (entries written are always valid)
  generate
    for (genvar s = 0; s < SETS; s++) begin : g_v
      always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
          vmem[s] <= '0;
        end else if (row_we && (ridx == s)) begin
          for (int e = 0; e < ASSOC; e++) if (we_e[e]) vmem[s][e] <= 1'b1;
        end
      end
    end
  endgenerate

  //----------------------------------------------------------------------------
  // Requests to the level below
  //----------------------------------------------------------------------------
  generate
    if (HAS_DN) begin : g_dn
      // miss: [write back dirty victim] then [read the missed block]
      wire need_wb = ~cache_hit & vic_dirty;
      wire last_ph = s1_ph | ~need_wb;
      assign dn_valid = s1_valid & ~cache_hit;
      assign dn_wr    = need_wb & ~s1_ph;
      assign dn_blk   = dn_wr ? vic_blk : s1_blk;
      assign s1_done  = s1_valid & last_ph & (cache_hit | dn_ready);

      always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                              s1_ph <= 1'b0;
        else if (s1_done)                          s1_ph <= 1'b0;
        else if (dn_valid & dn_wr & dn_ready)      s1_ph <= 1'b1;
      end
    end else begin : g_nodn
      // last level: main memory is a sink, only the counters see the traffic
      assign dn_valid = 1'b0;
      assign dn_wr    = 1'b0;
      assign dn_blk   = '0;
      assign s1_done  = s1_valid;
      assign s1_ph    = 1'b0;
    end
  endgenerate

  //----------------------------------------------------------------------------
  // Stream-buffer prefetch unit
  //----------------------------------------------------------------------------
  // Tiny explicit incrementer (xor/and chain): keeps Design Compiler from
  // instantiating a DW01_inc of width INC_W for this 3-bit add.
  function automatic logic [INC_W-1:0] inc_s(input logic [INC_W-1:0] a);
    logic c;
    c = 1'b1;
    for (int i = 0; i < INC_W; i++) begin
      inc_s[i] = a[i] ^ c;
      c        = c & a[i];
    end
  endfunction

  logic                sb_hit;           // request hits some stream buffer
  logic [INC_W-1:0]    pref_inc;         // prefetches issued by this request

  generate
    if (PREF_N > 0) begin : g_sb
      // NSB >= 1 always: Design Compiler elaborates declarations of this block
      // even when PREF_N == 0 (e.g. L1 with an L2 below); a [0:-1] range is illegal.
      localparam int               NSB = (PREF_N < 1) ? 1 : PREF_N;
      localparam int               KW  = INC_W;
      localparam logic [INC_W-1:0] M_C = PREF_M;
      localparam logic [BLK_W-1:0] M_B = PREF_M;

      logic [NSB-1:0][BLK_W-1:0] sb_base;   // head block of each stream
      logic [NSB-1:0]            sb_v;      // [0] = MRU ... [NSB-1] = LRU
      logic [BLK_W-1:0]             sb_diff [NSB];
      logic [NSB-1:0]            sb_hv, sb_sel, sb_sfx, sb_sh;
      logic                         seen;
      logic [KW-1:0]                k_sel;

      wire [BLK_W-1:0] nxt_blk = s1_blk + 1'b1;

      // hit test: block X lies in [base, base+M-1]  <=>  (X - base) < M
      always_comb begin
        seen  = 1'b0;
        k_sel = '0;
        for (int i = 0; i < NSB; i++) begin
          sb_diff[i] = s1_blk - sb_base[i];
          sb_hv[i]   = sb_v[i] & (sb_diff[i] < M_B);
          sb_sel[i]  = sb_hv[i] & ~seen;           // MRU-most hit wins
          seen       = seen | sb_hv[i];
          if (sb_sel[i]) k_sel = k_sel | sb_diff[i][KW-1:0];
        end
        sb_hit = seen;
        // hit at offset k: k+1 blocks leave the head, k+1 are prefetched
        // miss in cache and in every buffer: new stream of M blocks
        pref_inc = sb_hit ? inc_s(k_sel) : (cache_hit ? '0 : M_C);

        sb_sfx[NSB-1] = sb_sel[NSB-1];
        for (int i = NSB - 2; i >= 0; i--) sb_sfx[i] = sb_sfx[i+1] | sb_sel[i];
        sb_sh[0] = 1'b0;
        for (int i = 1; i < NSB; i++) sb_sh[i] = sb_hit ? sb_sfx[i] : sb_v[i-1];
      end

      // update: hit -> that buffer continues (becomes MRU, head = X+1)
      //         miss everywhere -> LRU buffer is recycled for stream X+1..X+M
      //         cache hit & no buffer hit -> nothing
      wire sb_we = s1_done & (sb_hit | ~cache_hit);

      always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) sb_v <= '0;
        else if (sb_we) begin
          sb_v[0] <= 1'b1;
          for (int i = 1; i < NSB; i++) if (sb_sh[i]) sb_v[i] <= 1'b1;
        end
      end

      always_ff @(posedge clk) begin
        if (sb_we) begin
          sb_base[0] <= nxt_blk;
          for (int i = 1; i < NSB; i++) if (sb_sh[i]) sb_base[i] <= sb_base[i-1];
        end
      end

      assign dump_sb_valid = sb_v[dump_sb];
      assign dump_sb_base  = sb_base[dump_sb];
    end else begin : g_nosb
      assign sb_hit        = 1'b0;
      assign pref_inc      = '0;
      assign dump_sb_valid = 1'b0;
      assign dump_sb_base  = '0;
    end
  endgenerate

  //----------------------------------------------------------------------------
  // Read-back of the final state (shares the S1 read port)
  //----------------------------------------------------------------------------
  assign dump_valid = r_v[dump_pos];
  assign dump_dirty = r_d[dump_pos];
  assign dump_tag   = r_t[dump_pos];

  //----------------------------------------------------------------------------
  // Measurements.  A "miss" means neither the cache nor a stream buffer hit.
  //----------------------------------------------------------------------------
  wire miss_dem = ~cache_hit & ~sb_hit;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      st_reads  <= '0;
      st_rmiss  <= '0;
      st_writes <= '0;
      st_wmiss  <= '0;
      st_wb     <= '0;
    end else if (s1_done) begin
      if (s1_wr) st_writes <= st_writes + 1'b1;
      else       st_reads  <= st_reads  + 1'b1;
      if (miss_dem & s1_wr)  st_wmiss <= st_wmiss + 1'b1;
      if (miss_dem & ~s1_wr) st_rmiss <= st_rmiss + 1'b1;
      if (evict)             st_wb    <= st_wb    + 1'b1;
    end
  end

  generate
    if (PREF_N > 0) begin : g_pc
      always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                        st_pref <= '0;
        else if (s1_done & (pref_inc != '0)) st_pref <= st_pref + {{(CNT_W-INC_W){1'b0}}, pref_inc};
      end
    end else begin : g_nopc
      assign st_pref = '0;
    end
  endgenerate

endmodule
