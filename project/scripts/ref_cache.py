#!/usr/bin/env python3
"""
Reference model of the memory-hierarchy spec (L1 [+ L2], LRU, WBWA, stream-buffer
prefetch in the last level), used as the golden output for the RTL regression.

It is intentionally written differently from the RTL:
  * LRU is kept as per-way recency counters (not a move-to-front stack),
  * every stream buffer holds its M blocks explicitly and is managed exactly as
    in Figure 2 of the spec (remove through the hit, shift, refill).
If the two agree on long traces, the RTL's compact representation
(stack rows, {valid, head-block} stream buffers) is equivalent.

usage: ref_cache.py <trace> <out> [--name NAME] --bs N --l1 SIZE ASSOC
                    [--l2 SIZE ASSOC] [--pref N M]
"""
import argparse


class StreamBuffers:
    def __init__(self, n, m):
        self.n, self.m = n, m
        self.blocks = [[] for _ in range(n)]      # explicit M blocks per buffer
        self.valid = [False] * n
        self.rank = list(range(n))                # 0 = MRU

    def _touch(self, i):
        r = self.rank[i]
        for j in range(self.n):
            if self.rank[j] < r:
                self.rank[j] += 1
        self.rank[i] = 0

    def lookup(self, x):
        """MRU-most buffer holding block x (None if none). Whole buffer searched."""
        for i in sorted(range(self.n), key=lambda k: self.rank[k]):
            if self.valid[i] and x in self.blocks[i]:
                return i
        return None

    def advance(self, i, x):
        """Scenario 2/4: remove blocks through x, shift, refill. Returns #prefetches."""
        buf = self.blocks[i]
        pos = buf.index(x)
        del buf[:pos + 1]
        issued = 0
        while len(buf) < self.m:
            buf.append((buf[-1] if buf else x) + 1)
            issued += 1
        self._touch(i)
        return issued

    def new_stream(self, x):
        """Scenario 1: recycle the LRU buffer. Returns #prefetches (= M)."""
        i = max(range(self.n), key=lambda k: self.rank[k])
        self.blocks[i] = [x + 1 + k for k in range(self.m)]
        self.valid[i] = True
        self._touch(i)
        return self.m

    def contents(self):
        """valid buffers, MRU -> LRU"""
        order = sorted(range(self.n), key=lambda k: self.rank[k])
        return [list(self.blocks[i]) for i in order if self.valid[i]]


class Cache:
    def __init__(self, size, assoc, bs, pref_n=0, pref_m=0, nxt=None):
        self.bs, self.assoc = bs, assoc
        self.sets = size // (assoc * bs)
        assert self.sets * assoc * bs == size and (self.sets & (self.sets - 1)) == 0
        self.nxt = nxt
        self.valid = [[False] * assoc for _ in range(self.sets)]
        self.dirty = [[False] * assoc for _ in range(self.sets)]
        self.tag = [[0] * assoc for _ in range(self.sets)]
        self.rank = [list(range(assoc)) for _ in range(self.sets)]   # 0 = MRU
        self.sb = StreamBuffers(pref_n, pref_m) if pref_n > 0 else None
        self.reads = self.rmiss = self.writes = self.wmiss = self.wb = self.pref = 0

    def _touch(self, s, w):
        r = self.rank[s][w]
        for j in range(self.assoc):
            if self.rank[s][j] < r:
                self.rank[s][j] += 1
        self.rank[s][w] = 0

    def access(self, blk, is_write):
        s, t = blk % self.sets, blk // self.sets
        if is_write:
            self.writes += 1
        else:
            self.reads += 1

        way = next((w for w in range(self.assoc) if self.valid[s][w] and self.tag[s][w] == t), None)
        sbi = self.sb.lookup(blk) if self.sb else None

        if way is not None:                                   # hit in cache
            self._touch(s, way)
            if is_write:
                self.dirty[s][way] = True
            if sbi is not None:                               # scenario 4
                self.pref += self.sb.advance(sbi, blk)
            return                                            # (scenario 3: nothing)

        # miss in cache: step 1 - make space
        inv = [w for w in range(self.assoc) if not self.valid[s][w]]
        if inv:
            way = inv[0]
        else:
            way = max(range(self.assoc), key=lambda w: self.rank[s][w])
            if self.dirty[s][way]:
                self.wb += 1
                if self.nxt:
                    self.nxt.access(self.tag[s][way] * self.sets + s, True)

        # step 2 - bring in the block
        if sbi is not None:                                   # scenario 2
            self.pref += self.sb.advance(sbi, blk)
        else:
            if is_write:
                self.wmiss += 1
            else:
                self.rmiss += 1
            if self.nxt:
                self.nxt.access(blk, False)
            if self.sb:                                       # scenario 1
                self.pref += self.sb.new_stream(blk)

        self.valid[s][way] = True
        self.tag[s][way] = t
        self.dirty[s][way] = is_write
        self._touch(s, way)

    def contents(self):
        """[(set, [(tag, dirty), ...] MRU->LRU)] for non-empty sets"""
        out = []
        for s in range(self.sets):
            ws = [w for w in range(self.assoc) if self.valid[s][w]]
            ws.sort(key=lambda w: self.rank[s][w])
            if ws:
                out.append((s, [(self.tag[s][w], self.dirty[s][w]) for w in ws]))
        return out


def rate(num, den):
    return num / den if den else 0.0


def run(trace, bs, l1, l2, pref, name):
    n, m = pref
    last_is_l2 = l2[0] > 0
    c2 = Cache(l2[0], l2[1], bs, n, m) if last_is_l2 else None
    c1 = Cache(l1[0], l1[1], bs, 0 if last_is_l2 else n, m, c2)
    off = bs.bit_length() - 1
    with open(trace) as f:
        for line in f:
            p = line.split()
            if len(p) != 2:
                continue
            c1.access(int(p[1], 16) >> off, p[0].lower() == "w")

    o = []
    o += ["===== Simulator configuration =====",
          f"BLOCKSIZE:  {bs}", f"L1_SIZE:    {l1[0]}", f"L1_ASSOC:   {l1[1]}",
          f"L2_SIZE:    {l2[0]}", f"L2_ASSOC:   {l2[1] if last_is_l2 else 0}",
          f"PREF_N:     {n}", f"PREF_M:     {m if n > 0 else 0}",
          f"trace_file: {name}", ""]

    def lvl(c):
        r = []
        for s, ents in c.contents():
            r.append(f"set {s}:" + "".join(f" {t:x}" + (" D" if d else "") for t, d in ents))
        return r

    o += ["===== L1 contents ====="] + lvl(c1) + [""]
    if c2:
        o += ["===== L2 contents ====="] + lvl(c2) + [""]
    if n > 0:
        last = c2 if c2 else c1
        o += ["===== Stream Buffer(s) contents ====="]
        for b in last.sb.contents():
            o.append("".join(f" {x:x}" for x in b))
        o += [""]

    z2 = c2 or Cache(l1[0], l1[1], bs)           # all-zero stand-in when no L2
    traffic = (z2.rmiss + z2.wmiss + z2.wb + z2.pref) if c2 else \
              (c1.rmiss + c1.wmiss + c1.wb + c1.pref)
    L = lambda s, v: f"{s:<48}{v}"
    o += ["===== Measurements =====",
          L("a. L1 reads:", c1.reads),
          L("b. L1 read misses:", c1.rmiss),
          L("c. L1 writes:", c1.writes),
          L("d. L1 write misses:", c1.wmiss),
          L("e. L1 miss rate:", f"{rate(c1.rmiss + c1.wmiss, c1.reads + c1.writes):.4f}"),
          L("f. L1 writebacks:", c1.wb),
          L("g. L1 prefetches:", c1.pref),
          L("h. L2 reads (demand):", z2.reads if c2 else 0),
          L("i. L2 read misses (demand):", z2.rmiss if c2 else 0),
          L("j. L2 reads (prefetch):", 0),
          L("k. L2 read misses (prefetch):", 0),
          L("l. L2 writes:", z2.writes if c2 else 0),
          L("m. L2 write misses:", z2.wmiss if c2 else 0),
          L("n. L2 miss rate:", f"{rate(z2.rmiss, z2.reads) if c2 else 0.0:.4f}"),
          L("o. L2 writebacks:", z2.wb if c2 else 0),
          L("p. L2 prefetches:", z2.pref if c2 else 0),
          L("q. memory traffic:", traffic)]
    return "\n".join(o) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("out")
    ap.add_argument("--name")
    ap.add_argument("--bs", type=int, required=True)
    ap.add_argument("--l1", type=int, nargs=2, required=True, metavar=("SIZE", "ASSOC"))
    ap.add_argument("--l2", type=int, nargs=2, default=[0, 0], metavar=("SIZE", "ASSOC"))
    ap.add_argument("--pref", type=int, nargs=2, default=[0, 0], metavar=("N", "M"))
    a = ap.parse_args()
    txt = run(a.trace, a.bs, a.l1, a.l2, a.pref, a.name or a.trace)
    with open(a.out, "w") as f:
        f.write(txt)


if __name__ == "__main__":
    main()
