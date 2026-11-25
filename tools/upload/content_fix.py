#!/usr/bin/env python3
"""CONTENT-FIX: Roblox-safe versions of the textures flagged by the content/text review (content_a/b/c.tsv,
text_b/c.tsv), changed as subtly as possible. The gore list (assets/optional/gore/textures.tsv) is handled by
gore_fix.py into work/upload/fixed/ and is skipped here.

  python3 tools/upload/content_fix.py [substring ...]   -> work/upload/fixed2/<vpath> (originals untouched)

Every changed file is rewritten from work/vfs-high/<vpath> at the same size and mode (JPEG quality 95);
assets/manifest/review/content_fixes.tsv is regenerated (vpath, issue, what changed). Deterministic: numpy +
Pillow only (helpers shared with gore_fix.py). All boxes are (x, y, w, h) in full-resolution pixels, checked by
eye on zoomed crops of the originals.

Operations:
  heal      remove text/logo in a box: the letter pixels (mode 'dark'/'light'/'dev': darker/lighter/different
            than the local background by `thr` luminance) or the whole box (mode 'all') are replaced by the
            surrounding surface, extended inward with small-scale normalized convolution, so the panel's own
            shading stays; edge feathered by ~1 px. Untouched pixels outside the mask stay bit-identical
            (apart from JPEG re-encoding).
  gblur     strong Gaussian blur of a box (feathered) for unreadable-by-design spots (screenshot server lists).
  retint    pixels redder than the surface (smoothstep on redness or red hue) -> a neutral grime colour
            with the same luminance (blood drops, smears, flesh).
  hue       hue rotation / saturation scale of reddish pixels (lava, rust, paint), luminance kept.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gore_fix as G  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "work/vfs-high"
DST = ROOT / "work/upload/fixed2"
LOG = ROOT / "assets/manifest/review/content_fixes.tsv"
GORE_LIST = ROOT / "assets/optional/gore/textures.tsv"


def load(v: str) -> np.ndarray:
    im = Image.open(SRC / v)
    return np.asarray(im.convert("L" if im.mode == "L" else "RGB")).astype(np.float64)


def save(v: str, a: np.ndarray) -> None:
    out = DST / v
    out.parent.mkdir(parents=True, exist_ok=True)
    a = np.clip(np.rint(a), 0, 255).astype(np.uint8)
    # 4:4:4 chroma (subsampling=0) like the release JPEGs: Pillow's default 4:2:0 would smear thin coloured text
    Image.fromarray(a, "L" if a.ndim == 2 else "RGB").save(out, quality=95, subsampling=0)


def L(a: np.ndarray) -> np.ndarray:
    return a if a.ndim == 2 else G.lum(a)


# ------------------------------------------------------------------------------------------------ ops
def _local(a, box, pad):
    x, y, w, h = box
    H, W = a.shape[:2]
    x0, y0, x1, y1 = max(0, x - pad), max(0, y - pad), min(W, x + w + pad), min(H, y + h + pad)
    return (x0, y0, x1, y1), (x - x0, y - y0, w, h)


def heal(a, box, mode="all", thr=18.0, grow=1, pad=24, sigmas=(1, 2, 3, 5, 8, 13, 21, 34), noref=None, seg=None):
    """Replace the text pixels (or the whole box) by the surrounding surface.
    noref: (x, y, w, h) boxes never used as reference surface (e.g. a black UV border next to the text)."""
    (x0, y0, x1, y1), (bx, by, bw, bh) = _local(a, box, pad)
    sub = a[y0:y1, x0:x1].copy()
    inbox = np.zeros(sub.shape[:2], bool)
    inbox[by:by + bh, bx:bx + bw] = True
    if seg is not None:  # slanted text: only a thick line segment ((x0, y0), (x1, y1), half_width) of the box
        (sx0, sy0), (sx1, sy1), hw = seg
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
        d = np.array([sx1 - sx0, sy1 - sy0], np.float64)
        t = np.clip(((xx - sx0) * d[0] + (yy - sy0) * d[1]) / (d @ d), 0, 1)
        inbox &= np.hypot(xx - sx0 - t * d[0], yy - sy0 - t * d[1]) <= hw
    bad = np.zeros(sub.shape[:2], bool)
    for nx, ny, nw, nh in noref or ():
        bad[max(0, ny - y0):max(0, ny + nh - y0), max(0, nx - x0):max(0, nx + nw - x0)] = True
    if mode == "all":
        mask = inbox
    else:
        bg = G.fill(sub, ~inbox & ~bad, False, sigmas)  # first guess of the surface under the box
        for _ in range(2):
            d = L(sub) - L(bg)
            txt = {"dark": d < -thr, "light": d > thr, "dev": np.abs(d) > thr}[mode]
            if sub.ndim == 3 and mode == "dev":
                txt |= np.abs(sub - bg).max(-1) > thr * 1.5
            txt &= inbox
            mask = G.dilate(txt, grow) & inbox
            bg = G.fill(sub, ~mask & ~bad, False, sigmas)
    new = G.fill(sub, ~mask & ~bad, False, sigmas)
    w = G.blur(mask.astype(np.float64), 0.6, False)
    w = np.maximum(w, mask)
    w = w * G.blur(inbox.astype(np.float64), 0.6, False) if mode == "all" else w
    w = np.maximum(w, mask * 1.0)
    if sub.ndim == 3:
        w = w[..., None]
    out = a.copy()
    out[y0:y1, x0:x1] = sub * (1 - w) + new * w
    return out


def flat(a, box):
    """Box on a uniform background (decal sheet): set to the median colour of the box's 1-px border."""
    x, y, w, h = box
    out = a.copy()
    ring = np.concatenate([a[y, x:x + w], a[y + h - 1, x:x + w], a[y:y + h, x], a[y:y + h, x + w - 1]])
    out[y:y + h, x:x + w] = np.median(ring, axis=0)
    return out


def gblur(a, box, sigma, feather=1.5):
    (x0, y0, x1, y1), (bx, by, bw, bh) = _local(a, box, int(3 * sigma) + 4)
    sub = a[y0:y1, x0:x1]
    inbox = np.zeros(sub.shape[:2])
    inbox[by:by + bh, bx:bx + bw] = 1
    w = G.blur(inbox, feather, False) if feather > 0 else inbox
    w = np.where(inbox > 0, np.maximum(w, 0.5), w)
    w = np.clip(w * 1.0, 0, 1)
    b = G.blur(sub, sigma, False)
    if sub.ndim == 3:
        w = w[..., None]
    out = a.copy()
    out[y0:y1, x0:x1] = sub * (1 - w) + b * w
    return out


def region_w(shape, box, feather):
    w = np.zeros(shape[:2])
    if box is None:
        return w + 1
    x, y, bw, bh = box
    w[y:y + bh, x:x + bw] = 1
    return np.clip(G.blur(w, feather, False) * 1.0, 0, 1) if feather > 0 else w


def retint(a, tint=(1.08, 1.0, 0.92), gain=1.0, t0=0.15, t1=0.40, box=None, feather=0.0, hue_only=False):
    """Reddish pixels -> luminance * tint (neutral grime/paint); others unchanged."""
    y = G.lum(a)[..., None]
    rec = np.clip(y * np.array(tint) * gain, 0, 255)
    if hue_only:
        h, s, v = G.rgb_to_hsv(a)
        red = ((h < 0.05) | (h > 0.93)).astype(np.float64)
        w = G.smoothstep(t0, t1, s) * red
    else:
        w = G.smoothstep(t0, t1, G.redness(a))
    w = (w * region_w(a.shape, box, feather))[..., None]
    return a * (1 - w) + rec * w


def hue(a, shift=0.0, sat=1.0, val=1.0, t0=0.0, t1=0.0, box=None, feather=0.0, hue_lo=0.93, hue_hi=0.06, target=None):
    """Rotate hue / scale saturation and value of red-hued pixels (weight by saturation)."""
    h, s, v = G.rgb_to_hsv(a)
    red = ((h >= hue_lo) | (h <= hue_hi)).astype(np.float64)
    w = (G.smoothstep(t0, t1, s) if t1 > t0 else np.ones_like(s)) * red
    w = w * region_w(a.shape, box, feather)
    if target is not None:  # pull the hue to `target` (fraction of the turn) instead of rotating it
        hh = np.where(h > 0.5, h - 1, h)
        h = (hh + (target - hh) * w) % 1.0
    n = G.hsv_to_rgb((h + shift * w) % 1.0, np.clip(s * (1 + (sat - 1) * w), 0, 1), np.clip(v * (1 + (val - 1) * w), 0, 1))
    return n


def soot_from_clean(a, clean_v, t0=0.04, t1=0.14):
    """Stain -> keep the stained image's luminance but take the clean sibling's colour (brown soot)."""
    c = load(clean_v)
    d = G.redness(a) - G.redness(c)
    w = G.smoothstep(t0, t1, d)
    w = np.maximum(w, G.blur(w, 1.0, True) * 0.9)[..., None]
    ratio = (G.lum(a) / np.maximum(G.lum(c), 1))[..., None]
    rec = np.clip(c * ratio, 0, 255)
    return a * (1 - w) + rec * w


def casing_ring(a, center, r0, r1, ang0, ang1, mode, thr, grow=1, grain=True):
    """Engraved text on the round shell base: letters in an annulus sector -> surrounding brass.
    Letter pixels = darker than the local brass by `thr` (colour maps) or off the local normal (normal map);
    they get the brass colour extended from the neighbouring non-letter pixels plus deterministic grain
    noise with the sector's own residual strength, so no smooth patch shows."""
    H, W = a.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    dx, dy = xx - center[0], yy - center[1]
    r = np.hypot(dx, dy)
    ang = np.degrees(np.arctan2(dy, dx))
    sector = (r >= r0) & (r <= r1) & (ang >= ang0) & (ang <= ang1)
    bg = G.blur(a, 4, False)
    for _ in range(3):
        if mode == "vec":
            txt = np.abs(a - bg).max(-1) > thr
        else:
            txt = (L(a) - L(bg)) < -thr
        mask = G.dilate(txt & sector, grow) & sector
        bg = G.fill(a, ~mask, False, (1, 2, 3, 5, 8))
    new = bg
    if grain:
        res = a - G.blur(a, 1.2, False)
        clean = sector & ~G.dilate(mask, 2)
        nz = G.blur(np.random.default_rng(0).standard_normal(a.shape), 0.6, False)
        nz /= nz.std()
        new = bg + nz * res[clean].std(0) * 0.8
    w = np.maximum(G.blur(mask.astype(np.float64), 0.6, False), mask)
    if a.ndim == 3:
        w = w[..., None]
    return a * (1 - w) + new * w


def needle_restore(orig, a, x0, x1, y0, y1):
    """Re-draw a straight vertical needle through a healed box from the rows just above and below it."""
    out = a.copy()
    top, bot = orig[y0 - 1, x0:x1], orig[y1, x0:x1]
    for yy in range(y0, y1):
        t = (yy - y0 + 1) / (y1 - y0 + 1)
        out[yy, x0:x1] = top * (1 - t) + bot * t
    return out


# --------------------------------------------------------------------------------------------- recipes
R: list[tuple[str, str, str, object]] = []  # (vpath, issue, what changed, fn(array)->array)


def rec(v, issue, what, fn):
    R.append((v, issue, what, fn))


# --- urls / server lists
rec("gfx/menu/wickedx/background_ingame.jpg", "url",
    "engraved '.ORG' after XONOTIC and the tiny unreadable engraved line under it removed (panel surface "
    "extended over them); XONOTIC wordmark kept",
    lambda a: heal(heal(a, (675, 999, 48, 14), "dark", 10, 1), (528, 1017, 212, 8), "dark", 8, 1))
rec("gfx/menu/wickedx/background_l2.jpg", "url",
    "engraved '.ORG' after XONOTIC and the tiny engraved line under it removed (panel surface extended); "
    "XONOTIC wordmark kept",
    lambda a: heal(heal(a, (675, 999, 48, 14), "dark", 10, 1), (528, 1017, 212, 8), "dark", 8, 1))
rec("gfx/menu/wickedx/skinpreview.jpg", "url",
    "downscaled '.ORG' after the engraved XONOTIC in the bottom frame removed",
    lambda a: heal(a, (134, 248, 15, 8), "dark", 8, 0))
rec("gfx/menu/xaw/skinpreview.jpg", "url",
    "screenshot server list: host-name column (web addresses) and the Address: IP field blurred unreadable; "
    "rest of the screenshot unchanged",
    lambda a: gblur(gblur(a, (419, 229, 196, 181), 2.5), (446, 408, 84, 13), 2.5))
rec("gfx/menu/luminos/skinpreview.jpg", "url",
    "tiny screenshot server list rows blurred (possible server domains)",
    lambda a: gblur(a, (143, 87, 88, 16), 1.5))
rec("models/trak/tablet_xon3.jpg", "url",
    "tablet text lines 'VISIT: WWW.XONOTIC.ORG / IRC CHANNEL: #XONOTIC @ IRC.QUAKENET.ORG' erased to the "
    "paper surface; logo, 'JOIN THE COMMUNITY' and 'GL & HF PLAYING XONOTIC' kept",
    lambda a: heal(a, (141, 79, 88, 52), "dark", 22, 1))

# --- phone-like digit strings
rec("models/trak/pen.jpg", "phone",
    "printed phone number '512-843-7884' on the pen erased to the pen colour; 'TRaK Inc.' kept",
    lambda a: heal(a, (36, 16, 9, 38), "all", noref=[(45, 0, 12, 64)]))
rec("models/containers/crate01.jpg", "phone",
    "stencilled serial '32157-5454-DF' erased to the crate paint", lambda a: heal(a, (338, 498, 66, 13), "light", 12, 1, noref=[(300, 511, 150, 1)]))
rec("textures/evil6_support/e6panelsym.jpg", "phone",
    "faint stencilled number '332-6x' at the bottom of the panel erased to the panel surface",
    lambda a: heal(a, (64, 110, 40, 14), "dev", 8, 1))
rec("gfx/reticle_nex_alpha.jpg", "phone",
    "scope readout digits 'm 12345 423--60 -433-00' blurred into an unreadable glow line (alpha only; colour "
    "plane is black there)", lambda a: gblur(a, (1172, 486, 126, 16), 2.5))

# --- crude / sexual / drug text
rec("models/trak/pbox.jpg", "text",
    "pizza-box side slogan 'Your destination for space defecation' erased to the box red; PIZZA GRONDINI'S, "
    "artwork and barcode kept", lambda a: heal(a, (242, 47, 11, 152), "light", 18, 1))
for v in ("models/casing_bronze.jpg", "models/casing_bronze_gloss.jpg", "models/casing_bronze_reflect.jpg",
          "models/casing_bronze_norm.jpg"):
    rec(v, "text", "engraved 'YOUR MOM IS FAT' around the primer erased to the surrounding brass "
        "(other engraving and primer kept)" + (" (normal map: emboss flattened)" if "norm" in v else ""), None)
for v in ("textures/facility114x/wall/corridor01.jpg", "textures/facility114x/wall/corridor01b.jpg",
          "textures/facility114x/wall/corridor01r.jpg", "textures/facility114invx/wall/corridor01inv.jpg",
          "textures/facility114invx/wall/corridor01invr.jpg"):
    rec(v, "sexual", "rule 'NO PORNOGRAPHIC MATERIALS ALLOWED BEYOND PERSONAL CUBICLES' and its bullet erased to the "
        "flat panel colour; other rules (incl. NO SMOKING) kept", lambda a: flat(a, (66, 231, 160, 19)))
    g = v.replace(".jpg", "_gloss.jpg")
    rec(g, "sexual", "bullet of the removed rule erased in the gloss map (keeps it in sync with the colour map)",
        lambda a: flat(a, (66, 231, 14, 12)))
for v in ("textures/facility114x/wall/corridor02.jpg", "textures/facility114invx/wall/corridor02inv.jpg",
          "textures/facility114invx/wall/corridor02invr.jpg"):
    rec(v, "gore", "warning sentence 'THE RED BUTTONS MAY CAUSE DECAPITATION AND EXPLOSIVE EVISCERATION.' erased to "
        "the flat panel colour; WARNING title and the rest of the notice kept", lambda a: flat(a, (21, 183, 224, 25)))
    rec(v.replace(".jpg", "_gloss.jpg"), "gore", "faint ghost of the removed sentence erased in the gloss map",
        lambda a: flat(a, (21, 183, 224, 25)))
rec("textures/trak4x/decal/decal_pills.jpg", "drugs",
    "word 'PILLS' removed from 'DID YOU TAKE YOUR PILLS TODAY?' (white background); bottle art kept",
    lambda a: flat(a, (292, 226, 246, 57)))
rec("textures/trak4x/decal/decal_pills_alpha.jpg", "drugs", "word 'PILLS' removed from the decal alpha mask",
    lambda a: flat(a, (292, 226, 246, 57)))

# --- brands
COCKPIT_TXT = [((93, 73, 70, 19), "light", 20), ((98, 196, 64, 16), "light", 20), ((155, 176, 50, 40), "light", 10),
               ((870, 142, 50, 15), "dev", 12)]


def cockpit(a, glow=False):
    o = a
    for box, mode, thr in (COCKPIT_TXT[-1:] if glow else COCKPIT_TXT):
        if box[0] == 155:  # part number '(c)2004-6180', written slanted along the bezel; red LED not a reference
            a = heal(a, box, mode, thr, 2, seg=((161, 210), (199, 186), 4.5), noref=[(189, 168, 16, 13)])
        else:
            a = heal(a, box, mode, thr, 2 if mode == "dev" else 1)
    if not glow:  # AutoGauge badge: whole badge -> gauge face, red needle re-drawn through it
        a = heal(a, (366, 70, 48, 24), "all", noref=[(377, 30, 15, 100)])
        a = needle_restore(o, a, 378, 391, 70, 94)
    return a


rec("textures/cockpit.jpg", "brand",
    "real gauge maker marks removed: 'COBALT', 'Auto Meter' + part number, AutoGauge badge on the speedometer "
    "(needle kept) and the AutoMeter logo on the boost gauge, all to the gauge-face colour",
    lambda a: cockpit(a))
rec("textures/cockpit_glow.jpg", "brand", "AutoMeter logo on the boost gauge glow removed (same box as cockpit.jpg)",
    lambda a: cockpit(a, True))
for v in ("textures/facility114x/misc/door01.jpg", "textures/facility114invx/misc/door01inv.jpg"):
    rec(v, "brand", "'APERTURE' (Valve trademark) wordmark erased to the flat door grey; small tags beside it kept",
        lambda a: heal(a, (100, 188, 298, 42), "all"))

# --- gore / blood
rec("maps/darkzone.jpg", "gore", "map preview: the reddish fleshy wall panel desaturated to the surrounding "
    "wood-brown (luminance kept)", lambda a: retint(a, (1.16, 1.0, 0.80), 1.0, 0.06, 0.30, (172, 180, 62, 84), 3))
for v in ("textures/desertfactory_signs/above_dirty.jpg", "textures/desertfactory_shaders/sign_above_dirty.jpg"):
    rec(v, "gore", "red blood drops on the CAUTION sign recoloured to dark brown dirt/oil spots (luminance and "
        "shape kept); sign yellow/black unchanged", lambda a: retint(a, (1.12, 1.0, 0.80), 0.95, 0.35, 0.6, hue_only=True))
rec("textures/dmask1.jpg", "gore", "exposed red gums/flesh under the helmet toned to dark brown-grey (luminance kept)",
    lambda a: retint(a, (1.10, 1.0, 0.90), 1.0, 0.10, 0.30))
for v in ("textures/evil1_liquids/lavaish.jpg", "textures/evil1_liquids/lavaishb.jpg"):
    rec(v, "gore", "blood-red lava hue moved ~13 deg toward orange (reads as lava, not a blood pool); "
        "brightness/pattern kept", lambda a: hue(a, 0.036, 1.0, 1.0))
for v in ("textures/evil1_walls/crude_1.jpg", "textures/evil1_walls/crude_2.jpg"):
    rec(v, "gore", "dark-red rust drips shifted toward rust-orange/brown and slightly desaturated so they read as "
        "rust, not blood", lambda a: hue(a, 0.025, 0.85, 1.0, 0.25, 0.6))
rec("textures/evil2_basewall/dirtybrick_faded_stn.jpg", "gore",
    "red smear on the bricks recoloured with the clean dirtybrick_faded colours (stain luminance kept, reads as "
    "brown soot)", lambda a: soot_from_clean(a, "textures/evil2_basewall/dirtybrick_faded.jpg"))
rec("textures/evil2_misc/crate_drtyow_sign.jpg", "gore",
    "blood splatter at the bottom of the crate recoloured to the surrounding wood/grime colour (luminance kept)",
    lambda a: _stain(a, "textures/evil2_misc/crate_drtyow_sign.jpg"))
rec("textures/eyeblood.jpg", "gore", "blood-red eye texture recoloured to dark brown-grey (luminance/pattern kept)",
    lambda a: retint(a, (1.08, 1.0, 0.92), 1.0, 0.05, 0.25))
rec("textures/flesh1.jpg", "gore", "raw-flesh red streaks recoloured to grey-brown rock/metal (luminance kept)",
    lambda a: retint(a, (1.10, 1.02, 0.90), 1.15, 0.08, 0.3))
for n in (2, 3, 4):
    rec(f"textures/gib{n}.jpg", "gore", "raw-meat red gib texture recoloured to grey-brown rock debris (luminance "
        "and structure kept, same recipe as gib1 in gore_fix.py)", lambda a: retint(a, (1.10, 1.02, 0.90), 1.15, 0.08, 0.3))
rec("textures/hook.jpg", "gore", "dark-red smears on the claw tips recoloured to grey grime (luminance kept)",
    lambda a: retint(a, (1.04, 1.0, 0.96), 1.0, 0.06, 0.20, hue_only=True))
rec("textures/map_catharsis/samual_easter.jpg", "gore",
    "blood-red 'Samual balance' credit and its splatters recoloured to light grey paint (shapes kept, "
    "author name kept)", lambda a: retint(a, (1.0, 1.0, 1.02), 1.25, 0.15, 0.40))
rec("textures/spider.jpg", "gore",
    "deep-red raw-flesh areas (mouth rim, abdomen pits, side stripes) pulled to the body's brown-orange hue; orange body and everything else unchanged (luminance kept)",
    lambda a: hue(a, 0, 0.9, 1.0, 0.35, 0.6, None, 0, 0.93, 0.03, 0.055))
rec("textures/techpanelx/panel/panel_tech2r.jpg", "gore",
    "dark maroon paint splotches shifted to a brighter team-red paint (hue +9 deg, saturation x1.4, brightness x1.3) so "
    "they read as paint like the b/g/y variants", lambda a: hue(a, 0.025, 1.4, 1.3, 0.12, 0.3))


def _stain(a, v):
    return G.stain(v, region=(150, 256, 0, 256))


def casing(v, a):
    # primer centre measured on zoomed crops of each map (colour/gloss/reflect/norm differ by ~1 px)
    if v.endswith("_norm.jpg"):
        return casing_ring(a, (200.0, 200.0), 29, 49, -128, 102, "vec", 14, 1, grain=False)
    if v.endswith("casing_bronze.jpg"):
        return casing_ring(a, (198.5, 199.0), 29, 49, -128, 102, "lum", 12, 1)
    return casing_ring(a, (198.75, 200.0), 29, 49, -128, 102, "lum", 38, 2)


# reviewed rows deliberately left unchanged (owner rules: keep XONOTIC logos without domain, author nicknames, sky
# credits, symbols; Nexuiz mentions only noted; engine-tinted white sprites stay)
NOTED = {
    "particles/particlefont.jpg": ("gore", "white droplet/splat sprites tinted red by the engine; shapes kept (tint is code)"),
    "particles/particlefont-template.jpg": ("gore", "template copy of particlefont, same white sprites; kept"),
    "gfx/blood.jpg": ("gore", "grey tint-mask splat sprite (colour comes from the engine); kept like particlefont"),
    "gfx/blood_alpha.jpg": ("gore", "alpha of gfx/blood.jpg; kept"),
    "gfx/hud/default/minigames/pp/piece_taken.jpg": ("gore", "white cartoon splat tinted in game; kept like particlefont"),
    "textures/meat.jpg": ("gore", "near-black base, flesh colour only from the runtime pants tint; kept"),
    "textures/meat_pants.jpg": ("gore", "grey colormap mask (no red in the image); kept"),
    "textures/meat_alien.jpg": ("gore", "green alien gib texture, not red; kept"),
    "textures/bloodyskull_alien.jpg": ("other", "no blood visible, only the file name; kept (rename is an upload-name matter)"),
    "textures/bloodyskull_robot.jpg": ("other", "no blood visible, only the file name; kept"),
    "models/trak/tablet_xon1.jpg": ("text", "Xonotic/Nexuiz blurb, no address; Nexuiz mention noted only"),
    "models/trak/tablet_xon2.jpg": ("text", "'direct successor of the Nexuiz project'; Nexuiz mention noted only"),
    "models/trak/tablet_xon0.jpg": ("text", "'successor of Nexuiz' (not flagged by review); Nexuiz mention noted only"),
    "models/desertfactory/textures/documents/writing02_alpha.jpg": ("text", "graffiti 'Nexuiz Rulez'; noted only"),
    "models/desertfactory/textures/shaders/writing02.jpg": ("text", "graffiti 'Nexuiz Rulez'; noted only"),
    "textures/stralenex1/slimepit_ad-3.jpg": ("brand", "'nexuiz' credit tile; noted only"),
    "textures/stralenex1/slimepit_ad-3_glow.jpg": ("brand", "'nexuiz' credit tile glow; noted only"),
    "models/desertfactory/textures/documents/note02.jpg": ("brand", "map author's tool credits (NetRadiant, Blender, GIMP...); kept"),
    "models/desertfactory/textures/documents/note03.jpg": ("brand", "texture credits (Blender disc, Nexuiz); kept"),
    "models/desertfactory/textures/documents/note01.jpg": ("hate", "ring-and-cross emblem; owner said keep"),
    "models/desertfactory/textures/documents/newspaper01.jpg": ("other", "newspaper soldier photo; owner said keep"),
    "models/it/lcd.jpg": ("brand", "'ALIEN TX' is not a real brand name; kept"),
    "models/trak/pbox.jpg#barcode": ("phone", "barcode digits are a product code, not phone-like; kept"),
    "textures/aggressor/numlock.jpg": ("phone", "keypad digits 1-9, not a number string; kept"),
    "textures/evil9/9screen01.jpg": ("text", "tiny engraved line is illegible (no URL visible); NEXX CORP is fictional; kept"),
    "textures/map_space-elevator/screen-blue.jpg": ("text", "same illegible line / NEXX CORP as 9screen01; kept"),
    "textures/evil9/9techwall05b.jpg": ("text", "NEXX CORP (fictional); kept"),
    "textures/e7/e7wgrate.jpg": ("other", "pentagram grate ornament; owner said keep"),
    "textures/e7/e7wgrate_alpha.jpg": ("other", "pentagram grate alpha; kept"),
    "textures/e7/e7bigwall.jpg": ("other", "star-in-circle ornament; kept"),
    "gfx/reticle_nex.jpg": ("phone", "colour plane is black under the digits; only the _alpha needed the change"),
    "textures/trak5x/panel/panel_comp1a_glow.jpg": ("other", "illegible filler text; kept"),
    "textures/map_courtfun/screen_obey.jpg": ("brand", "generic word OBEY (They Live); kept"),
    "gfx/menu/wickedx/skinpreview.jpg#mp": ("url", "multiplayer panel in the screenshot is a map list, no server names; only .ORG removed"),
}
for _n in ("darkplaces-icon", "XONOTIC wordmarks (conback3, loading, luma/luminos l2, c4/pong/ttt boards)",
           "author handles (kuniuthefrogg, SMILECYTHE, strahlemann, FRUITIEX, Samual balance)", "NewSky / sky credits"):
    NOTED["(" + _n + ")"] = ("text/brand", "game/engine logo, author nickname or sky credit; owner said keep")


# ------------------------------------------------------------------------------------------- main
def main() -> None:
    only = sys.argv[1:]
    gore = {ln.split("\t")[0] for ln in GORE_LIST.read_text().splitlines() if ln.strip() and not ln.startswith("#")}
    todo: dict[str, list] = {}
    for v, issue, what, fn in R:
        assert v not in gore, v
        todo.setdefault(v, []).append((issue, what, fn))
    rows = []
    for v, ops in todo.items():
        for issue, what, _ in ops:
            rows.append((v, issue, what))
        if only and not any(o in v for o in only):
            continue
        a = load(v)
        for _, _, fn in ops:
            a = casing(v, a) if fn is None else fn(a)
        save(v, a)
        print("fixed", v)
    rows += [(v, i, "UNCHANGED (noted): " + w) for v, (i, w) in NOTED.items()]
    LOG.write_text("# vpath\tissue\twhat changed (content_fix.py -> work/upload/fixed2/)\n"
                   + "".join(f"{v}\t{i}\t{w}\n" for v, i, w in rows))


if __name__ == "__main__":
    main()
