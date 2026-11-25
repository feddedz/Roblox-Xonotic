#!/usr/bin/env python3
"""Headless picture of a map as the Luau port loaded it (debug aid, not the game's renderer).

  lune run tools/studio/export_surfaces.luau stormkeep
  python3 tools/studio/render_map.py stormkeep [--out work/studio/stormkeep] [--size 1600x900]
      -> <out>_top.png (bird's eye) and <out>_spawn.png (from the first player spawn point)

A small software rasteriser (numpy z-buffer): every surface triangle of the .xsm dump, textured with the image
its Q3 shader names first (assets/data/shaders.json; the Roblox-safe versions in work/upload/ready when present),
lit by a fixed light so shapes read. No lightmaps, no shader stages, no sky: it shows geometry and texture
coordinates, which is what the loader produces.
"""
import argparse
import json
import math
import re
import struct
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SKY, NODRAW = 4, 128


def load(name):
    d = (ROOT / f"work/studio/{name}.xsm").read_bytes()
    assert d[:4] == b"XSM1"
    nv, nt, ns, ntex = struct.unpack_from("<4I", d, 4)
    o = 20
    pos = np.frombuffer(d, "<f4", nv * 3, o).reshape(-1, 3); o += nv * 12
    nrm = np.frombuffer(d, "<f4", nv * 3, o).reshape(-1, 3); o += nv * 12
    uv = np.frombuffer(d, "<f4", nv * 2, o).reshape(-1, 2); o += nv * 8
    el = np.frombuffer(d, "<i4", nt * 3, o).reshape(-1, 3); o += nt * 12
    surf = np.frombuffer(d, "<i4", ns * 4, o).reshape(-1, 4); o += ns * 16
    names = d[o:].decode("latin-1").split("\n")
    return pos, nrm, uv, el, surf, names


def texture_images(names):
    shaders = {s["name"].lower(): s for s in json.load(open(ROOT / "assets/data/shaders.json", encoding="utf-8"))["shaders"]}
    out = {}
    for i, n in enumerate(names):
        cands = []
        s = shaders.get(n.lower())
        if s:
            for layer in s["layers"]:
                for st in layer:
                    if st[0].lower() in ("map", "clampmap") and len(st) > 1 and not st[1].startswith("$"):
                        cands.append(st[1])
                    if st[0].lower() == "animmap" and len(st) > 2:
                        cands.append(st[2])
            for dct in s.get("directives", []):
                if dct[0].lower() == "qer_editorimage" and len(dct) > 1:
                    cands.append(dct[1])
        cands.append(n)
        for c in cands:
            base = re.sub(r"\.(tga|jpg|png)$", "", c, flags=re.I)
            for root in ("work/upload/ready", "work/vfs-high"):
                p = ROOT / root / (base + ".jpg")
                if p.exists():
                    im = np.asarray(Image.open(p).convert("RGB").resize((128, 128), Image.BILINEAR), np.float32) / 255.0
                    out[i] = im
                    break
            if i in out:
                break
    return out


def spawn(name):
    d = (ROOT / f"work/vfs-high/maps/{name}.bsp").read_bytes()
    ofs, ln = struct.unpack_from("<ii", d, 8)
    ent = d[ofs:ofs + ln].decode("latin-1")
    for block in re.findall(r"\{([^{}]*)\}", ent):
        kv = dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', block))
        if kv.get("classname", "").startswith("info_player") and "origin" in kv:
            o = np.array([float(x) for x in kv["origin"].split()], np.float32)
            return o, float(kv.get("angle", "0"))
    return None, 0.0


def render(pos, nrm, uv, el, surf, texs, eye, target, size, fov=90.0):
    W, H = size
    f = target - eye
    f /= np.linalg.norm(f)
    r = np.cross(f, np.array([0, 0, 1.0], np.float32))
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    rel = pos - eye
    cam = np.stack([rel @ r, rel @ u, rel @ f], 1)  # x right, y up, z forward
    focal = (W / 2) / math.tan(math.radians(fov) / 2)
    near = 4.0
    img = np.zeros((H, W, 3), np.float32) + np.array([0.05, 0.06, 0.08], np.float32)
    zbuf = np.full((H, W), np.inf, np.float32)
    light = np.array([0.35, 0.25, 0.9], np.float32)
    light /= np.linalg.norm(light)
    drawn = 0
    for tex, first, count, flags in surf:
        if tex < 0 or count == 0 or flags & (SKY | NODRAW):
            continue
        timg = texs.get(int(tex))
        h = (hash(int(tex)) % 360) / 360.0
        flat = np.array([0.5 + 0.3 * math.sin(6.28 * h), 0.5 + 0.3 * math.sin(6.28 * h + 2), 0.5 + 0.3 * math.sin(6.28 * h + 4)], np.float32)
        for t in el[first:first + count]:
            c = cam[t]
            if (c[:, 2] < near).any():  # no clipping: skip triangles that cross the near plane
                continue
            sx = W / 2 + c[:, 0] / c[:, 2] * focal
            sy = H / 2 - c[:, 1] / c[:, 2] * focal
            x0, x1 = int(max(0, math.floor(sx.min()))), int(min(W - 1, math.ceil(sx.max())))
            y0, y1 = int(max(0, math.floor(sy.min()))), int(min(H - 1, math.ceil(sy.max())))
            if x0 > x1 or y0 > y1:
                continue
            area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0])
            if abs(area) < 1e-6:
                continue
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1, dtype=np.float32) + 0.5, np.arange(y0, y1 + 1, dtype=np.float32) + 0.5)
            w0 = ((sx[1] - xs) * (sy[2] - ys) - (sx[2] - xs) * (sy[1] - ys)) / area
            w1 = ((sx[2] - xs) * (sy[0] - ys) - (sx[0] - xs) * (sy[2] - ys)) / area
            w2 = 1 - w0 - w1
            inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
            if not inside.any():
                continue
            iz = w0 / c[0, 2] + w1 / c[1, 2] + w2 / c[2, 2]  # perspective-correct
            z = 1 / np.maximum(iz, 1e-9)
            sub = zbuf[y0:y1 + 1, x0:x1 + 1]
            m = inside & (z < sub)
            if not m.any():
                continue
            n = nrm[t].mean(0)
            ln = np.linalg.norm(n)
            shade = 0.35 + 0.65 * abs(float(n @ light) / ln) if ln > 0 else 0.6
            if timg is not None:
                tu = (w0 * uv[t[0], 0] / c[0, 2] + w1 * uv[t[1], 0] / c[1, 2] + w2 * uv[t[2], 0] / c[2, 2]) * z
                tv = (w0 * uv[t[0], 1] / c[0, 2] + w1 * uv[t[1], 1] / c[1, 2] + w2 * uv[t[2], 1] / c[2, 2]) * z
                px = timg[(np.floor(tv * 128).astype(np.int64) % 128)[m], (np.floor(tu * 128).astype(np.int64) % 128)[m]] * shade
            else:
                px = flat * shade
            sub[m] = z[m]
            img[y0:y1 + 1, x0:x1 + 1][m] = px
            drawn += 1
    return Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)), drawn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", nargs="?", default="stormkeep")
    ap.add_argument("--out")
    ap.add_argument("--size", default="1600x900")
    a = ap.parse_args()
    size = tuple(int(x) for x in a.size.split("x"))
    out = a.out or str(ROOT / f"work/studio/{a.name}")
    pos, nrm, uv, el, surf, names = load(a.name)
    texs = texture_images(names)
    used = {int(s[0]) for s in surf if s[2] > 0 and s[0] >= 0}
    print(f"{len(used)} textures used, {len(used & set(texs))} with an image")
    lo, hi = pos[el.reshape(-1)].min(0), pos[el.reshape(-1)].max(0)
    mid = (lo + hi) / 2
    ext = float(np.linalg.norm(hi - lo))
    eye = mid + np.array([0.45, -0.55, 0.62], np.float32) * ext
    im, n = render(pos, nrm, uv, el, surf, texs, eye.astype(np.float32), mid.astype(np.float32), size, 60.0)
    im.save(out + "_top.png")
    print("top:", n, "triangles drawn ->", out + "_top.png")
    o, ang = spawn(a.name)
    if o is not None:
        eye = o + np.array([0, 0, 35], np.float32)  # eye height above the spawn origin
        tgt = eye + np.array([math.cos(math.radians(ang)), math.sin(math.radians(ang)), -0.05], np.float32) * 100
        im, n = render(pos, nrm, uv, el, surf, texs, eye, tgt.astype(np.float32), size, 90.0)
        im.save(out + "_spawn.png")
        print("spawn:", n, "triangles drawn ->", out + "_spawn.png")


if __name__ == "__main__":
    main()
