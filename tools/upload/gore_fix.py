#!/usr/bin/env python3
"""GORE-ASSETS: make Roblox-safe versions of the blood/gore textures, changed as subtly as possible.

  python3 tools/upload/gore_fix.py [substring ...]   -> work/upload/fixed/<vpath> (originals untouched)

Input list: assets/optional/gore/textures.tsv. Originals: work/vfs-high/<vpath>. Every changed file is written
at the same relative path under work/upload/fixed/ (JPEG quality 95, same size and mode); files that need no
change are not written. The log assets/manifest/review/gore_fixes.tsv is regenerated (one row per listed
vpath, plus the _alpha masks that had to change with their colour image). Deterministic: numpy + Pillow only.

Methods (see RECIPES at the bottom for which file gets which):
  splat_badge   default-HUD kill-feed icons: the splatter body (alpha>128, largest part) is smoothed into a
                slightly irregular rounded blob, droplets dropped; alpha/colour glow are rebuilt from the
                original's own edge profile (median per distance from the edge), the interior is the original
                fill texture (extended by normalized-convolution inpainting), the word is pasted back verbatim.
                The colour image and its _alpha mask come from the same new shape, so they stay in sync.
  luma_blob     same reshape for the luma "fall" splat, with a hue shift from red to amber.
  decal_recolor blood-splatter decals: shape and alpha untouched, the dark-red colour mapped to dark
                oil/scorch brown-grey (luminance kept).
  stain         map tiles with blood stains: only pixels that are redder than the surrounding surface are
                recoloured to the surface's local colour (low-frequency fill from the unstained pixels),
                their luminance detail kept, so the stain reads as dirt/grime; other pixels are unchanged.
  inpaint       small red features (cut on a face) replaced by the surrounding surface colour.
  debris        gib/flesh textures: hue mapped to grey-brown rock, luminance and structure kept.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "work/vfs-high"
DST = ROOT / "work/upload/fixed"
LIST = ROOT / "assets/optional/gore/textures.tsv"
LOG = ROOT / "assets/manifest/review/gore_fixes.tsv"


# ----------------------------------------------------------------------------------------------- helpers
def load(v: str) -> np.ndarray:
    im = Image.open(SRC / v)
    return np.asarray(im.convert("L" if im.mode == "L" else "RGB")).astype(np.float64)


def save(v: str, a: np.ndarray) -> None:
    out = DST / v
    out.parent.mkdir(parents=True, exist_ok=True)
    a = np.clip(np.rint(a), 0, 255).astype(np.uint8)
    Image.fromarray(a, "L" if a.ndim == 2 else "RGB").save(out, quality=95)


def lum(c: np.ndarray) -> np.ndarray:
    return c[..., 0] * 0.299 + c[..., 1] * 0.587 + c[..., 2] * 0.114


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def blur(a: np.ndarray, sigma: float, wrap: bool) -> np.ndarray:
    """Exact Gaussian blur via FFT; wrap=True for tiling textures, else edge padding."""
    if sigma <= 0:
        return a.copy()
    pad = 0 if wrap else int(3 * sigma) + 2
    x = a if wrap else np.pad(a, [(pad, pad), (pad, pad)] + [(0, 0)] * (a.ndim - 2), mode="edge")
    h, w = x.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (fx * fx + fy * fy))
    if x.ndim == 3:
        g = g[..., None]
    r = np.fft.irfft2(np.fft.rfft2(x, axes=(0, 1)) * g, s=(h, w), axes=(0, 1))
    return r if wrap else r[pad:-pad, pad:-pad]


def fill(img: np.ndarray, known: np.ndarray, wrap: bool, sigmas=(2, 4, 8, 16, 32, 64, 128)) -> np.ndarray:
    """Low-frequency colour of `img` from `known` pixels, extended into the unknown ones
    (multi-scale normalized convolution: the smallest scale with enough support wins)."""
    k = known.astype(np.float64)
    out = np.zeros_like(img)
    done = np.zeros(known.shape, bool)
    kk = k[..., None] if img.ndim == 3 else k
    for s in sigmas:
        num = blur(img * kk, s, wrap)
        den = blur(k, s, wrap)
        ok = (den > 0.25) & ~done
        dd = np.maximum(den, 1e-6)
        out[ok] = (num / (dd[..., None] if img.ndim == 3 else dd))[ok]
        done |= ok
    if not done.all():
        mean = img[known].mean(axis=0) if known.any() else img.mean(axis=(0, 1))
        out[~done] = mean
    return out


def dilate(m: np.ndarray, r: int) -> np.ndarray:
    m = m.copy()
    for _ in range(r):
        n = m.copy()
        n[1:] |= m[:-1]
        n[:-1] |= m[1:]
        n[:, 1:] |= m[:, :-1]
        n[:, :-1] |= m[:, 1:]
        m = n
    return m


def erode(m: np.ndarray, r: int) -> np.ndarray:
    return ~dilate(~m, r)


def labels(m: np.ndarray) -> np.ndarray:
    """4-connected component labels (0 = background)."""
    h, w = m.shape
    lab = np.where(m, np.arange(1, h * w + 1).reshape(h, w), 0)
    while True:
        n = lab.copy()
        n[1:] = np.maximum(n[1:], lab[:-1])
        n[:-1] = np.maximum(n[:-1], lab[1:])
        n[:, 1:] = np.maximum(n[:, 1:], lab[:, :-1])
        n[:, :-1] = np.maximum(n[:, :-1], lab[:, 1:])
        n = np.where(m, n, 0)
        if np.array_equal(n, lab):
            break
        lab = n
    return lab


def largest_component(m: np.ndarray) -> np.ndarray:
    lab = labels(m)
    ids, cnt = np.unique(lab[lab > 0], return_counts=True)
    return lab == ids[np.argmax(cnt)]


def drop_small(m: np.ndarray, n: int) -> np.ndarray:
    lab = labels(m)
    ids, cnt = np.unique(lab[lab > 0], return_counts=True)
    return np.isin(lab, ids[cnt >= n])


def fill_holes(m: np.ndarray) -> np.ndarray:
    pad = np.pad(~m, 1, constant_values=True)
    return ~largest_component(pad)[1:-1, 1:-1] | m


def edt(feat: np.ndarray) -> np.ndarray:
    """Euclidean distance from every pixel to the nearest True pixel of `feat` (two-pass, exact)."""
    h, w = feat.shape
    big = float(h + w)
    g = np.where(feat, 0.0, big)
    for y in range(1, h):
        g[y] = np.minimum(g[y], g[y - 1] + 1)
    for y in range(h - 2, -1, -1):
        g[y] = np.minimum(g[y], g[y + 1] + 1)
    xs = np.arange(w, dtype=np.float64)
    dx2 = (xs[None, :] - xs[:, None]) ** 2  # [x', x]
    out = np.empty((h, w))
    for y in range(h):
        out[y] = np.sqrt(np.min(g[y][:, None] ** 2 + dx2, axis=0))
    return out


def sdist(m: np.ndarray) -> np.ndarray:
    """Signed distance to the edge of mask m: >0 outside, <=0 inside (pixel units)."""
    return np.where(m, -(edt(~m) - 0.5), edt(m) - 0.5)


def upscale(m: np.ndarray, f: int) -> np.ndarray:
    return np.asarray(Image.fromarray(m.astype(np.uint8) * 255).resize((m.shape[1] * f, m.shape[0] * f), Image.BILINEAR)) > 127


def downscale(a: np.ndarray, f: int) -> np.ndarray:
    h, w = a.shape[0] // f, a.shape[1] // f
    return a.reshape(h, f, w, f, *a.shape[2:]).mean(axis=(1, 3))


def rgb_to_hsv(c: np.ndarray):
    c = c / 255.0
    mx, mn = c.max(-1), c.min(-1)
    d = mx - mn
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    h = np.zeros(mx.shape)
    dd = np.where(d == 0, 1, d)
    h = np.where(mx == r, ((g - b) / dd) % 6, h)
    h = np.where(mx == g, (b - r) / dd + 2, h)
    h = np.where(mx == b, (r - g) / dd + 4, h)
    h = np.where(d == 0, 0, h) / 6.0
    s = np.where(mx == 0, 0, d / np.where(mx == 0, 1, mx))
    return h, s, mx


def hsv_to_rgb(h, s, v):
    i = np.floor(h * 6) % 6
    f = h * 6 - np.floor(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r = np.choose(i.astype(int), [v, q, p, p, t, v])
    g = np.choose(i.astype(int), [t, v, v, q, p, p])
    b = np.choose(i.astype(int), [p, p, t, v, v, q])
    return np.stack([r, g, b], -1) * 255


def redness(c: np.ndarray) -> np.ndarray:
    """0 for neutral/green/blue pixels, ->1 for saturated red."""
    return (c[..., 0] - np.maximum(c[..., 1], c[..., 2])) / (c[..., 0] + 8)


# ------------------------------------------------------------------------------------- HUD splat badges
def profile(dist: np.ndarray, vals: np.ndarray, lo: float, hi: float, step: float = 0.5):
    """Median of vals (N,k) per distance bin -> (bin centres, medians)."""
    bins = np.arange(lo, hi + step, step)
    cs, ms = [], []
    for b in bins:
        sel = (dist >= b - step / 2) & (dist < b + step / 2)
        if sel.sum() >= 3:
            cs.append(b)
            ms.append(np.median(vals[sel], axis=0))
    return np.array(cs), np.array(ms)


def interp_profile(d: np.ndarray, cs: np.ndarray, ms: np.ndarray) -> np.ndarray:
    return np.stack([np.interp(d, cs, ms[:, k]) for k in range(ms.shape[1])], -1)


def new_blob(body: np.ndarray, text: np.ndarray, sigma: float, F: int) -> np.ndarray:
    """Smooth, slightly irregular rounded blob from the main splatter body, at F x resolution.
    A wide blur of the main body (droplets dropped) is thresholded so the blob keeps the body's area:
    spikes and drips melt away, the large-scale lumps survive as an irregular, malformed circle."""
    main = fill_holes(largest_component(body))
    up = upscale(main, F).astype(np.float64)
    soft = blur(up, sigma * F, False)
    keep = upscale(dilate(text, 4), F)  # the word must stay well inside the badge
    thr = np.quantile(soft, 1 - up.mean())
    sm = (soft > thr) | keep
    sm = blur(sm.astype(np.float64), 2.0 * F, False) > 0.5
    return fill_holes(largest_component(sm))


def splat_badge(cv: str, av: str, mode: str, sigma: float = 11.0, F: int = 4):
    """mode: 'neutral' (desaturate the blood red to a dark warm grey) or 'team' (keep team colour)."""
    c = load(cv)
    a = load(av)
    body = a > 128
    # the word = bright pixels enclosed by the main dark fill (the white outline sits outside the fill)
    dark = body & (lum(c) < 140)
    fillreg = fill_holes(largest_component(dark))
    text = fillreg & ~dark & (lum(c) > 150)
    # letters that touch the edge of the fill (T of TEAM, M of MELEE) are not enclosed: take bright pixels
    # deeper than the ~5 px white outline, drop outline crumbs, then grow 2 px back into the bright stroke
    d_old = sdist(body)
    bright = body & (lum(c) > 150)
    deep = drop_small(bright & (d_old < -6), 15)
    ys, xs = np.nonzero(text)  # restrict to the word's line (one letter width either side)
    band = np.zeros_like(deep)
    if len(ys):  # notify_death has no word
        band[max(ys.min() - 2, 0):ys.max() + 3, max(xs.min() - 28, 0):xs.max() + 29] = True
    deep = drop_small(deep & band, 50)  # a letter is >= ~100 px; outline crumbs in notches are smaller
    deep = dilate(deep, 1) & bright & (d_old < -5)
    deep &= dilate(erode(deep, 1), 1)  # opening: strip the thin outline spur left where a letter met it
    for _ in range(3):  # prune remaining 1-px diagonal spurs (pixels with < 4 of 8 neighbours set)
        p = np.pad(deep, 1).astype(int)
        nbr = sum(np.roll(np.roll(p, dy, 0), dx, 1) for dy in (-1, 0, 1) for dx in (-1, 0, 1)) - p
        deep &= nbr[1:-1, 1:-1] >= 4
    text |= deep
    fillreg |= dilate(text, 1)
    textzone = text | (dilate(text, 1) & body & (lum(c) < 110))  # never paste bits of the old white outline
    # edge profile of the original (alpha and colour), outside the body and the first pixels inside
    sel = (d_old > -2.5) & (d_old < 60)
    # colour profile ignores the leftover droplets: only pixels whose alpha fits the glow are used
    cs, ms = profile(d_old[sel], np.concatenate([a[sel][:, None], c[sel]], 1), -2.5, 60)
    # interior texture: original fill, text removed, extended over the new shape
    known = erode(fillreg, 3) & ~dilate(text, 2)
    interior = fill(c, known, False)
    wk = blur(known.astype(np.float64), 1.5, False)[..., None] * known[..., None]
    interior = interior * (1 - wk) + c * wk
    if mode == "neutral":
        y = lum(interior)[..., None]
        interior = 1.5 * y + 0.1 * (interior - y)
    nb = new_blob(body, text, sigma, F)
    d_new = sdist(nb) / F
    prof = interp_profile(d_new, cs, ms)
    alpha_hi = np.clip(prof[..., 0], 0, 255)
    halo = prof[..., 1:]
    if mode == "neutral":
        y = lum(halo)[..., None]
        halo = y + 0.2 * (halo - y)
    up = lambda x: np.repeat(np.repeat(x, F, 0), F, 1)  # noqa: E731
    t = np.clip((d_new + 2.0) / 2.0, 0, 1)[..., None]
    col_hi = up(interior) * (1 - t) + halo * t
    col = downscale(col_hi, F)
    alpha = downscale(alpha_hi, F)
    inside = downscale(nb.astype(np.float64), F) > 0.999
    tz = textzone & inside & ~(d_old > -1)
    col = np.where(tz[..., None], c if mode != "neutral" else _neutral_text(c), col)
    # alpha inside stays fully opaque, as in the original body
    alpha = np.where(inside, 255, alpha)
    return col, alpha


def _neutral_text(c: np.ndarray) -> np.ndarray:
    y = lum(c)[..., None]
    return np.clip(np.where(y > 150, c, 1.5 * y + 0.1 * (c - y)), 0, 255)


def luma_blob(cv: str, av: str, sigma: float = 12.0, F: int = 4, hue_shift: float = 18 / 360):
    """Luma theme: the fall splat (salmon fill, red glow) -> smooth blob, hue moved from red to amber."""
    c = load(cv)
    a = load(av)
    body = a > 200
    d_old = sdist(body)
    # the luma fill is a pure edge-distance gradient (red rim -> salmon centre): rebuild all of it,
    # inside and outside, from the original's own per-distance medians
    sel = d_old < 40
    cs, ms = profile(d_old[sel], np.concatenate([a[sel][:, None], c[sel]], 1), d_old.min(), 40)
    nb = new_blob(body, np.zeros_like(body), sigma, F)
    d_new = sdist(nb) / F
    prof = interp_profile(d_new, cs, ms)
    col = downscale(prof[..., 1:], F)
    alpha = downscale(np.clip(prof[..., 0], 0, 255), F)
    inside = downscale(nb.astype(np.float64), F) > 0.999
    alpha = np.where(inside, 255, alpha)
    h, s, v = rgb_to_hsv(np.clip(col, 0, 255))
    col = hsv_to_rgb((h + hue_shift) % 1.0, s, v)
    return col, alpha


# --------------------------------------------------------------------------------------- recolour recipes
def decal_recolor(v: str):
    """Blood-red splatter on white -> dark oil/scorch brown-grey; white background and shape kept."""
    c = load(v)
    y = lum(c)[..., None]
    # target tint: dark sooty brown-grey, keeping each pixel's luminance (texture, streaks, shading)
    tint = np.array([1.12, 1.0, 0.86])
    darkness = 1 - y / 255.0
    rec = np.clip(y * tint * 0.92, 0, 255)
    w = smoothstep(0.02, 0.12, darkness)  # pure white background untouched
    return c * (1 - w) + rec * w


def decal_help(cv: str, av: str):
    """HELP written in dripping blood -> dark-grey spray paint; the long drips under the letters trimmed."""
    c = load(cv)
    a = load(av)
    m = a > 40
    # horizontal opening (9 px): letter strokes survive, thin vertical drips do not
    k = 4
    er = m.copy()
    for s in range(1, k + 1):
        er &= np.roll(m, s, 1) & np.roll(m, -s, 1)
    op = er.copy()
    for s in range(1, k + 1):
        op |= np.roll(er, s, 1) | np.roll(er, -s, 1)
    # only cut drips below the letters: keep everything that the opening keeps, plus all pixels within
    # 3 px of it (soft edges), and restore anything above the drip zone untouched
    keep = dilate(op, 3)
    soft = blur(keep.astype(np.float64), 1.2, False)
    a2 = a * np.clip(soft * 1.3 - 0.15, 0, 1)
    y = lum(c)[..., None]
    paint = np.clip(y * np.array([0.95, 1.0, 1.08]) * 0.55 + 18, 0, 255)  # cool dark-grey paint
    wpaint = smoothstep(0.05, 0.3, redness(c))[..., None]
    c2 = c * (1 - wpaint) + paint * wpaint
    return c2, a2


def stain(v: str, t0=0.18, t1=0.38, keep_luma=1.0, lift=0.0, region=None):
    """Recolour pixels redder than the surface to the surface colour (luminance detail kept)."""
    c = load(v)
    r = redness(c)
    w = smoothstep(t0, t1, r)
    if region is not None:
        y0, y1, x0, x1 = region
        reg = np.zeros(w.shape)
        reg[y0:y1, x0:x1] = 1
        w = w * reg
    w = np.maximum(w, blur(w, 1.0, True) * 0.9)  # catch the anti-aliased stain fringe
    known = w < 0.05
    surf = fill(c, known, True)
    y = lum(c)
    ys = np.maximum(lum(surf), 1)
    ratio = (y / ys)[..., None]
    ratio = keep_luma * ratio + (1 - keep_luma)
    rec = surf * ratio + lift * (surf - surf * ratio)
    return c * (1 - w[..., None]) + np.clip(rec, 0, 255) * w[..., None]


def debris(v: str, t0=0.08, t1=0.3):
    """Flesh/gib colours -> grey-brown rock: hue and most saturation replaced, luminance kept."""
    c = load(v)
    y = lum(c)[..., None]
    rock = np.clip(y * np.array([1.10, 1.02, 0.90]) * 1.15, 0, 255)
    w = smoothstep(t0, t1, redness(c))[..., None]
    return c * (1 - w) + rock * w


def veins(v: str):
    """Eye texture: pink-red veins -> pale grey (structure kept)."""
    c = load(v)
    y = lum(c)[..., None]
    grey = np.clip(y * np.array([1.0, 0.99, 1.0]), 0, 255)
    h, s, _ = rgb_to_hsv(c)
    hue_red = (h < 0.04) | (h > 0.90)
    w = (smoothstep(0.06, 0.20, s) * hue_red)[..., None]
    return c * (1 - w) + grey * w


def skull(v: str):
    """bloodyskull: the dark blood-red smears in sockets/mouth -> dark brown-grey grime."""
    c = load(v)
    y = lum(c)[..., None]
    grime = np.clip(y * np.array([1.08, 1.0, 0.92]), 0, 255)
    w = smoothstep(0.15, 0.40, redness(c))[..., None]
    return c * (1 - w) + grime * w


# -------------------------------------------------------------------------------------------- recipes
D = "gfx/hud/default/"
L = "gfx/hud/luma/"
RECIPES: list[tuple[list[str], str, str, object]] = []


def rec(outs, what, method, fn):
    RECIPES.append((outs, what, method, fn))


for n in ("death", "fall", "headshot", "melee_laser", "outofammo", "selfkill"):
    rec([D + f"notify_{n}.jpg", D + f"notify_{n}_alpha.jpg"],
        "blood-splatter badge reshaped into a smooth irregular rounded blob (droplets/drips removed), fill desaturated "
        "from blood red to dark warm grey; word, size, white outline/glow kept; _alpha rebuilt from the same shape",
        "splat_badge(neutral)", (lambda n=n: splat_badge(D + f"notify_{n}.jpg", D + f"notify_{n}_alpha.jpg", "neutral")))
for n in ("blue", "pink", "red", "yellow"):
    rec([D + f"notify_teamkill_{n}.jpg", D + f"notify_teamkill_{n}_alpha.jpg"],
        f"team-coloured ({n}) splatter badge reshaped into a smooth irregular rounded blob (droplets removed); "
        "team colour, word TEAM, outline/glow kept; _alpha rebuilt from the same shape",
        "splat_badge(team)", (lambda n=n: splat_badge(D + f"notify_teamkill_{n}.jpg", D + f"notify_teamkill_{n}_alpha.jpg", "team")))
rec([L + "notify_fall.jpg", L + "notify_fall_alpha.jpg"],
    "luma splat (red, spiky) reshaped into a smooth irregular rounded blob and hue moved from red to amber; "
    "glow profile kept; _alpha rebuilt from the same shape", "luma_blob", lambda: luma_blob(L + "notify_fall.jpg", L + "notify_fall_alpha.jpg"))
for i in range(1, 6):
    rec([f"textures/decals/splatter0{i}.jpg"],
        "dark blood-red splatter recoloured to dark sooty brown-grey (oil/scorch); shape, texture and _alpha unchanged",
        "decal_recolor", (lambda i=i: [decal_recolor(f"textures/decals/splatter0{i}.jpg")]))
rec(["textures/trak4x/decal/decal_help.jpg", "textures/trak4x/decal/decal_help_alpha.jpg"],
    "HELP written in dripping blood -> dark-grey spray paint, thin drips under the letters trimmed (same in _alpha)",
    "decal_help", lambda: decal_help("textures/trak4x/decal/decal_help.jpg", "textures/trak4x/decal/decal_help_alpha.jpg"))

STAIN = {
    "textures/evil1_floors/br_tiles_blood.jpg": {},
    "textures/evil1_floors/br_tiles_brkblood.jpg": {},
    "textures/evil1_floors/carpet_drty_blood.jpg": {"t0": 0.42, "t1": 0.62},
    "textures/evil1_floors/carpet_drty_blood2.jpg": {"t0": 0.42, "t1": 0.62},
    "textures/evil1_floors/floortilebig2.jpg": {},
    "textures/evil2_basefloor/flr_b-w_drty_bbig.jpg": {},
    "textures/evil2_basefloor/flr_b-w_drty_bld.jpg": {},
    "textures/evil2_basefloor/flr_b-w_drty_bld2.jpg": {},
    "textures/evil2_basefloor/flr_tmtl_drk_bld.jpg": {},
    "textures/evil2_basewall/cementwall_btm_gore.jpg": {},
    "textures/evil2_misc/crate_drtycamo2.jpg": {},
    "textures/evil2_misc/crate_drtyow.jpg": {},
    "textures/evil2_misc/ecrate_drty2.jpg": {},
    "textures/evil2_misc/ecrate_drty3ow.jpg": {},
    "textures/evil3_floors/bdirt_blood.jpg": {"t0": 0.22, "t1": 0.42},
    "textures/evil3_floors/cemdrk_oddtile_bld.jpg": {},
    "textures/evil3_floors/cemdrk_oddtile_bldb.jpg": {"t0": 0.12, "t1": 0.30},
    "textures/evil3_floors/wd_tile_drk_bld.jpg": {},
    "textures/evil3_floors/woodvfloor3_brain.jpg": {},
    "textures/techpanelx/panel/panel_tech2r_gloss.jpg": {},
}
for v, kw in STAIN.items():
    rec([v], "blood stains recoloured to the surrounding surface colour (luminance detail kept, reads as dirt/grime); "
        "unstained pixels unchanged", "stain", (lambda v=v, kw=kw: [stain(v, **kw)]))
for v in ("textures/ignishead.jpg", "textures/ignisheadfb.jpg"):
    rec([v], "bleeding cut/drip on the forehead painted over with the surrounding skin colour; rest unchanged",
        "inpaint", (lambda v=v: [stain(v, t0=0.40, t1=0.55, keep_luma=0.35, region=(130, 560, 120, 1050))]))
rec(["textures/gib1.jpg"], "red flesh gib texture recoloured to grey-brown rock (luminance/structure kept)", "debris",
    lambda: [debris("textures/gib1.jpg")])
rec(["models/gibs/chunk.mdl_0.jpg"], "red flesh chunk skin recoloured to grey-brown rock (luminance kept)", "debris",
    lambda: [debris("models/gibs/chunk.mdl_0.jpg")])
rec(["textures/eye.jpg"], "pink-red veins on the eyeball made pale grey (shape kept); iris unchanged", "veins",
    lambda: [veins("textures/eye.jpg")])
rec(["textures/bloodyskull.jpg"], "dark blood-red smears in sockets/mouth recoloured to dark brown-grey grime", "skull",
    lambda: [skull("textures/bloodyskull.jpg")])

UNCHANGED = {
    "_bump.jpg": "bump/height map: encodes shape only, no blood colour; shape not changed -> unchanged",
    "_gloss.jpg": "gloss map (grayscale/specular), no blood colour; shape not changed -> unchanged",
    "_norm.jpg": "normal map: shape only -> unchanged",
    "_reflect.jpg": "reflection mask: shape only -> unchanged",
    "_shirt.jpg": "colormap mask (grayscale) -> unchanged",
    "_pants.jpg": "colormap mask (grayscale) -> unchanged",
    "_alpha.jpg": "alpha mask: shape kept (only the colour image was recoloured) -> unchanged",
}
UNCHANGED_FILES = {
    "models/turrets/basedestroyed_glow.jpg": "glow map of a destroyed turret (sparks/embers), no blood -> unchanged",
    "textures/final_rage/lava_glow.jpg": "lava glow map (molten rock), no blood -> unchanged",
    "textures/ignishead_glow.jpg": "glow mask (white/grey) of the head, no blood -> unchanged",
    "textures/ignishead_gloss.jpg": "gloss map of the head (dim skin tint), no blood feature -> unchanged",
    D + "notify_lava.jpg": "lava icon, not gore -> unchanged", D + "notify_lava_alpha.jpg": "lava icon mask -> unchanged",
    D + "notify_slime.jpg": "slime icon, not gore -> unchanged", D + "notify_slime_alpha.jpg": "slime icon mask -> unchanged",
    D + "notify_void.jpg": "void (vortex) icon, not gore -> unchanged", D + "notify_void_alpha.jpg": "void icon mask -> unchanged",
    D + "notify_melee_shotgun.jpg": "fish icon (melee shotgun), not gore -> unchanged",
    D + "notify_melee_shotgun_alpha.jpg": "fish icon mask -> unchanged",
}
for n in ("death", "lava", "melee_shotgun", "outofammo", "selfkill", "slime", "void", "teamkill_blue", "teamkill_neutral",
          "teamkill_pink", "teamkill_red", "teamkill_yellow"):
    for suf in (".jpg", "_alpha.jpg"):
        UNCHANGED_FILES[L + f"notify_{n}{suf}"] = (f"luma {n} icon is a stylised symbol (no blood splatter; team colour "
                                                   "where teamkill) -> unchanged")


def main() -> None:
    only = sys.argv[1:]
    listed = [ln.split("\t")[0] for ln in LIST.read_text().splitlines() if ln.strip() and not ln.startswith("#")]
    rows: dict[str, tuple[str, str]] = {}
    for outs, what, method, fn in RECIPES:
        if only and not any(o in x for o in only for x in outs):
            for x in outs:
                rows[x] = (what, method)
            continue
        res = fn()
        for x, arr in zip(outs, res):
            src_mode = Image.open(SRC / x).mode
            if src_mode == "L" and arr.ndim == 3:
                arr = lum(arr)
            save(x, arr)
            rows[x] = (what, method)
            print("fixed", x)
    for v in listed:
        if v in rows:
            continue
        why = UNCHANGED_FILES.get(v) or next((t for s, t in UNCHANGED.items() if v.endswith(s)), None)
        if why is None:
            raise SystemExit(f"no recipe for {v}")
        rows[v] = (why, "unchanged")
    LOG.parent.mkdir(parents=True, exist_ok=True)
    order = listed + sorted(set(rows) - set(listed))
    lines = ["# vpath\twhat changed\tmethod (tools/upload/gore_fix.py; output work/upload/fixed/<vpath>)"]
    for v in order:
        what, method = rows[v]
        lines.append(f"{v}\t{what}\t{method}")
    LOG.write_text("\n".join(lines) + "\n")
    print("log", LOG.relative_to(ROOT), len(order), "rows")


if __name__ == "__main__":
    main()
