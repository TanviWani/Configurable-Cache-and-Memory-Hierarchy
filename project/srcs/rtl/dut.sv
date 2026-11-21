`timescale 1ns/1ps
//==============================================================================
// dut : trace-driven cache + stream-buffer memory-hierarchy model in RTL
//
//   trace request ──► L1 ──► [L2] ──► main memory (counted only)
//
// Hierarchy shapes (same four/two shapes as the project spec):
//   L2_SIZE == 0, PREF_N == 0 : L1
//   L2_SIZE == 0, PREF_N  > 0 : L1 + prefetch unit
//   L2_SIZE  > 0, PREF_N == 0 : L1, L2
//   L2_SIZE  > 0, PREF_N  > 0 : L1, L2 + prefetch unit   (prefetch is always
//                                                         in the LAST level)
//
// Sizes are elaboration-time parameters (hardware cannot change geometry at
// run time).  Defaults come from the CFG_* macros so that the same numbers can
// be given to the simulator (+define+) and to Design Compiler (see CMake).
//==============================================================================
`ifndef CFG_BLOCKSIZE
  `define CFG_BLOCKSIZE 32
`endif
`ifndef CFG_L1_SIZE
  `define CFG_L1_SIZE 1024
`endif
`ifndef CFG_L1_ASSOC
  `define CFG_L1_ASSOC 2
`endif
`ifndef CFG_L2_SIZE
  `define CFG_L2_SIZE 8192
`endif
`ifndef CFG_L2_ASSOC
  `define CFG_L2_ASSOC 4
`endif
`ifndef CFG_PREF_N
  `define CFG_PREF_N 2
`endif
`ifndef CFG_PREF_M
  `define CFG_PREF_M 4
`endif

module dut #(
  parameter int BLOCKSIZE = `CFG_BLOCKSIZE,
  parameter int L1_SIZE   = `CFG_L1_SIZE,
  parameter int L1_ASSOC  = `CFG_L1_ASSOC,
  parameter int L2_SIZE   = `CFG_L2_SIZE,      // 0 = no L2
  parameter int L2_ASSOC  = `CFG_L2_ASSOC,
  parameter int PREF_N    = `CFG_PREF_N,       // 0 = no prefetch unit
  parameter int PREF_M    = `CFG_PREF_M,
  // ---- derived values: do not override ------------------------------------
  parameter bit HAS_L2    = (L2_SIZE > 0),
  parameter int OFFSET_W  = $clog2(BLOCKSIZE),
  parameter int BLK_W     = 32 - OFFSET_W,
  parameter int L1_SETS   = L1_SIZE / (L1_ASSOC * BLOCKSIZE),
  parameter int L2_SETS   = HAS_L2 ? L2_SIZE / (L2_ASSOC * BLOCKSIZE) : 1,
  parameter int L1_IDXD_W = ($clog2(L1_SETS) < 1) ? 1 : $clog2(L1_SETS),
  parameter int L2_IDXD_W = ($clog2(L2_SETS) < 1) ? 1 : $clog2(L2_SETS),
  parameter int L1_POSD_W = ($clog2(L1_ASSOC) < 1) ? 1 : $clog2(L1_ASSOC),
  parameter int L2_POSD_W = (!HAS_L2 || $clog2(L2_ASSOC) < 1) ? 1 : $clog2(L2_ASSOC),
  parameter int SBD_W     = ($clog2(PREF_N) < 1) ? 1 : $clog2(PREF_N),
  parameter int DSET_W    = (L1_IDXD_W > L2_IDXD_W) ? L1_IDXD_W : L2_IDXD_W,
  parameter int DPOS_W    = (L1_POSD_W > L2_POSD_W) ? L1_POSD_W : L2_POSD_W
)(
  input  wire                 clk,
  input  wire                 reset_n,

  // ---- trace request stream (one CPU load/store per handshake) -------------
  input  wire                 req_valid,
  input  wire                 req_wr,          // 1 = write, 0 = read
  input  wire  [31:0]         req_addr,
  output logic                req_ready,
  output logic                idle,            // pipeline drained, results valid

  // ---- read-back of final contents (drive only while idle) -----------------
  input  wire                 dump_en,         // 1-cycle pulse selects a set
  input  wire                 dump_l2,         // 0: L1, 1: L2
  input  wire  [DSET_W-1:0]   dump_set,
  input  wire  [DPOS_W-1:0]   dump_pos,        // 0 = MRU
  output logic                dump_valid,
  output logic                dump_dirty,
  output logic [31:0]         dump_tag,
  input  wire  [SBD_W-1:0]    dump_sb,         // 0 = MRU stream buffer
  output logic                dump_sb_valid,
  output logic [31:0]         dump_sb_base,    // first block of the stream

  // ---- measurements ---------------------------------------------------------
  output logic [31:0]         l1_reads,
  output logic [31:0]         l1_rmiss,
  output logic [31:0]         l1_writes,
  output logic [31:0]         l1_wmiss,
  output logic [31:0]         l1_wb,
  output logic [31:0]         l1_pref,
  output logic [31:0]         l2_reads,
  output logic [31:0]         l2_rmiss,
  output logic [31:0]         l2_writes,
  output logic [31:0]         l2_wmiss,
  output logic [31:0]         l2_wb,
  output logic [31:0]         l2_pref
);

  // synopsys translate_off
  initial begin
    if (HAS_L2 && L2_ASSOC < 1) $fatal(1, "dut: L2_ASSOC must be >= 1 when L2_SIZE > 0");
  end
  // synopsys translate_on

  //----------------------------------------------------------------------------
  // L1
  //----------------------------------------------------------------------------
  localparam int L1_TAG_W = BLK_W - $clog2(L1_SETS);

  // Resolved here as plain localparams (not as expressions inside the instance
  // parameter list): Design Compiler does not fold those and then elaborates
  // the stream-buffer generate of L1 with a bogus count.
  localparam int L1_PREF_N = HAS_L2 ? 0 : PREF_N;         // prefetch lives in the last level
  localparam int L1_SBD_W  = ($clog2(L1_PREF_N) < 1) ? 1 : $clog2(L1_PREF_N);

  wire [BLK_W-1:0] req_blk = req_addr[31:OFFSET_W];

  logic               l1_dn_valid, l1_dn_wr, l1_dn_ready;
  logic [BLK_W-1:0]   l1_dn_blk;
  logic               l1_busy, l1_dvalid, l1_ddirty, l1_dsbv;
  logic [L1_TAG_W-1:0] l1_dtag;
  logic [BLK_W-1:0]   l1_dsbb;

  cache_level #(
    .BLOCKSIZE (BLOCKSIZE),
    .SIZE      (L1_SIZE),
    .ASSOC     (L1_ASSOC),
    .PREF_N    (L1_PREF_N),
    .PREF_M    (PREF_M),
    .HAS_DN    (HAS_L2)
  ) u_l1 (
    .clk, .reset_n,
    .up_valid (req_valid), .up_wr (req_wr), .up_blk (req_blk), .up_ready (req_ready),
    .dn_valid (l1_dn_valid), .dn_wr (l1_dn_wr), .dn_blk (l1_dn_blk), .dn_ready (l1_dn_ready),
    .busy     (l1_busy),
    .dump_en  (dump_en & ~dump_l2),
    .dump_set (dump_set[L1_IDXD_W-1:0]),
    .dump_pos (dump_pos[L1_POSD_W-1:0]),
    .dump_valid (l1_dvalid), .dump_dirty (l1_ddirty), .dump_tag (l1_dtag),
    .dump_sb  (dump_sb[L1_SBD_W-1:0]),
    .dump_sb_valid (l1_dsbv), .dump_sb_base (l1_dsbb),
    .st_reads (l1_reads), .st_rmiss (l1_rmiss), .st_writes (l1_writes),
    .st_wmiss (l1_wmiss), .st_wb (l1_wb), .st_pref (l1_pref)
  );

  //----------------------------------------------------------------------------
  // L2 (optional)
  //----------------------------------------------------------------------------
  localparam int L2_TAG_W = HAS_L2 ? (BLK_W - $clog2(L2_SETS)) : 1;

  logic                 l2_busy, l2_dvalid, l2_ddirty, l2_dsbv;
  logic [L2_TAG_W-1:0]  l2_dtag;
  logic [BLK_W-1:0]     l2_dsbb;

  generate
    if (HAS_L2) begin : g_l2
      cache_level #(
        .BLOCKSIZE (BLOCKSIZE),
        .SIZE      (L2_SIZE),
        .ASSOC     (L2_ASSOC),
        .PREF_N    (PREF_N),
        .PREF_M    (PREF_M),
        .HAS_DN    (1'b0)
      ) u_l2 (
        .clk, .reset_n,
        .up_valid (l1_dn_valid), .up_wr (l1_dn_wr), .up_blk (l1_dn_blk), .up_ready (l1_dn_ready),
        .dn_valid (), .dn_wr (), .dn_blk (), .dn_ready (1'b1),
        .busy     (l2_busy),
        .dump_en  (dump_en & dump_l2),
        .dump_set (dump_set[L2_IDXD_W-1:0]),
        .dump_pos (dump_pos[L2_POSD_W-1:0]),
        .dump_valid (l2_dvalid), .dump_dirty (l2_ddirty), .dump_tag (l2_dtag),
        .dump_sb  (dump_sb),
        .dump_sb_valid (l2_dsbv), .dump_sb_base (l2_dsbb),
        .st_reads (l2_reads), .st_rmiss (l2_rmiss), .st_writes (l2_writes),
        .st_wmiss (l2_wmiss), .st_wb (l2_wb), .st_pref (l2_pref)
      );
    end else begin : g_nol2
      assign l1_dn_ready = 1'b1;
      assign l2_busy     = 1'b0;
      assign l2_dvalid   = 1'b0;
      assign l2_ddirty   = 1'b0;
      assign l2_dtag     = '0;
      assign l2_dsbv     = 1'b0;
      assign l2_dsbb     = '0;
      assign l2_reads    = '0;
      assign l2_rmiss    = '0;
      assign l2_writes   = '0;
      assign l2_wmiss    = '0;
      assign l2_wb       = '0;
      assign l2_pref     = '0;
    end
  endgenerate

  //----------------------------------------------------------------------------
  // Status and read-back muxing
  //----------------------------------------------------------------------------
  assign idle = ~l1_busy & ~l2_busy;

  assign dump_valid = dump_l2 ? l2_dvalid : l1_dvalid;
  assign dump_dirty = dump_l2 ? l2_ddirty : l1_ddirty;
  assign dump_tag   = dump_l2 ? 32'(l2_dtag) : 32'(l1_dtag);

  // the prefetch unit sits in the last level
  assign dump_sb_valid = HAS_L2 ? l2_dsbv : l1_dsbv;
  assign dump_sb_base  = HAS_L2 ? 32'(l2_dsbb) : 32'(l1_dsbb);

endmodule
