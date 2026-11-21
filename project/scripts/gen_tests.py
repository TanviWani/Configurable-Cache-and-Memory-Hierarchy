#!/usr/bin/env python3
"""
Generate the regression cases:
    inputs/input<N>/trace.txt   deterministic synthetic trace
    inputs/input<N>/config.json cache geometry of the case
    outputs/output<N>/expected.out   golden report from scripts/ref_cache.py

The traces mix sequential streams (to exercise the stream buffers incl. several
streams / redundant streams), backward streams, set-conflict loops (associativity
and LRU), a hot working set (hits, dirty blocks) and wide random traffic (misses,
write-backs).  Same seeds -> same files.
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cache  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NREQ = 12000

# name, bs, (l1 size, assoc), (l2 size, assoc), (pref N, M)
CASES = [
    ("l1_dm",            16, (1024, 1),  (0, 0),       (0, 0)),
    ("l1_4way",          32, (2048, 4),  (0, 0),       (0, 0)),
    ("l1_fully_assoc",   32, (512, 16),  (0, 0),       (0, 0)),
    ("l1_l2",            32, (1024, 2),  (8192, 4),    (0, 0)),
    ("l1_l2_odd_assoc",  32, (768, 3),   (6144, 6),    (0, 0)),
    ("l1_pref_1x4",      32, (1024, 2),  (0, 0),       (1, 4)),
    ("l1_pref_4x8",      32, (2048, 4),  (0, 0),       (4, 8)),
    ("l1_l2_pref_3x10",  32, (1024, 2),  (16384, 8),   (3, 10)),
    ("l1_l2_dm_bs64",    64, (2048, 1),  (16384, 1),   (0, 0)),
    ("l1_pref_2x1",      32, (1024, 2),  (0, 0),       (2, 1)),
    ("l2_fully_assoc",   32, (1024, 1),  (2048, 64),   (0, 0)),
    ("bs128_l2_pref",    128, (4096, 2), (16384, 4),   (2, 5)),
    ("l1_l2_pref_8x16",  32, (512, 2),   (4096, 4),    (8, 16)),
    ("l1_pref_3x3_bs16", 16, (1024, 2),  (0, 0),       (3, 3)),
    ("tiny_thrash",      32, (128, 1),   (256, 2),     (1, 1)),
]


def gen_trace(rng, n, bs, l1_size, l1_assoc):
    sets = l1_size // (l1_assoc * bs)
    conflict_stride = sets * bs                     # same L1 set
    out = []
    while len(out) < n:
        mode = rng.choice(["stream", "stream", "stream", "back", "hot", "wide", "conflict", "mixed"])
        cnt = rng.randint(300, 1200)
        wp = rng.choice([0.05, 0.2, 0.35, 0.6])
        if mode == "stream":                        # 1..6 interleaved ascending streams
            k = rng.randint(1, 6)
            step = rng.choice([4, 4, 8, bs, bs, 2 * bs])
            base = [rng.randrange(0x1000_0000, 0x3000_0000) & ~3 for _ in range(k)]
            for _ in range(cnt):
                i = rng.randrange(k)
                out.append((rng.random() < wp, base[i]))
                base[i] += step
        elif mode == "back":                        # descending streams
            k = rng.randint(1, 4)
            step = rng.choice([4, bs, bs])
            base = [rng.randrange(0x4000_0000, 0x5000_0000) & ~3 for _ in range(k)]
            for _ in range(cnt):
                i = rng.randrange(k)
                out.append((rng.random() < wp, base[i]))
                base[i] -= step
        elif mode == "hot":                         # small working set with reuse
            foot = rng.choice([l1_size // 2, l1_size, 2 * l1_size, 8 * l1_size])
            base = rng.randrange(0x2000_0000, 0x2800_0000) & ~(bs - 1)
            for _ in range(cnt):
                out.append((rng.random() < wp, base + (rng.randrange(foot) & ~3)))
        elif mode == "wide":                        # mostly misses
            for _ in range(cnt):
                out.append((rng.random() < wp, rng.randrange(0x0010_0000, 0x7000_0000) & ~3))
        elif mode == "conflict":                    # associativity / LRU stress
            nb = l1_assoc + rng.randint(0, 3)
            base = rng.randrange(0x5000_0000, 0x6000_0000) & ~(conflict_stride - 1)
            for _ in range(cnt):
                j = rng.randrange(nb)
                out.append((rng.random() < wp, base + j * conflict_stride * 1 + (rng.randrange(bs) & ~3)))
        else:                                       # mixed: stream + hot
            base = rng.randrange(0x1000_0000, 0x3000_0000) & ~3
            hot = rng.randrange(0x6000_0000, 0x6100_0000) & ~(bs - 1)
            for _ in range(cnt):
                if rng.random() < 0.5:
                    out.append((rng.random() < wp, base))
                    base += bs
                else:
                    out.append((rng.random() < wp, hot + (rng.randrange(l1_size) & ~3)))
    return out[:n]


def main():
    for n, (name, bs, l1, l2, pref) in enumerate(CASES):
        rng = random.Random(1000 + n)
        tr = gen_trace(rng, NREQ, bs, l1[0], l1[1])
        idir = os.path.join(ROOT, "inputs", f"input{n}")
        odir = os.path.join(ROOT, "outputs", f"output{n}")
        os.makedirs(idir, exist_ok=True)
        os.makedirs(odir, exist_ok=True)
        tpath = os.path.join(idir, "trace.txt")
        with open(tpath, "w") as f:
            for w, a in tr:
                f.write(f"{'w' if w else 'r'} {a & 0xFFFFFFFF:x}\n")
        cfg = {"name": name, "BLOCKSIZE": bs, "L1_SIZE": l1[0], "L1_ASSOC": l1[1],
               "L2_SIZE": l2[0], "L2_ASSOC": l2[1], "PREF_N": pref[0], "PREF_M": pref[1]}
        with open(os.path.join(idir, "config.json"), "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        txt = ref_cache.run(tpath, bs, l1, l2, pref, f"trace{n}.txt")
        with open(os.path.join(odir, "expected.out"), "w") as f:
            f.write(txt)
        print(f"case {n:2d} {name:18s} -> {NREQ} requests")


if __name__ == "__main__":
    main()
