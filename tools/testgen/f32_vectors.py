#!/usr/bin/env python3
"""Generate float32 reference vectors for tests/unit/f32.test.luau.

The reference is numpy's float32 arithmetic, i.e. real IEEE-754 single precision
(round-to-nearest-even), the same as DarkPlaces' C `float` on x86-64 SSE without FMA.
This is independent of the Luau implementation under test.

Output: tests/vectors/f32.txt, one case per line, hex bit patterns:
  C <f64bits> <f32bits>              conversion double -> float
  A|S|M|D <a32> <b32> <r32>          a+b, a-b, a*b, a/b computed in float32
  Q <a32> <r32>                      sqrtf(a)
Deterministic (fixed seed). Usage: python3 tools/testgen/f32_vectors.py
"""
import struct, sys, pathlib
import numpy as np

rng = np.random.default_rng(20261120)
np.seterr(all="ignore")  # overflow-to-inf is an expected, tested result
out = []

def f64bits(x): return struct.unpack("<Q", struct.pack("<d", float(x)))[0]
def f32bits(x): return int(np.float32(x).view(np.uint32))

# --- conversions ---
edge = [0.0, -0.0, 1.0, -1.0, 0.1, 1/3, 3.4028234663852886e38, 3.4028235677973366e38,  # FLT_MAX, just below overflow tie
        3.402823669209385e38, 1e39, -1e39, float("inf"), float("-inf"),
        1.401298464324817e-45, 7.006492321624085e-46, 7.006492321624087e-46, 1e-46, 1.1754943508222875e-38,
        1.1754942106924411e-38, 16777217.0, 16777219.0, 33554434.0, 0.0333333, 0.0166667, 0.01388889, 1e10, 123456789.123]
for x in edge:
    out.append(f"C {f64bits(x):016x} {f32bits(np.float64(x).astype(np.float32)):08x}")
# exact ties between adjacent floats (round-half-even must be exercised)
for _ in range(500):
    a = rng.integers(0x00800000, 0x7f000000, dtype=np.uint32)
    lo = np.uint32(a).view(np.float32).astype(np.float64); hi = np.uint32(a + 1).view(np.float32).astype(np.float64)
    mid = (lo + hi) / 2  # exactly representable in double
    for x in (mid, -mid, np.nextafter(mid, 0), np.nextafter(mid, np.inf)):
        out.append(f"C {f64bits(x):016x} {f32bits(np.float64(x).astype(np.float32)):08x}")
# random doubles over the full exponent range incl. subnormal/overflow results
for _ in range(3000):
    bits = rng.integers(0, 2**63, dtype=np.uint64) | (np.uint64(rng.integers(0, 2)) << np.uint64(63))
    x = np.uint64(bits).view(np.float64)
    if np.isnan(x): continue
    e = rng.integers(-160, 140)
    x = np.float64(rng.standard_normal()) * np.float64(2.0) ** e if rng.random() < 0.7 else x
    with np.errstate(over="ignore"):
        out.append(f"C {f64bits(x):016x} {f32bits(np.float64(x).astype(np.float32)):08x}")

# --- float32 arithmetic ---
def rand_f32():
    r = rng.random()
    if r < 0.6:   v = np.float32(rng.standard_normal() * 10.0 ** rng.integers(-6, 6))   # game-like magnitudes
    elif r < 0.9: v = np.float32(rng.uniform(-8192, 8192))                              # map coordinates
    else:         v = np.uint32(rng.integers(0, 0x7f800000)).view(np.float32) * np.float32(1 - 2 * rng.integers(0, 2))
    return np.float32(v)
with np.errstate(all="ignore"):
    for op, fn in (("A", np.add), ("S", np.subtract), ("M", np.multiply), ("D", np.divide)):
        for _ in range(1500):
            a, b = rand_f32(), rand_f32()
            if op == "D" and b == 0: continue
            r = fn(a, b)
            out.append(f"{op} {f32bits(a):08x} {f32bits(b):08x} {f32bits(r):08x}")
    for _ in range(1000):
        a = abs(rand_f32())
        out.append(f"Q {f32bits(a):08x} {f32bits(np.sqrt(a)):08x}")

path = pathlib.Path(__file__).resolve().parents[2] / "tests/vectors/f32.txt"
path.write_text("\n".join(out) + "\n")
print(f"wrote {len(out)} cases to {path}", file=sys.stderr)
