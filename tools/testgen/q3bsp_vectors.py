#!/usr/bin/env python3
"""Reference summary of every stock map's Q3 BSP lumps for tests/integration/q3bsp_load.test.luau.

  python3 tools/testgen/q3bsp_vectors.py   -> tests/vectors/q3bsp.tsv   (needs work/vfs-high/maps/*.bsp, numpy)

An independent decoder (struct / numpy, written from the file format in model_brush.h, not from the Luau port):
counts, and a checksum of each array as the engine holds it after loading. Float arithmetic the loader does
(colour * 1/255, light grid) is done in float32.
Checksum of a byte string (zero-padded to 32-bit little-endian words w[0..n-1]), cheap in numpy and in Luau:
  a = sum(w[i]) mod 2^32
  b = sum((w[i] & 0xFFFF) * (i % 65521 + 1) + (w[i] >> 16) * (i % 65519 + 1)) mod 2^32   -> "%08x%08x" % (a, b)
"""
import math
import re
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
MAPS = ROOT / "work/vfs-high/maps"
OUT = ROOT / "tests/vectors/q3bsp.tsv"


def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


def chk(data) -> str:
    data = bytes(data)
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    w = np.frombuffer(data, "<u4").astype(np.uint64)
    i = np.arange(len(w), dtype=np.uint64)
    a = int(w.sum()) & 0xFFFFFFFF
    b = int(((w & 0xFFFF) * (i % 65521 + 1) + (w >> 16) * (i % 65519 + 1)).sum()) & 0xFFFFFFFF
    return f"{a:08x}{b:08x}"


def supercontents(native: int) -> int:
    native &= 0xFFFFFFFF
    table = ((0x1, 0x1), (0x20, 0x2), (0x10, 0x4), (0x8, 0x8), (0x02000000, 0x20), (0x04000000, 0x40),
             (0x80000000, 0x80), (0x10000, 0x100), (0x20000, 0x200), (0x200000, 0x400), (0x400000, 0x800))
    s = 0
    for q3, sup in table:
        if native & q3:
            s |= sup
    if not native & 0x20000000:
        s |= 0x1000
    return s


VERT = np.dtype([("origin", "<f4", 3), ("tc", "<f4", 2), ("lm", "<f4", 2), ("normal", "<f4", 3), ("color", "u1", 4)])


def one(path: Path) -> list[str]:
    d = path.read_bytes()
    assert d[:4] == b"IBSP"
    version = struct.unpack_from("<i", d, 4)[0]
    L = [struct.unpack_from("<ii", d, 8 + 8 * i) for i in range(17)]
    lumps = [d[o:o + n] for o, n in L]  # sliced once: slicing inside the loops below would copy a lump per item
    lump = lambda i: lumps[i]
    ent = lump(0).split(b"\0")[0]
    # textures
    tex = [(lump(1)[i:i + 64].split(b"\0")[0],) + struct.unpack_from("<iI", lump(1), i + 64) for i in range(0, L[1][1], 72)]
    texsuper = [supercontents(c) for _, _, c in tex]
    htex = chk(b"".join(n + b"\0" + struct.pack("<iI", sf, texsuper[i]) for i, (n, sf, _) in enumerate(tex)))
    # planes: normal dist type signbits
    pl = bytearray()
    for i in range(0, L[2][1], 16):
        nx, ny, nz, _ = struct.unpack_from("<4f", lump(2), i)
        typ = 0 if nx == 1 else 1 if ny == 1 else 2 if nz == 1 else 3
        sign = (1 if nx < 0 else 0) | (2 if ny < 0 else 0) | (4 if nz < 0 else 0)
        pl += lump(2)[i:i + 16] + struct.pack("<ii", typ, sign)
    # brush sides / brushes
    side = 12 if version == 48 else 8
    sides = [struct.unpack_from("<ii", lump(9), i) for i in range(0, L[9][1], side)]
    brushes = [struct.unpack_from("<iii", lump(8), i) for i in range(0, L[8][1], 12)]
    # vertices
    v = np.frombuffer(lump(10), VERT)
    nv = len(v)
    col = (v["color"].astype(np.float32) * np.float32(1.0 / 255.0)).astype("<f4")
    lit = bool((v["color"][:, :3] != 255).any()) if nv else False
    # triangles
    e = np.frombuffer(lump(11), "<i4")
    ne = len(e)
    if nv:
        el = np.where((e < 0) | (e >= nv), 0, e).astype("<i4").tobytes()
    else:
        ne, el = 0, b""
    # models
    models = lump(7)
    # leafs / nodes
    leafs = [struct.unpack_from("<12i", lump(4), i) for i in range(0, L[4][1], 48)]
    leafbrushes = [x for (x,) in struct.iter_unpack("<i", lump(6))]
    leafsurfaces = [x for (x,) in struct.iter_unpack("<i", lump(5))]
    faces = lump(13)
    nodes = [struct.unpack_from("<9i", lump(3), i) for i in range(0, L[3][1], 36)]
    # the tree below node 0: combinedsupercontents is only set on nodes and leafs the engine reaches from the
    # root (Mod_Q1BSP_LoadNodes_RecursiveSetParent); leafs outside it (submodel leafs) stay 0
    numleafs = 0
    order = []
    reached = set()
    stack = [0]
    while stack:
        n = stack.pop()
        order.append(n)
        for ch in nodes[n][1:3]:
            if ch >= 0:
                stack.append(ch)
            else:
                reached.add(-1 - ch)
                numleafs = max(numleafs, -1 - ch + 1)
    leafcomb = []
    hl = bytearray()
    for li, (cl, ar, a, b, c, e1, f, g, fs, ns, fb, nb) in enumerate(leafs):
        comb = 0
        if li in reached:
            for j in range(nb):
                comb |= texsuper[brushes[leafbrushes[fb + j]][2]]
            # collision surfaces = patches (a valid patch always tesselates to collision triangles)
            for j in range(ns):
                tx, _, typ, _, nverts, _, _ = struct.unpack_from("<7i", faces, leafsurfaces[fs + j] * 104)
                pw, ph = struct.unpack_from("<2i", faces, leafsurfaces[fs + j] * 104 + 96)
                if typ == 2 and nverts == pw * ph and pw >= 3 and ph >= 3 and pw & 1 and ph & 1 and pw * ph < 4225:
                    comb |= texsuper[tx]
        leafcomb.append(comb)
        hl += struct.pack("<ii6fiiiiI", cl, ar, a - 1, b - 1, c - 1, e1 + 1, f + 1, g + 1, fs, ns, fb, nb, comb)
    nodecomb = [0] * len(nodes)
    for n in reversed(order):  # children before parents
        comb = 0
        for ch in nodes[n][1:3]:
            comb |= nodecomb[ch] if ch >= 0 else leafcomb[-1 - ch]
        nodecomb[n] = comb
    hn = bytearray()
    for i, (p, c0, c1, a, b, c, e1, f, g) in enumerate(nodes):
        hn += struct.pack("<iii6fI", p, c0, c1, a - 1, b - 1, c - 1, e1 + 1, f + 1, g + 1, nodecomb[i])
    # pvs
    if L[16][1] == 0:
        ncl = max([1] + [l[0] + 1 for l in leafs])
        nby = (ncl + 7) // 8
        pvs = b"\xff" * (ncl * nby)
    else:
        ncl, nby = struct.unpack_from("<ii", lump(16), 0)
        pvs = lump(16)[8:8 + ncl * nby]
    # worldspawn keys (first entity): a leading _ is dropped from the key, trailing spaces too
    world = {}
    toks = re.findall(rb'"([^"]*)"', ent.split(b"}")[0])
    for k, val in zip(toks[0::2], toks[1::2]):
        k = (k[1:] if k[:1] == b"_" else k).rstrip(b" ")
        world.setdefault(k, []).append(val)
    # light grid cell size: 64 64 128 unless a gridsize key (any case) gives three non-zero numbers; sscanf
    # stops at the first thing that is not a number and leaves the remaining defaults
    cell = [64.0, 64.0, 128.0]
    for k, vals in world.items():
        if k.lower() == b"gridsize":
            for val in vals:
                g = [64.0, 64.0, 128.0]
                m = re.match(rb"\s*([-+0-9.eE]+)(?:\s+([-+0-9.eE]+))?(?:\s+([-+0-9.eE]+))?", val)
                if m:
                    for i in range(3):
                        if m.group(i + 1) is not None:
                            g[i] = f32(float(m.group(i + 1)))
                if g[0] != 0 and g[1] != 0 and g[2] != 0:
                    cell = g
    deluxe = any(val in (b"1", b"2") for val in world.get(b"deluxeMaps", [])[-1:])
    mins = struct.unpack_from("<3f", models, 0)
    maxs = struct.unpack_from("<3f", models, 12)
    scale = [f32(1.0 / c) for c in cell]
    imins = [math.ceil(f32(mins[k] * scale[k])) for k in range(3)]
    imaxs = [math.floor(f32(maxs[k] * scale[k])) for k in range(3)]
    isize = [imaxs[k] - imins[k] + 1 for k in range(3)]
    gcount = isize[0] * isize[1] * isize[2]
    grid = lump(15)[:gcount * 8] if L[15][1] >= gcount * 8 else b""
    # indexfromworld = Matrix4x4_CreateScale3 then Matrix4x4_ConcatTranslate(-imins * cellsize): out = base x temp,
    # every product and sum rounded to float32 (matrix4x4_t is float), row-major (no MATRIX4x4_OPENGLORIENTATION)
    base = [[scale[0], 0.0, 0.0, 0.0], [0.0, scale[1], 0.0, 0.0], [0.0, 0.0, scale[2], 0.0], [0.0, 0.0, 0.0, 1.0]]
    tr = [f32(-imins[k] * cell[k]) for k in range(3)]
    temp = [[1.0, 0.0, 0.0, tr[0]], [0.0, 1.0, 0.0, tr[1]], [0.0, 0.0, 1.0, tr[2]], [0.0, 0.0, 0.0, 1.0]]
    mat = []
    for r in range(4):
        for c in range(4):
            acc = f32(base[r][0] * temp[0][c])
            for k in range(1, 4):
                acc = f32(acc + f32(base[r][k] * temp[k][c]))
            mat.append(acc)
    return [path.stem, str(version), chk(ent), "1" if deluxe else "0",
            str(len(tex)), htex,
            str(L[2][1] // 16), chk(pl),
            str(len(sides)), chk(b"".join(struct.pack("<ii", *s) for s in sides)),
            str(len(brushes)), chk(b"".join(struct.pack("<iii", *b) for b in brushes)),
            str(L[12][1] // 72),
            str(nv), chk(v["origin"].tobytes()), chk(v["normal"].tobytes()), chk(v["tc"].tobytes()),
            chk(v["lm"].tobytes()), chk(col.tobytes()), "1" if lit else "0",
            str(ne // 3), chk(el),
            str(L[13][1] // 104),
            str(L[7][1] // 40), chk(models),
            str(len(leafbrushes)), chk(lump(6)), str(L[5][1] // 4), chk(lump(5)),
            str(len(leafs)), chk(hl), str(len(nodes)), chk(hn), str(numleafs),
            str(ncl), str(nby), chk(pvs),
            " ".join(f"{f32(x):g}" for x in cell), " ".join(map(str, imins)), " ".join(map(str, isize)),
            str(len(grid) // 8), chk(grid),
            chk(struct.pack("<16f", *mat))]


def main() -> None:
    rows = [one(p) for p in sorted(MAPS.glob("*.bsp"))]
    head = ("# map\tversion\tentities\tdeluxe\ttextures\th\tplanes\th\tbrushsides\th\tbrushes\th\teffects\tvertices\tvertex3f\t"
            "normal3f\ttexcoordtexture2f\ttexcoordlightmap2f\tcolor4f\tlit\ttriangles\telement3i\tsurfaces\tmodels\th\t"
            "leafbrushes\th\tleafsurfaces\th\tleafs\th\tnodes\th\tnum_leafs\tpvsclusters\tpvsclusterbytes\tpvs\t"
            "lightgrid cellsize\timins\tisize\tlightgrid\th\tindexfromworld")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(head + "\n" + "".join("\t".join(r) + "\n" for r in rows))
    print(len(rows), "maps ->", OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
