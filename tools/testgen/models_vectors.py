#!/usr/bin/env python3
"""Reference summary of every alias / sprite model of the release for tests/integration/model_alias.test.luau.

  python3 -I tools/testgen/models_vectors.py   -> tests/vectors/models.tsv   (needs work/vfs-high, numpy)

An independent decoder (struct / numpy, written from the file formats of model_alias.h, modelgen.h, model_iqm.h,
model_dpmodel.h, model_zymotic.h and spritegn.h, not from the Luau port) of every md3 / iqm / dpm / zym / mdl /
spr / sp2 file the engine would load (by magic, as Mod_LoadModel dispatches), plus its .skin and .framegroups
files. Per model: the counts, frame / bone / tag names, the element, bind-pose vertex, texture coordinate and
bone pose arrays as checksums, and the bounding boxes and radius, all computed in float32 where the loader works
in float. A value the decoder cannot compute without the skeletal animation pipeline is "*" (not checked):
  * dpm / zym: the bone poses (data_poses7s, through Matrix4x4_ToBonePose7s) and the boxes / radius
    (Mod_Alias_CalculateBoundingBox animates every pose through the skeletal vertex code);
  * iqm without a bounds lump: the boxes / radius (same reason).
Checksum of a byte string (zero-padded to 32-bit little-endian words w[0..n-1]), as q3bsp_vectors.py:
  a = sum(w[i]) mod 2^32
  b = sum((w[i] & 0xFFFF) * (i % 65521 + 1) + (w[i] >> 16) * (i % 65519 + 1)) mod 2^32   -> "%08x%08x" % (a, b)
"""
import math
import re
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
VFS = ROOT / "work/vfs-high"
MANIFEST = ROOT / "assets/manifest/vfs-high.tsv"
OUT = ROOT / "tests/vectors/models.tsv"

F = np.float32
np.seterr(all="ignore")


def chk(data) -> str:
    if data is None:
        return "-"
    data = bytes(data)
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    w = np.frombuffer(data, "<u4").astype(np.uint64)
    i = np.arange(len(w), dtype=np.uint64)
    a = int(w.sum()) & 0xFFFFFFFF
    b = int(((w & 0xFFFF) * (i % 65521 + 1) + (w >> 16) * (i % 65519 + 1)).sum()) & 0xFFFFFFFF
    return f"{a:08x}{b:08x}"


def hx(x) -> str:
    return "%08x" % struct.unpack("<I", struct.pack("<f", float(x)))[0]


def vec(v) -> str:
    return ",".join(hx(x) for x in v)


def cstr(d: bytes, o: int, maxlen=None) -> str:
    end = len(d) if maxlen is None else min(len(d), o + maxlen)
    e = d.find(b"\0", o, end)
    if e < 0:
        e = end
    return d[o:e].decode("latin-1")


def names_chk(names) -> str:
    return chk("\0".join(names).encode("latin-1"))


def toshort(x) -> int:
    x = float(x)
    if x != x or x >= 2147483648.0 or x < -2147483648.0:
        return 0
    i = int(x)  # truncation toward zero
    i &= 0xFFFF
    return i - 65536 if i >= 32768 else i


class Model:
    def __init__(self):
        self.type = "-"
        self.numframes = 0
        self.scenes = []  # (name, firstframe, framecount, loop, framerate float32)
        self.num_poses = 0
        self.bones = []  # (name, parent)
        self.tags = []
        self.num_surfaces = 0
        self.numskins = 0
        self.num_vertices = 0
        self.num_triangles = 0
        self.elements = None
        self.vertex = None
        self.texcoord = None
        self.poses = None
        self.box = None  # (normalmins, normalmaxs, yawmins, yawmaxs, rotatedmins, rotatedmaxs, radius) or "*"


def skincount(name: str, files: set) -> int:
    i = 0
    while i < 256 and f"{name}_{i}.skin" in files:
        i += 1
    return i


def validate(el: np.ndarray, first: int, num: int):
    bad = (el < first) | (el >= first + num)
    el[bad] = first


def box_from_vertices(frames):
    """Mod_Alias_CalculateBoundingBox over float32 vertex arrays (one (n, 3) array per pose)."""
    mins = maxs = None
    yaw = F(0)
    rad = F(0)
    for v in frames:
        if len(v) == 0:
            continue
        fmin, fmax = v.min(axis=0), v.max(axis=0)
        mins = fmin if mins is None else np.minimum(mins, fmin)
        maxs = fmax if maxs is None else np.maximum(maxs, fmax)
        d = (v[:, 0] * v[:, 0]) + (v[:, 1] * v[:, 1])
        r = d + (v[:, 2] * v[:, 2])
        yaw = max(yaw, d.max())
        rad = max(rad, r.max())
    if mins is None:
        mins = maxs = np.zeros(3, F)
    radius = F(math.sqrt(float(rad)))
    yawr = F(math.sqrt(float(yaw)))
    return (list(mins), list(maxs), [-yawr, -yawr, mins[2]], [yawr, yawr, maxs[2]],
            [-radius] * 3, [radius] * 3, radius)


# ---------------------------------------------------------------- md3
def md3(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "MD3"
    (version, num_frames, num_tags, num_meshes, ofs_frames, ofs_tags, ofs_meshes) = (
        struct.unpack_from("<i", d, 4)[0], *struct.unpack_from("<iii", d, 76), *struct.unpack_from("<iii", d, 92))
    assert version == 15
    m.numskins = max(skincount(name, files), 1)
    m.numframes = num_frames
    m.num_poses = num_frames
    m.scenes = [(cstr(d, ofs_frames + 56 * i + 40, 31), i, 1, 1, F(10)) for i in range(num_frames)]
    m.tags = [cstr(d, ofs_tags + 112 * i, 63) for i in range(num_tags)]
    meshes = []
    o = ofs_meshes
    for _ in range(num_meshes):
        nf, ns, nv, nt, le, ls, lt, lfv, lend = struct.unpack_from("<iiiiiiiii", d, o + 72)
        meshes.append((o, nv, nt, le, lt, lfv))
        o += lend
    m.num_surfaces = num_meshes
    tv = sum(x[1] for x in meshes)
    tt = sum(x[2] for x in meshes)
    m.num_vertices, m.num_triangles = tv, tt
    el = np.zeros(tt * 3, "<i4")
    tc = np.zeros(tv * 2, "<f4")
    origins = np.zeros((num_frames, tv, 3), F)
    fv = ft = 0
    for (o, nv, nt, le, lt, lfv) in meshes:
        e = np.frombuffer(d, "<i4", nt * 3, o + le).astype(np.int64) + fv
        e = e.astype("<i4")
        validate(e, fv, nv)
        el[ft * 3:(ft + nt) * 3] = e
        tc[fv * 2:(fv + nv) * 2] = np.frombuffer(d, "<f4", nv * 2, o + lt)
        for f in range(num_frames):
            raw = np.frombuffer(d, "<i2", nv * 4, o + lfv + f * nv * 8).reshape(nv, 4)[:, :3]
            origins[f, fv:fv + nv] = raw.astype(F)
        fv += nv
        ft += nt
    m.elements = el.tobytes()
    m.texcoord = tc.tobytes()
    scale = F(F(1) * F(1.0 / 64.0))
    verts = [origins[f] * scale for f in range(num_frames)]
    m.vertex = (verts[0].astype("<f4").tobytes() if num_frames else np.zeros(tv * 3, "<f4").tobytes())
    m.box = box_from_vertices(verts)
    return m


# ---------------------------------------------------------------- iqm
def iqm(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "IQM"
    h = struct.unpack_from("<27I", d, 16)
    (version, filesize, flags, num_text, ofs_text, num_meshes, ofs_meshes, num_vertexarrays, num_vertexes,
     ofs_vertexarrays, num_triangles, ofs_triangles, ofs_neighbors, num_joints, ofs_joints, num_poses, ofs_poses,
     num_anims, ofs_anims, num_frames, num_framechannels, ofs_frames, ofs_bounds, num_comment, ofs_comment,
     num_extensions, ofs_extensions) = h
    assert version in (1, 2)
    hastext = num_text and ofs_text

    def text(o, maxlen=None):
        return cstr(d, ofs_text + o, maxlen) if hastext else ""

    va = {}
    for i in range(num_vertexarrays):
        t, fl, fmt, size, off = struct.unpack_from("<5I", d, ofs_vertexarrays + 20 * i)
        vsize = (num_vertexes * size) & 0xFFFFFFFF
        if fmt == 7:
            vsize *= 4
        elif fmt != 1:
            continue
        if off + vsize > len(d):
            continue
        if (t, fmt, size) in ((0, 7, 3), (1, 7, 2), (2, 7, 3), (3, 7, 4), (4, 1, 4), (5, 1, 4)):
            va[t] = off
    m.numskins = max(skincount(name, files), 1)
    m.numframes = max(num_anims, 1)
    m.num_poses = max(num_frames, 1)
    m.num_surfaces = num_meshes
    m.num_vertices = num_vertexes
    m.num_triangles = num_triangles
    # joints
    jsize = 44 if version == 1 else 48
    joints = []
    for i in range(num_joints):
        o = ofs_joints + jsize * i
        nm, parent = struct.unpack_from("<Ii", d, o)
        origin = [F(x) for x in struct.unpack_from("<3f", d, o + 8)]
        nrot = 3 if version == 1 else 4
        rot = [F(x) for x in struct.unpack_from(f"<{nrot}f", d, o + 20)]
        if version == 2:
            if rot[3] > 0:
                rot = [-x for x in rot]
            il = F(math.sqrt(float(F(F(F(F(rot[0] * rot[0]) + F(rot[1] * rot[1])) + F(rot[2] * rot[2])) + F(rot[3] * rot[3])))))
            if il != 0:
                il = F(F(1) / il)
            rot = [F(x * il) for x in rot]
        joints.append((origin, rot))
        m.bones.append((text(nm, 63), parent))
    # anims
    for i in range(num_anims):
        nm, first, num, = struct.unpack_from("<III", d, ofs_anims + 20 * i)
        fr, fl = struct.unpack_from("<fI", d, ofs_anims + 20 * i + 12)
        s32 = lambda u: u - (1 << 32) if u >= (1 << 31) else u
        m.scenes.append((text(nm, 31), s32(first), s32(num), 1 if fl & 1 else 0, F(fr)))
    if num_anims <= 0:
        m.scenes.append(("static", 0, 1, 1, F(10)))
    # poses
    nch = 9 if version == 1 else 10
    psize = 80 if version == 1 else 88
    poses = []
    big = F(0)
    for i in range(num_poses):
        o = ofs_poses + psize * i
        parent, mask = struct.unpack_from("<iI", d, o)
        off = [F(x) for x in struct.unpack_from(f"<{nch}f", d, o + 8)]
        sc = [F(x) for x in struct.unpack_from(f"<{nch}f", d, o + 8 + 4 * nch)]
        poses.append((mask, off, sc))
        for k in range(3):
            big = max(big, F(abs(off[k])))
        for k in range(3):
            big = max(big, F(abs(F(off[k] + F(F(0xFFFF) * sc[k])))))
    if num_frames <= 0:
        for origin, _ in joints:
            for k in range(3):
                big = max(big, F(abs(origin[k])))
    posescale = F(big / F(32767))
    invscale = F(F(1) / posescale)
    out = []
    fd = ofs_frames
    if num_frames > 0:
        for _ in range(num_frames):
            for (mask, off, sc) in poses:
                ch = []
                for c in range(7 if version == 2 else 6):
                    if mask & (1 << c):
                        u = struct.unpack_from("<H", d, fd)[0]
                        fd += 2
                        ch.append(F(off[c] + F(F(u) * sc[c])))
                    else:
                        ch.append(F(off[c] + F(0)))
                for c in range(7 if version == 2 else 6, nch):
                    if mask & (1 << c):
                        fd += 2
                p = [toshort(F(invscale * ch[k])) for k in range(3)]
                if version == 2:
                    rot = ch[3:7]
                    if rot[3] > 0:
                        rot = [-x for x in rot]
                    il = F(math.sqrt(float(F(F(F(F(rot[0] * rot[0]) + F(rot[1] * rot[1])) + F(rot[2] * rot[2])) + F(rot[3] * rot[3])))))
                    if il != 0:
                        il = F(F(1) / il)
                    rot = [F(x * il) for x in rot]
                else:
                    qx, qy, qz = ch[3:6]
                    qw = F(F(1) - F(F(F(qx * qx) + F(qy * qy)) + F(qz * qz)))
                    qw = F(-math.sqrt(float(qw))) if qw > 0 else F(0)
                    rot = [qx, qy, qz, qw]
                p += [toshort(F(F(32767) * r)) for r in rot]
                out += p
    else:
        for origin, rot in joints:
            p = [toshort(F(invscale * origin[k])) for k in range(3)]
            if version == 2:
                q = rot
            else:
                qx, qy, qz = rot
                qw = F(F(1) - F(F(F(qx * qx) + F(qy * qy)) + F(qz * qz)))
                qw = F(-math.sqrt(float(qw))) if qw > 0 else F(0)
                q = [qx, qy, qz, qw]
            p += [toshort(F(F(32767) * r)) for r in q]
            out += p
    pose_bytes = np.array(out, "<i2").tobytes()
    want = m.num_poses * num_joints * 14
    m.poses = (pose_bytes + b"\0" * want)[:want]
    # elements, vertices
    el = np.frombuffer(d, "<i4", num_triangles * 3, ofs_triangles).copy()
    validate(el, 0, num_vertexes)
    m.elements = el.tobytes()
    if num_vertexes > 0:
        m.vertex = d[va[0]:va[0] + num_vertexes * 12]
        m.texcoord = d[va[1]:va[1] + num_vertexes * 8]
    else:
        m.vertex = m.texcoord = None
    # bounds
    if ofs_bounds:
        mins = [F(0)] * 3
        maxs = [F(0)] * 3
        xyr = F(0)
        rad = F(0)
        for i in range(num_frames):
            b = [F(x) for x in struct.unpack_from("<8f", d, ofs_bounds + 32 * i)]
            if i == 0:
                mins, maxs = b[0:3], b[3:6]
            else:
                mins = [min(mins[k], b[k]) for k in range(3)]
                maxs = [max(maxs[k], b[3 + k]) for k in range(3)]
            if b[6] > xyr:
                xyr = b[6]
            if b[7] > rad:
                rad = b[7]
        m.box = (mins, maxs, [-xyr, -xyr, mins[2]], [xyr, xyr, maxs[2]], [-rad] * 3, [rad] * 3, rad)
    else:
        m.box = "*"
    return m


# ---------------------------------------------------------------- dpm / zym (big-endian)
def concat(a, b):
    """R_ConcatTransforms on two float32[12] arrays."""
    o = [F(0)] * 12
    for r in range(3):
        for c in range(4):
            v = F(F(F(a[r * 4] * b[c]) + F(a[r * 4 + 1] * b[4 + c])) + F(a[r * 4 + 2] * b[8 + c]))
            if c == 3:
                v = F(v + a[r * 4 + 3])
            o[r * 4 + c] = v
    return o


def bonepose0(d, poses, parents):
    bp = []
    for i, parent in enumerate(parents):
        mm = [F(x) for x in struct.unpack_from(">12f", d, poses + 48 * i)]
        bp.append(concat(bp[parent], mm) if parent >= 0 else mm)
    return bp


def dpm(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "DPM"
    (typ, filesize) = struct.unpack_from(">II", d, 16)
    assert typ == 2
    num_bones, num_meshs, num_frames, ofs_bones, ofs_meshs, ofs_frames = struct.unpack_from(">6I", d, 56)
    m.numskins = max(skincount(name, files), 1)
    m.numframes = num_frames
    m.num_poses = num_frames
    m.num_surfaces = num_meshs
    for i in range(num_bones):
        o = ofs_bones + 40 * i
        m.bones.append((cstr(d, o, 32), struct.unpack_from(">i", d, o + 32)[0]))
    m.scenes = [(cstr(d, ofs_frames + 68 * i, 32), i, 1, 1, F(10)) for i in range(num_frames)]
    meshes = [struct.unpack_from(">6I", d, ofs_meshs + 56 * i + 32) for i in range(num_meshs)]
    tv = sum(x[0] for x in meshes)
    tt = sum(x[1] for x in meshes)
    m.num_vertices, m.num_triangles = tv, tt
    poses0 = struct.unpack_from(">i", d, ofs_frames + 64)[0]
    bp = bonepose0(d, poses0, [b[1] for b in m.bones])
    el = np.zeros(tt * 3, "<i4")
    tc = np.zeros(tv * 2, "<f4")
    vx = np.zeros(tv * 3, F)
    fv = ft = 0
    for (nv, nt, ofs_verts, ofs_tc, ofs_idx, _g) in meshes:
        e = np.frombuffer(d, ">i4", nt * 3, ofs_idx).astype(np.int64).reshape(nt, 3)[:, ::-1].reshape(-1) + fv
        e = e.astype("<i4")
        validate(e, fv, nv)
        el[ft * 3:(ft + nt) * 3] = e
        tc[fv * 2:(fv + nv) * 2] = np.frombuffer(d, ">f4", nv * 2, ofs_tc)
        o = ofs_verts
        for j in range(fv, fv + nv):
            nw = struct.unpack_from(">i", d, o)[0]
            o += 4
            acc = [vx[j * 3], vx[j * 3 + 1], vx[j * 3 + 2]]
            for _ in range(nw):
                ox, oy, oz, infl = (F(x) for x in struct.unpack_from(">4f", d, o))
                bone = struct.unpack_from(">i", d, o + 28)[0]
                mm = bp[bone]
                for r in range(3):
                    t = F(F(F(F(ox * mm[r * 4]) + F(oy * mm[r * 4 + 1])) + F(oz * mm[r * 4 + 2])) + F(infl * mm[r * 4 + 3]))
                    acc[r] = F(acc[r] + t)
                o += 32
            vx[j * 3:j * 3 + 3] = acc
        fv += nv
        ft += nt
    m.elements = el.tobytes()
    m.texcoord = tc.tobytes()
    m.vertex = vx.astype("<f4").tobytes()
    m.poses = "*"
    m.box = "*"
    return m


def zym(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "ZYM"
    typ = struct.unpack_from(">i", d, 12)[0]
    assert typ == 1
    numverts, numtris, numshaders, numbones, numscenes = struct.unpack_from(">5i", d, 48)
    lumps = [struct.unpack_from(">ii", d, 68 + 8 * k) for k in range(9)]
    (scenes, poses, bones, vbc, verts, texc, render, shaders, trizone) = lumps
    m.numskins = max(skincount(name, files), 1)
    m.numframes = numscenes
    m.num_surfaces = numshaders
    for i in range(numscenes):
        o = scenes[0] + 76 * i
        fr = F(struct.unpack_from(">f", d, o + 60)[0])
        flags, start, length = struct.unpack_from(">3i", d, o + 64)
        m.scenes.append((cstr(d, o, 32), start, length, 0 if flags & 1 else 1, fr))
    for i in range(numbones):
        o = bones[0] + 40 * i
        m.bones.append((cstr(d, o, 32), struct.unpack_from(">i", d, o + 36)[0]))
    m.num_poses = poses[1] // 48 // numbones
    m.num_vertices, m.num_triangles = numverts, numtris
    bp = bonepose0(d, poses[0], [b[1] for b in m.bones])
    vx = np.zeros(numverts * 3, F)
    for j in range(numverts):
        bone = struct.unpack_from(">i", d, verts[0] + 16 * j)[0]
        ox, oy, oz = (F(x) for x in struct.unpack_from(">3f", d, verts[0] + 16 * j + 4))
        mm = bp[bone]
        for r in range(3):
            vx[j * 3 + r] = F(F(F(F(ox * mm[r * 4]) + F(oy * mm[r * 4 + 1])) + F(oz * mm[r * 4 + 2])) + mm[r * 4 + 3])
    tcin = np.frombuffer(d, ">f4", numverts * 2, texc[0]).astype(F).reshape(numverts, 2)
    tcin[:, 1] = F(1) - tcin[:, 1]
    el = np.zeros(numtris * 3, "<i4")
    o = render[0]
    ft = 0
    for _ in range(numshaders):
        count = struct.unpack_from(">i", d, o)[0]
        o += 4
        e = np.frombuffer(d, ">i4", count * 3, o).astype(np.int64).reshape(count, 3)[:, ::-1].reshape(-1)
        el[ft * 3:(ft + count) * 3] = e
        o += count * 12
        ft += count
    validate(el, 0, numverts)
    m.elements = el.tobytes()
    m.texcoord = tcin.astype("<f4").tobytes()
    m.vertex = vx.astype("<f4").tobytes()
    m.poses = "*"
    m.box = "*"
    return m


# ---------------------------------------------------------------- mdl
def mdl(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "MDL"
    (version,) = struct.unpack_from("<i", d, 4)
    assert version == 6
    scale = [F(x) for x in struct.unpack_from("<3f", d, 8)]
    translate = [F(x) for x in struct.unpack_from("<3f", d, 20)]
    numskins, skinwidth, skinheight, numverts, numtris, numframes = struct.unpack_from("<6i", d, 48)
    o = 84
    totalskins = 0
    for _ in range(numskins):
        t = struct.unpack_from("<i", d, o)[0]
        o += 4
        if t == 0:
            g = 1
        else:
            g = struct.unpack_from("<i", d, o)[0]
            o += 4 + 4 * g
        o += g * skinwidth * skinheight
        totalskins += g
    stverts = [struct.unpack_from("<3i", d, o + 12 * i) for i in range(numverts)]
    o += 12 * numverts
    tris = [struct.unpack_from("<4i", d, o + 16 * i) for i in range(numtris)]
    o += 16 * numtris
    # frames: (scene name, group frame count, framerate, [trivertx arrays])
    frames = []
    for _ in range(numframes):
        t = struct.unpack_from("<i", d, o)[0]
        o += 4
        if t == 0:
            g = 1
            interval = F(0.1)
        else:
            g = struct.unpack_from("<i", d, o)[0]
            o += 12
            interval = F(struct.unpack_from("<f", d, o)[0])
            if interval < F(0.01):
                interval = F(0.1)
            o += 4 * g
        sname = cstr(d, o + 8, 31)
        poses = []
        for _ in range(g):
            o += 24
            poses.append(np.frombuffer(d, "u1", numverts * 4, o).reshape(numverts, 4))
            o += 4 * numverts
        frames.append((sname, g, F(F(1) / interval), poses))
    scales = F(1.0 / skinwidth)
    scalet = F(1.0 / skinheight)
    st = []
    for (onseam, s, t) in stverts:
        st.append((F(s * scales) if True else 0, F(t * scalet)))
    st = [(F(F(s) * scales), F(F(t) * scalet)) for (_, s, t) in stverts]
    st2 = st + [(F(float(a) + 0.5), b) for (a, b) in st]
    el = []
    for (ff, a, b, c) in tris:
        el += [a, b, c]
    el = np.array(el, np.int64)
    bad = (el < 0) | (el >= numverts)
    el[bad] = 0
    for i, (ff, *_x) in enumerate(tris):
        if ff == 0:
            for j in range(3):
                if stverts[el[i * 3 + j]][0]:
                    el[i * 3 + j] += numverts
    used = np.zeros(numverts * 2, np.int64)
    for e in el:
        used[e] += 1
    remap = np.full(numverts * 2, -1, np.int64)
    tc = []
    nv = 0
    for i in range(numverts * 2):
        if used[i]:
            remap[i] = nv
            tc.append(st2[i])
            nv += 1
    el = remap[el]
    m.numframes = numframes
    m.scenes = []
    pose = 0
    allposes = []
    for (sname, g, rate, poses) in frames:
        m.scenes.append((sname, pose, g, 1, rate))
        pose += g
        allposes += poses
    m.num_poses = pose
    m.num_surfaces = 1
    sk = skincount(name, files)
    m.numskins = sk if sk else numskins
    m.num_vertices = nv
    m.num_triangles = numtris
    m.elements = el.astype("<i4").tobytes()
    m.texcoord = np.array(tc, F).reshape(-1).astype("<f4").tobytes()
    verts = []
    for p in allposes:
        v = np.zeros((nv, 3), F)
        for i in range(numverts):
            for j in (remap[i], remap[i + numverts]):
                if j >= 0:
                    v[j] = [F(translate[k] + F(F(int(p[i][k])) * scale[k])) for k in range(3)]
        verts.append(v)
    m.vertex = verts[0].astype("<f4").tobytes() if verts else np.zeros(nv * 3, "<f4").tobytes()
    m.box = box_from_vertices(verts)
    return m


# ---------------------------------------------------------------- sprites
def spr_box(frames):
    radius = F(0)
    for (left, right, up, down) in frames:
        x = int(max(F(left * left), F(right * right)))
        y = int(max(F(up * up), F(down * down)))
        if radius < F(x + y):
            radius = F(x + y)
    r = F(math.sqrt(float(radius)))
    return ([-r] * 3, [r] * 3, [-r] * 3, [r] * 3, [-r] * 3, [r] * 3, r)


def idsp(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "SPR1"
    version = struct.unpack_from("<i", d, 4)[0]
    if version in (1, 32):
        numframes = struct.unpack_from("<i", d, 24)[0]
        o = 36
    else:
        assert version == 2
        numframes = struct.unpack_from("<i", d, 28)[0]
        o = 40 + 2 + 768
    frames = []
    for i in range(numframes):
        t = struct.unpack_from("<i", d, o)[0]
        o += 4
        if t == 0:
            g = 1
            interval = F(0.1)
        else:
            g = struct.unpack_from("<i", d, o)[0]
            o += 4
            interval = F(struct.unpack_from("<f", d, o)[0])
            o += 4 * g
        m.scenes.append((f"frame {i}", len(frames), g, 1, F(F(1) / interval)))
        for _ in range(g):
            ox, oy, w, h = struct.unpack_from("<4i", d, o)
            o += 16 + w * h * (4 if version == 32 else 1)
            frames.append((F(ox), F(ox + w), F(oy), F(oy - h)))
    m.numframes = numframes
    m.box = spr_box(frames)
    return m


def ids2(d: bytes, name: str, files: set) -> Model:
    m = Model()
    m.type = "SPR2"
    numframes = struct.unpack_from("<i", d, 8)[0]
    frames = []
    for i in range(numframes):
        w, h, ox, oy = struct.unpack_from("<4i", d, 12 + 80 * i)
        m.scenes.append((f"frame {i}", i, 1, 1, F(10)))
        frames.append((F(-ox), F(-ox + w), F(oy), F(oy - h)))
    m.numframes = numframes
    m.box = spr_box(frames)
    return m


LOADERS = {b"IDP3": md3, b"INTE": iqm, b"DARK": dpm, b"ZYMO": zym, b"IDPO": mdl, b"IDSP": idsp, b"IDS2": ids2}


# ---------------------------------------------------------------- .framegroups
def atoi(s: str) -> int:
    s = s.lstrip()
    j = 0
    if j < len(s) and s[j] in "+-":
        j += 1
    while j < len(s) and s[j].isdigit():
        j += 1
    try:
        return int(s[:j])
    except ValueError:
        return 0


def atof(s: str) -> float:
    s = s.strip()
    for j in range(len(s), 0, -1):
        try:
            return float(s[:j])
        except ValueError:
            pass
    return 0.0


def framegroups(m: Model, text: str):
    groups = []
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)  # block comments (they hold no newline token)
    for line in text.replace("\r", "\n").split("\n"):
        line = line.split("//")[0]
        tok = line.split()
        if not tok:
            continue
        if len(tok) < 2:
            continue  # "framegroups file: missing number of frames"
        start, length = atoi(tok[0]), atoi(tok[1])
        fps = F(atof(tok[2])) if len(tok) > 2 else F(20)
        loop = (atoi(tok[3]) != 0) if len(tok) > 3 else True
        nm = tok[4][:63] if len(tok) > 4 else ""
        groups.append((start, length, fps, loop, nm))
    if not groups:
        return
    m.numframes = len(groups)
    m.scenes = []
    np_ = m.num_poses
    for i, (start, length, fps, loop, nm) in enumerate(groups):
        first = (start if start < np_ - 1 else np_ - 1) if start >= 0 else 0
        hi = np_ - first
        count = (length if length < hi else hi) if length >= 1 else 1
        rate = F(1) if F(1) > fps else fps
        m.scenes.append(((nm if nm else f"groupified_{i}_anim")[:31], first, count, 1 if loop else 0, rate))


def row(name: str, m: Model) -> list:
    sc = ";".join(f"{a},{b},{c},{hx(r)}" for (_, a, b, c, r) in m.scenes)
    box = ["*"] * 7 if m.box == "*" else [vec(m.box[0]), vec(m.box[1]), vec(m.box[2]), vec(m.box[3]),
                                         vec(m.box[4]), vec(m.box[5]), hx(m.box[6])]
    return [name, m.type, str(m.numframes), names_chk([s[0] for s in m.scenes]), chk(sc.encode()),
            str(m.num_poses), str(len(m.bones)), names_chk([b[0] for b in m.bones]),
            ",".join(str(b[1]) for b in m.bones), str(len(m.tags)), names_chk(m.tags), str(m.num_surfaces),
            str(m.numskins), str(m.num_vertices), str(m.num_triangles), chk(m.elements), chk(m.vertex),
            chk(m.texcoord), m.poses if m.poses == "*" else chk(m.poses), *box]


EXTS = (".md3", ".iqm", ".dpm", ".zym", ".mdl", ".md2", ".spr", ".spr32", ".sp2", ".psk")


def main():
    names = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        names.append(line.split("\t")[0])
    files = set(names)
    out = ["# name\ttype\tnumframes\tscene names\tscenes\tnum_poses\tnum_bones\tbone names\tbone parents\tnum_tags"
           "\ttag names\tnum_surfaces\tnumskins\tnum_vertices\tnum_triangles\telement3i\tvertex3f\ttexcoord2f"
           "\tposes7s\tnormalmins\tnormalmaxs\tyawmins\tyawmaxs\trotatedmins\trotatedmaxs\tradius"
           "  (* = not computed by this decoder)"]
    counts = {}
    for name in sorted(names):
        if not name.lower().endswith(EXTS):
            continue
        p = VFS / name
        if not p.is_file():
            continue
        d = p.read_bytes()
        loader = LOADERS.get(d[:4])
        if loader is None:
            continue
        m = loader(d, name, files)
        fg = f"{name}.framegroups"
        if fg in files and (VFS / fg).is_file():
            framegroups(m, (VFS / fg).read_bytes().split(b"\0")[0].decode("latin-1"))
        counts[m.type] = counts.get(m.type, 0) + 1
        out.append("\t".join(row(name, m)))
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"{OUT.relative_to(ROOT)}: {len(out) - 1} models {counts}")


if __name__ == "__main__":
    sys.exit(main())
