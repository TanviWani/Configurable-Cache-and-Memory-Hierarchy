#!/usr/bin/env python3
"""
Run the regression cases (inputs/input<N>) on the RTL and compare the report with
outputs/output<N>/expected.out using diff -iw semantics (case and whitespace
insensitive, blank lines still count).

  Questa (used by `make vsim-dut-c` / `make vsim-dut`):
      run_tests.py --sim questa --test -1 --lib build/dut/work --ini build/dut/modelsim.ini \
                   --workdir build/dut --simout build/dut/outputs
  Verilator (optional, for quick local checks without a Questa licence):
      run_tests.py --sim verilator --test -1 --workdir build/verilator --simout build/verilator/outputs
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def norm(path):
    with open(path) as f:
        return [re.sub(r"\s+", "", ln).lower() for ln in f.read().split("\n")]


def compare(got, exp):
    g, e = norm(got), norm(exp)
    while g and g[-1] == "":
        g.pop()
    while e and e[-1] == "":
        e.pop()
    if g == e:
        return None
    for i in range(max(len(g), len(e))):
        a = g[i] if i < len(g) else "<missing>"
        b = e[i] if i < len(e) else "<missing>"
        if a != b:
            return f"first difference at line {i + 1}:\n    got: {a}\n    exp: {b}"
    return "length mismatch"


def params(cfg):
    return [f"T_{k}={cfg[k]}" for k in
            ("BLOCKSIZE", "L1_SIZE", "L1_ASSOC", "L2_SIZE", "L2_ASSOC", "PREF_N", "PREF_M")]


def run_questa(a, n, cfg, trace, out, extra):
    cmd = [a.vsim, "-c" if not a.gui else "-gui", "-64", "-modelsimini", a.ini, "-voptargs=+acc",
           f"{a.lib}.tb"] + [f"-G{p}" for p in params(cfg)] + \
          [f"+trace={trace}", f"+out={out}", f"+tracename=trace{n}.txt"] + extra
    if a.gui:
        cmd += ["+stop", "-do", os.path.join(ROOT, "do", "waves.do")]
    else:
        cmd += ["-do", "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0"]
    return subprocess.run(cmd, cwd=a.workdir, capture_output=not a.gui, text=True)


def run_verilator(a, n, cfg, trace, out, extra):
    mdir = os.path.join(a.workdir, f"case{n}")
    exe = os.path.join(mdir, "simv")
    srcs = sorted(glob.glob(os.path.join(ROOT, "srcs", "rtl", "*.sv"))) + [os.path.join(ROOT, "srcs", "tb", "tb.sv")]
    cmd = ["verilator", "--binary", "--timing", "-sv", "-Wno-fatal", "-Wno-lint", "-Wno-style",
           "--top-module", "tb", "--Mdir", mdir, "-o", "simv", "-O3"] + \
          [f"-G{p}" for p in params(cfg)] + srcs
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return r
    return subprocess.run([exe, f"+trace={trace}", f"+out={out}", f"+tracename=trace{n}.txt"] + extra,
                          capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", choices=["questa", "verilator"], default="questa")
    ap.add_argument("--test", type=int, default=-1)
    ap.add_argument("--lib", default="work")
    ap.add_argument("--ini", default="modelsim.ini")
    ap.add_argument("--vsim", default="vsim")
    ap.add_argument("--workdir", default=os.path.join(ROOT, "build"))
    ap.add_argument("--simout", default=None, help="where sim reports are written")
    ap.add_argument("--bubble", type=int, default=0, help="+bubble=<pct> idle cycles between requests")
    ap.add_argument("--gui", action="store_true")
    a = ap.parse_args()

    a.workdir = os.path.abspath(a.workdir)
    a.lib, a.ini = os.path.abspath(a.lib), os.path.abspath(a.ini)
    simout = os.path.abspath(a.simout or os.path.join(a.workdir, "outputs"))
    os.makedirs(a.workdir, exist_ok=True)

    cases = sorted(int(re.search(r"input(\d+)$", d).group(1))
                   for d in glob.glob(os.path.join(ROOT, "inputs", "input*")))
    if a.test >= 0:
        cases = [a.test]
    elif a.gui:
        cases = cases[:1]

    extra = [f"+bubble={a.bubble}"] if a.bubble else []
    bad = 0
    for n in cases:
        idir = os.path.join(ROOT, "inputs", f"input{n}")
        with open(os.path.join(idir, "config.json")) as f:
            cfg = json.load(f)
        odir = os.path.join(simout, f"output{n}")
        os.makedirs(odir, exist_ok=True)
        out = os.path.join(odir, "sim.out")
        if os.path.exists(out):
            os.remove(out)
        t0 = time.time()
        fn = run_questa if a.sim == "questa" else run_verilator
        r = fn(a, n, cfg, os.path.join(idir, "trace.txt"), out, extra)
        log = (r.stdout or "") + (r.stderr or "")
        with open(os.path.join(odir, "sim.log"), "w") as f:
            f.write(log)
        if a.gui:
            continue
        info = next((ln for ln in log.splitlines() if "INFO[tb]" in ln), "")
        err = next((ln for ln in log.splitlines() if re.search(r"(error|fatal|tb: )", ln, re.I)
                    and "INFO[tb]" not in ln), "")
        if not os.path.exists(out):
            print(f"FAIL  case {n:2d} {cfg['name']:18s} no report produced  {err}")
            tail = [ln for ln in log.splitlines() if ln.strip()][-8:]
            print("      --- last lines of " + os.path.join(odir, "sim.log") + " ---")
            for ln in tail:
                print("      " + ln)
            bad += 1
            continue
        diff = compare(out, os.path.join(ROOT, "outputs", f"output{n}", "expected.out"))
        if diff or (err and "tb:" in err and "$error" in err):
            print(f"FAIL  case {n:2d} {cfg['name']:18s} {diff or err}")
            bad += 1
        else:
            m = re.search(r"\((\S+) cycles/request\)", info)
            print(f"PASS  case {n:2d} {cfg['name']:18s} {m.group(1) + ' cyc/req' if m else ''}  ({time.time() - t0:.1f}s)")
    if not a.gui:
        print(f"{len(cases) - bad}/{len(cases)} cases passed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
