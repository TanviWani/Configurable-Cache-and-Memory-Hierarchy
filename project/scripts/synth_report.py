#!/usr/bin/env python3
"""
Build one summary report from the Design Compiler reports and the simulation logs.

  python3 scripts/synth_report.py [--build build] [--clk 10.0]

Reads   build/synth/reports/*.rpt            (written by synthesis/CompileAnalyze.tcl)
        build/dut/outputs/output*/sim.log     (written by `make vsim-dut-c`)
Writes  build/synth/reports/summary.rpt       (and prints it)

Reported:  clock period, setup slack, hold slack, area, cell counts,
           cycles (per trace and total), total execution time = cycles x clock period.
"""
import argparse, glob, os, re, sys


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def first(pat, text, cast=float):
    m = re.search(pat, text, re.M)
    return cast(m.group(1)) if m else None


def slack(text):
    m = re.search(r"slack \((MET|VIOLATED)\)\s+(-?[\d.]+)", text)
    return (float(m.group(2)), m.group(1)) if m else (None, "n/a")


def fmt(v, unit="", nd=4):
    return "n/a" if v is None else f"{v:.{nd}f}{unit}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--clk", type=float, default=None, help="clock period in ns (default: parse from report)")
    a = ap.parse_args()
    rd = os.path.join(a.build, "synth", "reports")

    # ---- timing ------------------------------------------------------------------
    setup_txt = read(os.path.join(rd, "setup_final.rpt")) or read(glob.glob(os.path.join(rd, "timing_max_slow_holdfixed_*.rpt"))[0] if glob.glob(os.path.join(rd, "timing_max_slow_holdfixed_*.rpt")) else "")
    hold_txt = read(os.path.join(rd, "hold_final.rpt")) or read(glob.glob(os.path.join(rd, "timing_min_fast_holdcheck_*.rpt"))[0] if glob.glob(os.path.join(rd, "timing_min_fast_holdcheck_*.rpt")) else "")
    setup_slack, setup_st = slack(setup_txt)
    hold_slack, hold_st = slack(hold_txt)
    clk = a.clk or first(r"clock \S+ \(rise edge\)\s+([\d.]+)\s+[\d.]+\s*\n(?:.*\n)*?.*clock network", setup_txt)
    if not clk:
        clk = first(r"-period\s+([\d.]+)", read(os.path.join(a.build, "dc", "command.log"))) or 10.0
    data_path = first(r"data arrival time\s+(-?[\d.]+)", setup_txt)
    fmax = 1000.0 / (clk - setup_slack) if (setup_slack is not None and clk - setup_slack > 0) else None

    # ---- area / cells ----------------------------------------------------------------
    area_txt = read(os.path.join(rd, "area_report_final.rpt"))
    cell_txt = read(os.path.join(rd, "cell_report_final.rpt"))
    qor_txt = read(os.path.join(rd, "qor_report_final.rpt"))
    total_area = first(r"Total cell area:\s+([\d.]+)", area_txt) or first(r"Total cell area:\s+([\d.]+)", cell_txt) or first(r"Cell Area[^\n]*:\s+([\d.]+)", qor_txt)
    comb_area = first(r"Combinational area:\s+([\d.]+)", area_txt)
    seq_area = first(r"Noncombinational area:\s+([\d.]+)", area_txt)
    buf_area = first(r"Buf/Inv area:\s+([\d.]+)", area_txt)
    n_cells = first(r"Number of cells:\s+(\d+)", area_txt, int) or first(r"Leaf Cell Count:\s+(\d+)", qor_txt, int) or first(r"Total number of cells:\s+(\d+)", cell_txt, int)
    n_seq = first(r"Number of sequential cells:\s+(\d+)", area_txt, int) or first(r"Sequential Cell Count:\s+(\d+)", qor_txt, int)
    n_comb = first(r"Number of combinational cells:\s+(\d+)", area_txt, int) or first(r"Combinational Cell Count:\s+(\d+)", qor_txt, int)

    # ---- cycles / time ------------------------------------------------------------------
    rows, tot_c, tot_r = [], 0, 0
    for log in sorted(glob.glob(os.path.join(a.build, "dut", "outputs", "output*", "sim.log")),
                      key=lambda p: int(re.search(r"output(\d+)", p).group(1))):
        m = re.search(r"INFO\[tb\]:\s+(\d+) requests in (\d+) cycles \(([\d.]+) cycles/request\)", read(log))
        if m:
            n = int(re.search(r"output(\d+)", log).group(1))
            r_, c_ = int(m.group(1)), int(m.group(2))
            rows.append((n, r_, c_, float(m.group(3))))
            tot_c += c_; tot_r += r_

    L = []
    w = L.append
    w("=" * 66)
    w("  SYNTHESIS + PERFORMANCE SUMMARY  (design: dut, Nangate 45nm slow)")
    w("=" * 66)
    w(f"Clock period            : {fmt(clk, ' ns', 3)}   ({fmt(1000.0 / clk, ' MHz', 1)})")
    w(f"Setup slack (max, slow) : {fmt(setup_slack, ' ns')}  [{setup_st}]")
    w(f"Hold  slack (min, fast) : {fmt(hold_slack, ' ns')}  [{hold_st}]")
    w(f"Critical data arrival   : {fmt(data_path, ' ns')}")
    w(f"Achievable period (est.): {fmt(clk - setup_slack if setup_slack is not None else None, ' ns', 3)}"
      f"   (~{fmt(fmax, ' MHz', 1)})")
    w("-" * 66)
    w(f"Total cell area         : {fmt(total_area, ' um^2', 2)}")
    w(f"  combinational         : {fmt(comb_area, ' um^2', 2)}")
    w(f"  sequential            : {fmt(seq_area, ' um^2', 2)}")
    w(f"  buf/inv               : {fmt(buf_area, ' um^2', 2)}")
    w(f"Total cells             : {n_cells if n_cells is not None else 'n/a'}")
    w(f"  combinational cells   : {n_comb if n_comb is not None else 'n/a'}")
    w(f"  sequential cells      : {n_seq if n_seq is not None else 'n/a'}")
    w("-" * 66)
    if rows:
        w(f"{'case':>4} {'requests':>9} {'cycles':>9} {'cyc/req':>8} {'time (us)':>11}")
        for n, r_, c_, cpr in rows:
            w(f"{n:>4} {r_:>9} {c_:>9} {cpr:>8.3f} {c_ * clk / 1000.0:>11.3f}")
        w(f"{'ALL':>4} {tot_r:>9} {tot_c:>9} {tot_c / tot_r:>8.3f} {tot_c * clk / 1000.0:>11.3f}")
        w(f"Total cycles            : {tot_c}")
        w(f"Total time              : {tot_c * clk:.1f} ns  ({tot_c * clk / 1000.0:.3f} us) = cycles x clock period")
    else:
        w("Cycles / total time    : n/a  (run `make vsim-dut-c` first so sim.log files exist)")
    w("=" * 66)
    out = "\n".join(L)
    print(out)
    os.makedirs(rd, exist_ok=True)
    with open(os.path.join(rd, "summary.rpt"), "w") as f:
        f.write(out + "\n")


if __name__ == "__main__":
    sys.exit(main())
