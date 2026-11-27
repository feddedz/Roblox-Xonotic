#!/usr/bin/env python3
"""Small synthetic alias / sprite models for the C reference of engine/model_alias.luau (no game data needed).

  python3 -I tools/testgen/make_model_fixtures.py   -> tests/fixtures/models/   (committed)

tools/testgen/alias_vectors.c loads them with the release's own loaders (Mod_ForName -> Mod_LoadModel ->
Mod_INTERQUAKEMODEL_Load / Mod_IDP3_Load / Mod_DARKPLACESMODEL_Load / Mod_IDP0_Load / Mod_IDSP_Load) and prints
everything they set (tests/vectors/alias.tsv); tests/unit/model_alias_ref.test.luau loads the same files.
Every model has several frames, bones or tags, two surfaces (sprites and mdl: one), and most have .skin and
.framegroups files. Values are pseudo-random (fixed seed) and not representable in few bits, so the float
rounding of the loaders matters. Edge cases: an MD3 frame name of 16 characters without NUL (strlcpy reads on),
an out-of-range element (Mod_ValidateElements), an IQM vertex array of an unsupported format, a joint whose
quaternion has w > 0, DPM vertices with 1 to 5 weights, MDL seam vertices / back faces / a frame group with a
too-small interval, a sprite frame group.
"""
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tests/fixtures/models"

seed = 12345


def rnd() -> int:
    global seed
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    return seed


def frand(lo: float, hi: float) -> float:
    return lo + (hi - lo) * (rnd() % 100003) / 100003.0


def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


def write(rel: str, data: bytes):
    p = OUT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def quat(ax, ay, az, angle):
    n = math.sqrt(ax * ax + ay * ay + az * az)
    s = math.sin(angle / 2) / n
    return [ax * s, ay * s, az * s, math.cos(angle / 2)]


# ---------------------------------------------------------------- IQM
class Blob:
    def __init__(self, start: int):
        self.parts = []
        self.pos = start

    def add(self, data: bytes) -> int:
        while self.pos % 4:
            self.parts.append(b"\0")
            self.pos += 1
        o = self.pos
        self.parts.append(data)
        self.pos += len(data)
        return o

    def bytes(self) -> bytes:
        return b"".join(self.parts)


def iqm(version: int, with_bounds: bool, with_normals: bool, with_neighbors: bool, num_anims: int,
        num_frames: int) -> bytes:
    text = b"\0"
    names = {}
    for s in ("body", "head", "models/tv/skin_a", "tvshader/red.tga", "root", "arm", "hand", "idle", "run"):
        names[s] = len(text)
        text += s.encode() + b"\0"
    nv = 10
    pos = [[frand(-20, 20) for _ in range(3)] for _ in range(nv)]
    tc = [[frand(0, 1), frand(0, 1)] for _ in range(nv)]
    nrm = []
    for _ in range(nv):
        v = [frand(-1, 1) for _ in range(3)]
        n = math.sqrt(sum(x * x for x in v))
        nrm.append([x / n for x in v])
    tan = [[frand(-1, 1), frand(-1, 1), frand(-1, 1), 1.0 if rnd() % 2 else -1.0] for _ in range(nv)]
    bi = [[i % 3, (i + 1) % 3, (i + 2) % 3, 0] for i in range(nv)]
    bw = [[255, 0, 0, 0], [200, 55, 0, 0], [100, 100, 55, 0], [128, 127, 0, 0], [85, 85, 85, 0]]
    bw = [bw[i % len(bw)] for i in range(nv)]
    col = [[rnd() % 256 for _ in range(4)] for _ in range(nv)]
    tris = [[0, 1, 2], [2, 3, 0], [3, 4, 5], [5, 1, 3], [6, 7, 8], [8, 9, 6 if version == 2 else 99]]
    meshes = [(names["body"], names["models/tv/skin_a"], 0, 6, 0, 4), (names["head"], names["tvshader/red.tga"], 6, 4, 4, 2)]
    # joints
    jdefs = [("root", -1), ("arm", 0), ("hand", 1)]
    joints = []
    for k, (nm, parent) in enumerate(jdefs):
        origin = [frand(-8, 8) for _ in range(3)]
        q = quat(frand(-1, 1), frand(-1, 1), frand(-1, 1), frand(-3, 3))
        if k == 1:
            q = [x * 1.3 for x in q]  # not normalized
        if k == 2 and q[3] < 0:
            q = [-x for x in q]  # w > 0: the v2 loader negates it
        if q[3] > 0 and k == 0:
            q = [-x for x in q]
        scale = [1.0, 1.0, 1.0]
        joints.append((names[nm], parent, origin, q, scale))
    nch = 9 if version == 1 else 10
    masks = [(1 << nch) - 1, 0x07 | (0x38 if version == 1 else 0x78), 0x10 | 0x02]
    poses = []
    for k, (nmo, parent, origin, q, scale) in enumerate(joints):
        off = origin + q[:3] + ([q[3]] if version == 2 else []) + [1.0, 1.0, 1.0]
        sc = [frand(-0.001, 0.001) for _ in range(3)] + [frand(-1, 1) / 65535.0 for _ in range(4 if version == 2 else 3)] + [0.00001] * 3
        poses.append((parent, masks[k], off, sc))
    framechannels = sum(bin(m).count("1") for m in masks)
    frames = []
    for _ in range(num_frames):
        for (parent, mask, off, sc) in poses:
            for c in range(nch):
                if mask & (1 << c):
                    frames.append(rnd() % 65536)
    anims = [(names["idle"], 0, min(2, num_frames), 12.5, 1), (names["run"], min(2, num_frames - 1), 2, 7.25, 0)][:num_anims]
    bounds = []
    for f in range(num_frames):
        mins = [frand(-30, -10) for _ in range(3)]
        maxs = [frand(10, 30) for _ in range(3)]
        bounds.append(mins + maxs + [frand(10, 40), frand(20, 50)])

    blob = Blob(124)
    o_text = blob.add(text)
    o_meshes = blob.add(b"".join(struct.pack("<6I", *m) for m in meshes))
    arrays = []
    arrays.append((0, 0, 7, 3, blob.add(b"".join(struct.pack("<3f", *v) for v in pos))))
    arrays.append((1, 0, 7, 2, blob.add(b"".join(struct.pack("<2f", *v) for v in tc))))
    if with_normals:
        arrays.append((2, 0, 7, 3, blob.add(b"".join(struct.pack("<3f", *v) for v in nrm))))
        arrays.append((3, 0, 7, 4, blob.add(b"".join(struct.pack("<4f", *v) for v in tan))))
    arrays.append((4, 0, 1, 4, blob.add(b"".join(bytes(v) for v in bi))))
    arrays.append((5, 0, 1, 4, blob.add(b"".join(bytes(v) for v in bw))))
    if version == 2:
        arrays.append((6, 0, 1, 4, blob.add(b"".join(bytes(v) for v in col))))
    else:
        arrays.append((6, 0, 7, 4, blob.add(b"".join(struct.pack("<4f", *[c / 255.0 for c in v]) for v in col))))
        arrays.append((2, 0, 2, 3, blob.add(b"\0" * (nv * 6))))  # IQM_SHORT normals: unsupported format, skipped
    o_va = blob.add(b"".join(struct.pack("<5I", *a) for a in arrays))
    o_tri = blob.add(b"".join(struct.pack("<3I", *t) for t in tris))
    o_nb = blob.add(b"".join(struct.pack("<3i", (i + 1) % 6, -1, (i + 3) % 6) for i in range(len(tris)))) if with_neighbors else 0
    if version == 1:
        o_joints = blob.add(b"".join(struct.pack("<Ii3f3f3f", n, p, *o, *q[:3], *s) for (n, p, o, q, s) in joints))
        o_poses = blob.add(b"".join(struct.pack("<iI9f9f", p, m, *off, *sc) for (p, m, off, sc) in poses))
    else:
        o_joints = blob.add(b"".join(struct.pack("<Ii3f4f3f", n, p, *o, *q, *s) for (n, p, o, q, s) in joints))
        o_poses = blob.add(b"".join(struct.pack("<iI10f10f", p, m, *off, *sc) for (p, m, off, sc) in poses))
    o_anims = blob.add(b"".join(struct.pack("<IIIfI", *a) for a in anims)) if anims else 0
    o_frames = blob.add(struct.pack(f"<{len(frames)}H", *frames))
    o_bounds = blob.add(b"".join(struct.pack("<8f", *b) for b in bounds)) if with_bounds else 0
    body = blob.bytes()
    filesize = 124 + len(body)
    header = b"INTERQUAKEMODEL\0" + struct.pack(
        "<27I", version, filesize, 0, len(text), o_text, len(meshes), o_meshes, len(arrays), nv, o_va, len(tris),
        o_tri, o_nb, len(joints), o_joints, len(poses), o_poses, len(anims), o_anims, num_frames, framechannels,
        o_frames, o_bounds, 0, 0, 0, 0)
    return header + body


# ---------------------------------------------------------------- MD3
def md3() -> bytes:
    num_frames, num_tags = 3, 2
    frame_names = [b"stand", b"abcdefghijklmnop", b"last"]
    frames = b""
    for f in range(num_frames):
        frames += struct.pack("<10f", *[frand(-5, 5) for _ in range(10)]) + frame_names[f].ljust(16, b"\0")[:16]
    tags = b""
    for f in range(num_frames):
        for t, nm in enumerate((b"tag_weapon", b"tag_head")):
            q = quat(frand(-1, 1), frand(-1, 1), frand(-1, 1), frand(-3, 3))
            x, y, z, w = q
            s = 1.0 + 0.25 * t  # a scaled tag
            rot = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
                   2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
                   2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)]
            tags += nm.ljust(64, b"\0") + struct.pack("<3f", *[frand(-10, 10) for _ in range(3)]) + struct.pack("<9f", *[r * s for r in rot])
    meshes = b""
    for mi, (mname, shader, nv, tris) in enumerate(((b"torso", b"models/tv/skin_b.tga", 5, [[0, 1, 2], [2, 3, 0], [3, 4, 1]]),
                                                    (b"legs", None, 4, [[0, 1, 2], [1, 3, 2]]))):
        st = b"".join(struct.pack("<2f", frand(0, 1), frand(0, 1)) for _ in range(nv))
        xyz = b""
        for f in range(num_frames):
            for v in range(nv):
                xyz += struct.pack("<3h2B", rnd() % 4000 - 2000, rnd() % 4000 - 2000, rnd() % 4000 - 2000, rnd() % 256, rnd() % 256)
        el = b"".join(struct.pack("<3i", *t) for t in tris)
        sh = (shader.ljust(64, b"\0") + struct.pack("<i", 0)) if shader else b""
        o_tri = 108
        o_sh = o_tri + len(el)
        o_st = o_sh + len(sh)
        o_xyz = o_st + len(st)
        o_end = o_xyz + len(xyz)
        hdr = b"IDP3" + mname.ljust(64, b"\0") + struct.pack("<10i", 0, num_frames, 1 if shader else 0, nv, len(tris), o_tri, o_sh, o_st, o_xyz, o_end)
        meshes += hdr + el + sh + st + xyz
    o_frames = 108
    o_tags = o_frames + len(frames)
    o_meshes = o_tags + len(tags)
    o_end = o_meshes + len(meshes)
    hdr = b"IDP3" + struct.pack("<i", 15) + b"models/tv/c.md3".ljust(64, b"\0") + struct.pack(
        "<9i", 0x0301, num_frames, num_tags, 2, 0, o_frames, o_tags, o_meshes, o_end)
    return hdr + frames + tags + meshes


# ---------------------------------------------------------------- DPM (big-endian)
def rotmatrix(ax, ay, az, angle):
    x, y, z, w = quat(ax, ay, az, angle)
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]


def dpm() -> bytes:
    num_bones, num_frames = 3, 3
    bones = [(b"root", -1, 1), (b"spine", 0, 0), (b"tail", 1, 0)]
    poses = []
    for f in range(num_frames):
        fp = b""
        for k in range(num_bones):
            r = rotmatrix(frand(-1, 1), frand(-1, 1), frand(-1, 1), frand(-2, 2))
            s = 1.5 if k == 0 else 1.0  # root scale (modelscale of the loader)
            t = [frand(-6, 6) for _ in range(3)]
            fp += struct.pack(">12f", *[r[i][j] * s for i in range(3) for j in range(3)][0:3], t[0],
                              *[r[1][j] * s for j in range(3)], t[1], *[r[2][j] * s for j in range(3)], t[2])
        poses.append(fp)
    meshes = []
    for mi, (sname, nv, tris) in enumerate(((b"models/tv/skin_b", 5, [[0, 1, 2], [2, 3, 4], [4, 1, 0]]),
                                            (b"dpmshader_two_with_a_long_name_x", 4, [[0, 1, 2], [3, 2, 1]]))):
        verts = b""
        for v in range(nv):
            nw = 1 + (v + mi) % 5
            ws = [frand(0.1, 1) for _ in range(nw)]
            tot = sum(ws)
            verts += struct.pack(">I", nw)
            for w in range(nw):
                verts += struct.pack(">3ff3fI", *[frand(-10, 10) for _ in range(3)], ws[w] / tot,
                                     *[frand(-1, 1) for _ in range(3)], (v + w) % num_bones)
        tc = struct.pack(f">{nv * 2}f", *[frand(0, 1) for _ in range(nv * 2)])
        idx = b"".join(struct.pack(">3I", *t) for t in tris)
        meshes.append((sname, nv, len(tris), verts, tc, idx))
    body = b""
    o = 80
    o_bones = o
    bones_b = b"".join(n.ljust(32, b"\0") + struct.pack(">iI", p, fl) for (n, p, fl) in bones)
    o += len(bones_b)
    o_meshs = o
    o += 56 * len(meshes)
    o_frames = o
    o += 68 * num_frames
    mesh_hdr = b""
    mesh_data = b""
    for (sname, nv, nt, verts, tc, idx) in meshes:
        ov = o
        o += len(verts)
        ot = o
        o += len(tc)
        oi = o
        o += len(idx)
        og = o
        groups = struct.pack(f">{nt}I", *range(nt))
        o += len(groups)
        mesh_hdr += sname.ljust(32, b"\0")[:32] + struct.pack(">6I", nv, nt, ov, ot, oi, og)
        mesh_data += verts + tc + idx + groups
    frame_hdr = b""
    frame_data = b""
    for f in range(num_frames):
        frame_hdr += (b"frame%d" % f).ljust(32, b"\0") + struct.pack(">8fi", *[frand(-5, 5) for _ in range(8)], o)
        frame_data += poses[f]
        o += len(poses[f])
    body = bones_b + mesh_hdr + frame_hdr + mesh_data + frame_data
    hdr = b"DARKPLACESMODEL\0" + struct.pack(">II", 2, 80 + len(body)) + struct.pack(">8f", -9, -9, -9, 9, 9, 9, 12, 15) + struct.pack(
        ">6I", num_bones, len(meshes), num_frames, o_bones, o_meshs, o_frames)
    return hdr + body


# ---------------------------------------------------------------- MDL
def mdl() -> bytes:
    sw, sh, nv = 8, 4, 5
    hdr = b"IDPO" + struct.pack("<i3f3ff3f", 6, 0.12, 0.25, 0.0625, -16.5, -8.25, -2.0, 30.0, 0, 0, 20) + struct.pack(
        "<8if", 2, sw, sh, nv, 4, 2, 1, 0x0109, 10.0)
    skins = struct.pack("<i", 0) + bytes(rnd() % 256 for _ in range(sw * sh))
    skins += struct.pack("<ii2f", 1, 2, 0.15, 0.3) + bytes(rnd() % 256 for _ in range(2 * sw * sh))
    st = b"".join(struct.pack("<3i", 32 if v in (1, 3) else 0, rnd() % sw, rnd() % sh) for v in range(nv))
    tris = b"".join(struct.pack("<4i", ff, *t) for (ff, t) in ((1, (0, 1, 2)), (0, (1, 3, 2)), (0, (3, 4, 2)), (1, (4, 0, 2))))

    def frame(name: bytes) -> bytes:
        return bytes([1, 2, 3, 0, 250, 251, 252, 0]) + name.ljust(16, b"\0") + bytes(
            [rnd() % 256 if k % 4 != 3 else rnd() % 162 for k in range(nv * 4)])
    frames = struct.pack("<i", 0) + frame(b"single")
    frames += struct.pack("<i", 1) + struct.pack("<i8B", 2, 0, 0, 0, 0, 255, 255, 255, 0) + struct.pack("<2f", 0.005, 0.2)
    frames += frame(b"group_a") + frame(b"group_b")
    return hdr + skins + st + tris + frames


# ---------------------------------------------------------------- SPR
def spr() -> bytes:
    hdr = b"IDSP" + struct.pack("<iif3ifi", 1, 2, 20.0, 8, 16, 2, 0.0, 0)
    fr = struct.pack("<i", 0) + struct.pack("<4i", -4, 8, 8, 16) + bytes(rnd() % 256 for _ in range(8 * 16))
    fr += struct.pack("<ii2f", 1, 2, 0.2, 0.3)
    fr += struct.pack("<4i", -3, 5, 6, 10) + bytes(rnd() % 256 for _ in range(60))
    fr += struct.pack("<4i", -2, 2, 4, 4) + bytes(rnd() % 256 for _ in range(16))
    return hdr + fr


SHADER = """// shaders the fixture models use
models/tv/skin_b
{
	{
		map models/tv/skin_b.tga
		blendfunc add
	}
}
tvshader/red
{
	surfaceparm nonsolid
	{
		map $whiteimage
		rgbgen lightingdiffuse
	}
}
tvshader/blue
{
	cull none
	{
		map models/tv/blue.tga
		alphafunc GE128
	}
}
"""


def main():
    write("models/tv/a.iqm", iqm(2, True, True, True, 2, 4))
    write("models/tv/a.iqm_0.skin", b"body,models/tv/skin_b.tga\nhead,tvshader/blue\ntag_hand,\n")
    write("models/tv/a.iqm_1.skin", b"replace body tvshader/red\nreplace head\nnot a valid line\n")
    write("models/tv/a.iqm.framegroups", b"0 2 10 1 idle2\n1 9 0.5 0\n// a comment line\n3 1\n")
    write("models/tv/b.iqm", iqm(1, False, False, False, 0, 3))
    write("models/tv/c.md3", md3())
    write("models/tv/c.md3_0.skin", b"torso,models/tv/skin_b\nlegs,common/nodraw\ntag_weapon,\n")
    write("models/tv/c.md3_1.skin", b"replace torso tvshader/red\n")
    write("models/tv/c.md3.framegroups", b"0 2 15 1 walk\n2 1\n")
    write("models/tv/d.dpm", dpm())
    write("models/tv/d.dpm.framegroups", b"/* generated */\n0 1 5 0 stand\n1 2 10\n")
    write("models/tv/e.mdl", mdl())
    write("models/tv/f.spr", spr())
    write("scripts/tvmodels.shader", SHADER.encode())
    for p in sorted(OUT.rglob("*")):
        if p.is_file():
            print(p.relative_to(ROOT), p.stat().st_size)


if __name__ == "__main__":
    main()
