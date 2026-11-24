#!/usr/bin/env python3
"""UPLOAD-FIX3: Roblox-safe versions of the images flagged by the 2026-11-23 strict review
(assets/manifest/review/upload_findings_{a..f}.tsv, G-051), changed as subtly as possible (D-025).

  python3 tools/upload/content_fix3.py [substring ...]   -> work/upload/fixed3/<vpath>   (nothing is uploaded)

The strict review looked at the upload-ready set, so every recipe starts from the file that would be uploaded
today: work/upload/fixed/ (gore_fix.py) > fixed2/ (content_fix.py) > blurred/ (blur_text.py) > work/vfs-high/
(the original). Run those three tools first. Output: same size and mode, JPEG quality 95, 4:4:4. Deterministic:
numpy + Pillow only, helpers from gore_fix.py (G) and content_fix.py (C). Boxes are (x, y, w, h) in
full-resolution pixels, read off zoomed crops.

Every row of the findings is either fixed (assets/manifest/review/content_fixes3.tsv) or deliberately kept
(content_kept3.tsv, with the reason); main() refuses to run if a finding is in neither or in both.
Rule used (owner, 2026-11-24): fix every high and medium item, and low items with real names/handles, brands,
other games' names, anything blood/gore-like, crosses/stars/hooked-cross shapes, body-like shapes, letters or
digits that could read as a flagged code, or drug references. Harmless signage and the XONOTIC wordmark (no
URL) stay. _norm/_gloss/_alpha/_glow/_bump maps get the same change as their colour map.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import content_fix as C  # noqa: E402
import gore_fix as G  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ORIG = ROOT / "work/vfs-high"
CHAIN = [ROOT / "work/upload/fixed", ROOT / "work/upload/fixed2", ROOT / "work/upload/blurred", ORIG]
DST = ROOT / "work/upload/fixed3"
REVIEW = ROOT / "assets/manifest/review"
LOG_FIXED = REVIEW / "content_fixes3.tsv"
LOG_KEPT = REVIEW / "content_kept3.tsv"


# ----------------------------------------------------------------------------------------------- io
def src_path(v: str) -> Path:
    for d in CHAIN:
        if (d / v).exists():
            return d / v
    raise FileNotFoundError(v)


def _arr(p: Path) -> np.ndarray:
    im = Image.open(p)
    return np.asarray(im.convert("L" if im.mode == "L" else "RGB")).astype(np.float64)


def load(v: str) -> np.ndarray:
    """The image that would be uploaded today (earlier fixes included)."""
    return _arr(src_path(v))


def orig(v: str) -> np.ndarray:
    return _arr(ORIG / v)


def save(v: str, a: np.ndarray) -> None:
    out = DST / v
    out.parent.mkdir(parents=True, exist_ok=True)
    a = np.clip(np.rint(a), 0, 255).astype(np.uint8)
    Image.fromarray(a, "L" if a.ndim == 2 else "RGB").save(out, quality=95, subsampling=0)


def findings() -> dict[str, tuple[str, str, str]]:
    """vpath -> (n, severity, issue) of the strict review."""
    out = {}
    for f in sorted(REVIEW.glob("upload_findings_*.tsv")):
        for ln in f.read_text(encoding="utf-8").splitlines():
            if ln.strip() and not ln.startswith("#"):
                c = ln.split("\t")
                out[c[1]] = (c[0], c[3], c[2])
    return out


# ---------------------------------------------------------------------------------------------- ops
# (shared ones come from content_fix.py: C.heal, C.flat, C.gblur, C.retint, C.hue)
def soft_patch(a, clean_v, k=0.5, sigma=7.0, thr=10.0, grow=3, feather=2.5, wrap=True, tile=1, mono=False):
    """Splatter on a tile that has a clean sibling texture (same layout): inside the splatter the image becomes
    the clean sibling plus only the low-pass part of the stain, scaled by k. Droplets, spray, drips and any
    lump lose their outline; a faint soft dirt patch stays where the stain was. Pixels outside are unchanged.
    tile: the stained texture is tile x tile copies of the sibling. mono: keep only the stain's darkness, not
    its colour cast (pink tint)."""
    c = orig(clean_v)
    if c.ndim == 2 and a.ndim == 3:  # greyscale sibling of an RGB texture
        c = np.repeat(c[..., None], 3, -1)
    if tile > 1:
        c = np.tile(c, (tile, tile, 1) if c.ndim == 3 else (tile, tile))
    d = a - c
    dl = G.lum(d) if a.ndim == 3 else d
    m = np.abs(G.blur(dl, 1.0, wrap)) > thr
    if mono:
        m |= np.abs(G.blur(d, 1.0, wrap)).max(-1) > thr
        d = np.repeat(dl[..., None], 3, -1)
    m = G.dilate(G.drop_small(m, 6), grow)
    w = np.clip(G.blur(m.astype(np.float64), feather, wrap) * 1.6, 0, 1)
    new = c + k * G.blur(d, sigma, wrap)
    if a.ndim == 3:
        w = w[..., None]
    return a * (1 - w) + new * w


def clone_patch(a, box, shift, k=0.0, thr=None, sigma=10.0, grow=3, feather=2.5, lowfreq=False):
    """Clone stamp inside one image: pixels of `box` (x, y, w, h) are replaced by the pixels `shift` = (dx, dy)
    away (wrapping; pick a multiple of the pattern period so the pattern lines up). thr=None replaces the whole
    box (feathered); with thr only pixels darker than the clone by more than thr (the stain) are replaced.
    k > 0 keeps that fraction of the old low-pass darkness as a soft neutral shadow."""
    x, y, w, h = box
    src = np.roll(a, (-shift[1], -shift[0]), (0, 1))
    inbox = np.zeros(a.shape[:2], bool)
    inbox[y:y + h, x:x + w] = True
    dl = (G.lum(a) if a.ndim == 3 else a) - (G.lum(src) if a.ndim == 3 else src)
    if thr is None:
        m = inbox
    else:
        m = G.dilate(G.drop_small((G.blur(dl, 1.5, False) < -thr) & inbox, 8), grow) & inbox
    wgt = np.clip(G.blur(m.astype(np.float64), feather, False) * 1.6, 0, 1) * G.blur(inbox.astype(np.float64), 1.5, False)
    if lowfreq:  # only the clone's fine detail; the large-scale shading is extended from around the box
        src = G.fill(a, ~G.dilate(m, 2), False, (4, 8, 16, 32, 64)) + (src - G.blur(src, 4.0, False))
    new = src + k * np.minimum(G.blur(dl * inbox, sigma, False), 0)[..., None] if a.ndim == 3 else \
        src + k * np.minimum(G.blur(dl * inbox, sigma, False), 0)
    if a.ndim == 3:
        wgt = wgt[..., None]
    return a * (1 - wgt) + new * wgt


def rot_disc(a, cx, cy, r, deg, feather=1.0, band=None, normal=False):
    """Turn the disc (centre cx, cy; radius r) by `deg` degrees counter-clockwise, in place (bilinear sampling;
    180 degrees with a half-pixel centre is an exact pixel swap). band: only rows with |y - cy| <= band.
    normal=True: tangent-space normal map (x right, y up): the encoded vectors are turned by the same angle."""
    H, W = a.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
    dx, dy = xx - cx, yy - cy
    t = np.radians(deg)
    # content turns CCW on screen (y down): sample the source at the point turned back (clockwise)
    sx = cx + dx * np.cos(t) - dy * np.sin(t)
    sy = cy + dx * np.sin(t) + dy * np.cos(t)
    x0, y0 = np.floor(sx).astype(int), np.floor(sy).astype(int)
    fx, fy = sx - x0, sy - y0
    x0c, x1c = np.clip(x0, 0, W - 1), np.clip(x0 + 1, 0, W - 1)
    y0c, y1c = np.clip(y0, 0, H - 1), np.clip(y0 + 1, 0, H - 1)
    if a.ndim == 3:
        fx, fy = fx[..., None], fy[..., None]
    rot = (a[y0c, x0c] * (1 - fx) + a[y0c, x1c] * fx) * (1 - fy) + (a[y1c, x0c] * (1 - fx) + a[y1c, x1c] * fx) * fy
    if normal:
        nx, ny = rot[..., 0] - 127.5, rot[..., 1] - 127.5
        rot = rot.copy()
        rot[..., 0] = nx * np.cos(t) - ny * np.sin(t) + 127.5
        rot[..., 1] = nx * np.sin(t) + ny * np.cos(t) + 127.5
    w = np.clip((r - np.hypot(dx, dy)) / max(feather, 1e-6) + 0.5, 0, 1)
    if band is not None:
        w = w * (np.abs(dy) <= band)
    if a.ndim == 3:
        w = w[..., None]
    return a * (1 - w) + rot * w


def regrain(a, healed, shift, gsig=2.5, gain=1.0, neutral=0.0):
    """After a heal on a rough surface: where `healed` differs from `a`, add the fine grain (high-pass of the
    luminance) of the same image `shift` = (dx, dy) away, so the healed area is not a smooth patch.
    neutral: 0..1, pull the healed colour toward grey (removes a colour fringe the fill picked up)."""
    diff = np.abs(healed - a)
    w = G.smoothstep(1.0, 5.0, G.blur(diff.max(-1) if a.ndim == 3 else diff, 1.0, False))
    if shift is None:  # no clean area to borrow from: deterministic noise with the strength of the nearby grain
        y = G.lum(a) if a.ndim == 3 else a
        hp0 = y - G.blur(y, gsig, True)
        near = G.dilate(w > 0.05, 14) & ~G.dilate(w > 0.05, 2)
        nz = G.blur(np.random.default_rng(0).standard_normal(y.shape), 0.7, True)
        hp = nz / nz.std() * (hp0[near].std() if near.any() else hp0.std()) * gain
    else:
        src = np.roll(a, (-shift[1], -shift[0]), (0, 1))
        y = G.lum(src) if a.ndim == 3 else src
        hp = (y - G.blur(y, gsig, True)) * gain
    out = healed
    if a.ndim == 3:
        if neutral:
            yy = G.lum(healed)[..., None]
            out = healed + (yy - healed) * neutral * w[..., None]
        return out + (w * hp)[..., None]
    return out + w * hp


# ------------------------------------------------------------------------------------------ recipes
FIX: dict[str, list[tuple[str, object]]] = {}  # vpath -> [(what changed, fn(array, vpath) -> array)]
KEEP: dict[str, str] = {}  # vpath -> reason


def fix(vs, what: str, fn) -> None:
    for v in [vs] if isinstance(vs, str) else vs:
        FIX.setdefault(v, []).append((what, fn))


def keep(vs, reason: str) -> None:
    for v in [vs] if isinstance(vs, str) else vs:
        assert v not in KEEP, v
        KEEP[v] = reason


T = "textures/"

# --- blood / gore: floor and wall tiles with a splatter (earlier pass only recoloured them; the splatter
#     shape with its spray, and the lump on two of them, still read as a blood pool)
_PATCH = "splatter outline, spray droplets{} dissolved: inside the stain the tile is now the clean sibling {} " \
         "plus a faint soft dirt shadow (low-pass of the old stain x{}); rest of the tile unchanged"
for _v, _clean, _k, _extra in (
    ("evil3_floors/cemdrk_oddtile_bldb", "evil3_floors/cemdrk_oddtile", 0.45, " and the pale brain-like lump"),
    ("evil3_floors/woodvfloor3_brain", "evil3_floors/woodvfloor3", 0.45, " and the pale brain-like lump"),
    ("evil3_floors/cemdrk_oddtile_bld", "evil3_floors/cemdrk_oddtile", 0.5, ""),
    ("evil3_floors/wd_tile_drk_bld", "evil3_floors/wd_tile_drk", 0.5, ""),
    ("evil1_floors/br_tiles_blood", "evil1_floors/br_tiles", 0.5, ""),
    ("evil1_floors/carpet_drty_blood", "evil1_floors/carpet_drty", 0.5, ""),
    ("evil1_floors/carpet_drty_blood2", "evil1_floors/carpet_drty", 0.5, ""),
    ("evil3_floors/bdirt_blood", "evil3_floors/bdirt", 0.5, ""),
    ("evil2_basefloor/flr_tmtl_drk_bld", "evil2_basefloor/flr_tmtl_drk", 0.5, ""),
):
    fix(T + _v + ".jpg", _PATCH.format(_extra, _clean.split("/")[1] + ".jpg", _k),
        lambda a, v, c=T + _clean + ".jpg", k=_k: soft_patch(a, c, k))
for _v, _tile, _k in (("flr_b-w_drty_bld", 1, 0.35), ("flr_b-w_drty_bld2", 1, 0.4), ("flr_b-w_drty_bbig", 2, 0.4)):
    fix(T + f"evil2_basefloor/{_v}.jpg",
        "black pool/splatter with spray dissolved and the pinkish cast removed: the checker floor is now the clean "
        f"sibling flr_b-w_drty.jpg{' (2x2)' if _tile > 1 else ''} plus a faint neutral-grey soft shadow (low-pass of "
        f"the old stain's darkness x{_k})",
        lambda a, v, t=_tile, k=_k: soft_patch(a, T + "evil2_basefloor/flr_b-w_drty.jpg", k, 9.0, tile=t, mono=True))
fix(T + "evil1_floors/br_tiles_brkblood.jpg",
    "dark splatter with spray (top right) dissolved: stained pixels replaced by the clean tiles 9 tiles to the left / "
    "1 tile up in the same image (32 px tile grid lines up), a faint soft shadow (x0.35) kept; broken tiles and "
    "the rest unchanged",
    lambda a, v: clone_patch(clone_patch(a, (262, 16, 250, 216), (-288, -32), 0.35, 12.0),
                             (424, 166, 88, 56), (-416, -128), 0.0, 5.0))
fix(T + "evil2_basewall/cementwall_btm_gore.jpg",
    "remaining faint reddish-brown smear band across the lower half neutralised to the wall's grey-green grime "
    "(luminance kept)",
    lambda a, v: C.retint(a, (0.99, 1.0, 0.96), 1.0, 0.012, 0.07))

# --- tags / handles / brands on evil* walls
fix(T + "evil3_walls/mtlwll_twrn2drtyhfx.jpg",
    "yellow stencil tag '[HFX]' on the upper panel erased to the surrounding dark metal; hazard stripes kept",
    lambda a, v: regrain(a, C.heal(a, (18, 34, 226, 46), "dev", 6, 3), None, neutral=0.85))
fix(T + "evil3_walls/mtlwll_twrn2drtyhfx_gloss.jpg",
    "ghost of the '[HFX]' stencil erased in the gloss map (same box as the colour map)",
    lambda a, v: regrain(a, C.heal(a, (18, 34, 226, 46), "dev", 4, 3), None, neutral=0.85))
fix(T + "evil2_misc/barrel_rst_sign.jpg",
    "barrel label: the cotton-seal logo and the line '100% katoen' (real textile-label mark) erased to the rusty "
    "barrel surface; the rounded label frame is kept as a blank label",
    lambda a, v: regrain(a, C.heal(C.heal(a, (88, 88, 60, 62), "all"), (84, 151, 68, 15), "all"), None))
fix(T + "evil1_metals/de-r_mtl_gloss.jpg",
    "near-black gloss map: the faint crossed/hooked scratch strokes (read as a broken hooked cross after a contrast "
    "stretch) blurred into a soft shapeless sheen (Gaussian, sigma 7); colour map untouched",
    lambda a, v: G.blur(a, 7.0, True))
keep([T + "evil1_walls/cementwall_btm_jericho.jpg", T + "evil1_walls/cementwall_btm_jericho_gloss.jpg",
      T + "evil1_walls/cementwall_jericho.jpg", T + "evil1_walls/cementwall_jericho_gloss.jpg"],
     "graffiti/stencil word 'JERICHO' is a place name used as wall decoration, not a person's handle, brand or code")
_KFX = (10, 92, 246, 50)
fix(T + "evil4_metals/tekwallmulti_wrn2hfx.jpg",
    "yellow stencil '[KFX] INDUSTRIES' across the panel erased to the surrounding grey wall (grain matched); "
    "stripes, lights and trim kept",
    lambda a, v: regrain(a, C.heal(a, _KFX, "dev", 6, 3), None, neutral=0.85))
fix(T + "evil4_metals/tekwallmulti_wrn2hfx_norm.jpg",
    "embossed '[KFX] INDUSTRIES' relief replaced by the plain wall relief 50 px below it (same box as the colour map)",
    lambda a, v: clone_patch(a, _KFX, (0, 50)))
fix(T + "evil4_metals/tekwallmulti_wrn2hfx_norm_alpha.jpg",
    "'[KFX] INDUSTRIES' replaced in the height map by the fine relief of the plain wall 50 px below it, large-scale "
    "height extended from around the box (same box as the colour map)",
    lambda a, v: clone_patch(a, _KFX, (0, 50), lowfreq=True))
fix(T + "evil6_trims/e6symbol_b.jpg",
    "raised glyph with four bent arms (reads as a hooked cross) replaced by the sibling plate e6symbol_a.jpg turned "
    "180 degrees: same plate, rivets and metal, a different harmless rune",
    lambda a, v: orig(T + "evil6_trims/e6symbol_a.jpg")[::-1, ::-1])
fix(T + "evil6_walls/e6tdoor.jpg",
    "small stencilled marks on the left door edge (rotated, read like 'S.S' and digits '479') erased to the door "
    "metal; panel detail kept",
    lambda a, v: regrain(a, C.heal(C.heal(a, (19, 98, 15, 31), "dev", 10, 1), (19, 136, 15, 27), "dev", 10, 1), None, gain=0.5))
fix(T + "evil8_fx/e8scuffs1.jpg",
    "reddish-pink smear of the scuff decal recoloured to grey-brown dirt (luminance and shape kept)",
    lambda a, v: C.retint(a, (1.05, 1.0, 0.93), 1.0, 0.03, 0.2))
keep([T + "evil6_support/e6panelsym.jpg", T + "evil6_support/e6vpanel.jpg", T + "evil6_support/e6vpanelsupprt.jpg"],
     "embossed round emblem is an abstract squiggle: no letters, no known logo, no symbol resemblance at full size")
keep([T + "evil8_fx/e8evilspacetxt.jpg", T + "e8/e8evilspacetxt.jpg", T + "e8/e8evilspacetxt_alpha.jpg",
      T + "e8/e8evilspacetxt_bump.jpg"], "map title stencil 'EVILSPACE': harmless signage, no name/brand/code")
# --- screens / doors: brand-like wordmarks, digit strings, small print
fix(T + "evil9/9screen01.jpg",
    "'NEXX CORP' wordmark under the arc erased to the metal frame; the red message lines (SOLARIS NEBULA ... "
    "COUNTDOWN TO TERMINATION ... 10..9..8) and the countdown blurred into unreadable glowing scanlines; WARNING "
    "title, layout and glow kept",
    lambda a, v: C.gblur(C.gblur(regrain(a, C.heal(a, (194, 36, 80, 13), "all"), None, gain=0.7),
                                 (58, 76, 244, 70), 1.7), (58, 166, 78, 18), 1.7))
fix(T + "evil9/9techwall05b.jpg",
    "faint 'NEXX CORP' wordmark (also a real brand) erased to the panel grime; the faint arc shape kept",
    lambda a, v: regrain(a, C.heal(C.heal(C.heal(a, (97, 296, 91, 30), "all"), (196, 296, 119, 30), "all"),
                                   (324, 296, 82, 30), "all"), None, gain=0.6))  # three panels, seams kept


def _door(a, thr):
    a = C.flat(a, (109, 126, 82, 20))  # VECTOR wordmark + its small-print lines (inside the darker label panel)
    a = C.flat(a, (405, 210, 20, 10))  # 4-digit number in the small diagram (read like 1688)
    return C.flat(a, (70, 458, 342, 30))  # bottom strip of tiny labels (TASK, NOM, DBE, -ACAMIN ...)


for _v in ("facility114x/misc/door01", "facility114invx/misc/door01inv"):
    fix(T + _v + ".jpg", "'VECTOR' wordmark with its small print, the tiny 4-digit number in the diagram box (read "
        "like '1688') and the bottom strip of tiny labels erased to the flat panel colour; SHOOT TO OPEN, PLEASE DO "
        "NOT BLOCK OPENING, SUBGATE 4, stripes and icons kept", lambda a, v: _door(a, 12))
    fix(T + _v + "_gloss.jpg", "same three areas erased in the gloss map", lambda a, v: _door(a, 6))


def _corridor(a, v):
    a = C.flat(a, (68, 211, 150, 19))  # rule 'NO SMOKING EXCEPT WHEN INSTRUCTED ...' with its bullet
    return C.flat(a, (156, 280, 29, 12))  # the word LETHAL (and its underline)


for _v in ("facility114x/wall/corridor01", "facility114x/wall/corridor01b", "facility114x/wall/corridor01r",
           "facility114invx/wall/corridor01inv", "facility114invx/wall/corridor01invr"):
    fix(T + _v + ".jpg", "rules panel: the rule 'NO SMOKING EXCEPT WHEN INSTRUCTED TO DO SO AS PART OF AN EXPERIMENTAL "
        "PROCEDURE' (with its bullet) and the word 'LETHAL' in '... IMMEDIATE LETHAL TERMINATION OF EMPLOYMENT "
        "CONTRACT' erased to the flat panel colour; all other text kept", _corridor)
    fix(T + _v + "_gloss.jpg", "the same two areas erased in the gloss map", _corridor)

# --- gore-like leftovers on models
fix(T + "fireball_pants.jpg",
    "colour-mask decal: the dripping streaks under the skull and under the tally marks cut off (set to the mask's "
    "black); clean skull, tally marks and the '15' kept",
    lambda a, v: C.flat(C.flat(a, (700, 1598, 140, 80)), (600, 1538, 105, 100)))


def _grey(a, v, tint=(0.98, 1.0, 1.03), amount=1.0):
    y = G.lum(a)[..., None]
    return a * (1 - amount) + np.clip(y * np.array(tint), 0, 255) * amount


for _n in "1234":
    fix(T + f"gib{_n}.jpg", "gib chunk skin: remaining brown/flesh tint removed, now neutral cool stone-grey "
        "(luminance and structure kept) so the chunks read as rubble", _grey)
fix(T + "ignishead_gloss.jpg", "gloss map of the face: dark-red cast (read as a skinned/bloody face) made neutral "
    "grey; brightness, i.e. the gloss itself, unchanged", lambda a, v: _grey(a, v, (1.0, 1.0, 1.0)))


def smooth_skin(a, box, sigma=10.0):
    """Skin-coloured patch on a black UV sheet: shading inside the patch (dimple, crease) replaced by its own
    low-pass, so only a plain skin-tone area is left; outline and colour kept."""
    x, y, w, h = box
    sub = a[y:y + h, x:x + w]
    m = (sub[..., 0] - sub[..., 2] > 25) & (G.lum(sub) > 70)
    mf = m.astype(np.float64)
    low = G.blur(sub * mf[..., None], sigma, False) / np.maximum(G.blur(mf, sigma, False), 1e-3)[..., None]
    wgt = G.erode(m, 1)[..., None]
    out = a.copy()
    out[y:y + h, x:x + w] = np.where(wgt, low, sub)
    return out


fix(T + "pyria.jpg",
    "player skin sheet: the two small isolated skin hexagons (bottom left) lose their darker centre spot and the "
    "isolated skin patch on the left edge loses its crease (each smoothed to plain skin tone); outlines, colours, "
    "face and armour unchanged",
    lambda a, v: smooth_skin(smooth_skin(smooth_skin(a, (170, 1900, 150, 120)), (650, 1900, 140, 110)),
                             (0, 1380, 140, 240)))

# --- real names / handles / other brands
fix(T + "harlequin_sky/nebula_qer1.jpg", "editor preview tile: line 'by Justin Fisher' (real name) erased to the "
    "flat background; 'Nebula' kept", lambda a, v: C.flat(a, (14, 31, 100, 22)))
fix(T + "harlequin_sky/nebula_qer2.jpg", "editor preview tile: line 'by Justin Fisher' (real name) erased to the "
    "flat background; 'Nebula NO-GLOW' kept", lambda a, v: C.flat(a, (10, 42, 108, 21)))
for _v in ("map_boil/credit.jpg", "map_boil/credit_alpha.jpg"):
    fix(T + _v, "map credit: the handle line 'kuniuthefrogg' blacked out (colour and alpha alike, so nothing is "
        "drawn there); map title 'Boil' kept", lambda a, v: C.flat(a, (0, 250, 512, 80)))
fix(T + "map_courtfun/screen_obey.jpg", "screen 'OBEY' (matches a clothing-brand logo) replaced by the map's own "
    "sibling screen screen_xon.jpg ('XON', same size, font and colours)",
    lambda a, v: orig(T + "map_courtfun/screen_xon.jpg"))

fix(T + "map_catharsis/by_justin.jpg", "author line 'by Justin' (real first name) blacked out; title 'CATHARSIS' kept",
    lambda a, v: C.flat(a, (0, 62, 512, 66)))
fix(T + "map_catharsis/samual_easter.jpg", "the name 'Samual' (contributor handle) blacked out of 'Samual balance'; "
    "'balance' and the grey paint splats kept", lambda a, v: C.flat(a, (20, 158, 480, 128)))
fix(T + "map_erbium/fightingzone.jpg", "small author tag 'SMILECYTHE?' under the message blacked out; 'YOU LEFT THE "
    "FIGHTING ZONE' kept", lambda a, v: C.flat(a, (280, 196, 124, 30)))
fix(T + "skies/distant_sunset.jpg", "sky preview: credit line 'By Cuinn Herrick' (real name) erased to the landscape "
    "behind it; title 'distant sunset' kept", lambda a, v: C.heal(a, (10, 190, 244, 38), "light", 22, 2))
fix(T + "skies/polluted_earth.jpg", "sky preview: credit line 'By Cuinn Herrick' (real name) erased to the sky "
    "gradient behind it; title 'polluted earth' kept", lambda a, v: C.heal(a, (8, 202, 246, 40), "dark", 14, 2))
for _v in ("slimepit_ad", "slime_rev-3"):
    for _s in ("", "_glow"):
        fix(T + f"stralenex1/{_v}{_s}.jpg", "billboard frame showing the author handle 'strahlemann' made a blank "
            "(black) frame; the other frames of the animated billboard are unchanged", lambda a, v: a * 0)
for _s in ("", "_glow"):
    fix(T + f"stralenex1/slimepit_ad-3{_s}.jpg", "billboard frame showing another game's name 'nexuiz' made a blank "
        "(black) frame; the other frames are unchanged", lambda a, v: a * 0)
fix(T + "trak5x/wall/wall_wall6a.jpg", "tiny white text on the orange sticker (author tag 'TRAK ...') filled with the "
    "sticker's orange; sticker kept", lambda a, v: C.heal(a, (455, 340, 34, 25), "light", 22, 1))
fix(T + "trak5x/wall/wall_wall6a_gloss.jpg", "same sticker text smoothed out in the gloss map",
    lambda a, v: C.heal(a, (455, 340, 34, 25), "dev", 8, 1))


def _help_colour(a, v):
    al = load(T + "trak4x/decal/decal_help_alpha.jpg")
    w = G.smoothstep(12, 70, G.blur(al, 1.0, False))[..., None]
    return a * w + 255.0 * (1 - w)


fix(T + "trak4x/decal/decal_help.jpg", "graffiti 'HELP': every drip and speck that the alpha mask does not draw is "
    "painted out to the white background, so the colour image shows the same plain brush lettering as in game "
    "(no long dripping streaks)", _help_colour)
keep(T + "trak4x/decal/decal_help_alpha.jpg", "mask already has the long drips trimmed (earlier pass): plain brush "
     "lettering 'HELP'; the colour image now matches it")
for _v in ("trak4x/decal/decal_pills.jpg", "trak4x/decal/decal_pills_alpha.jpg"):
    fix(T + _v, "pill bottle with the spilled pills (right third) removed to the plain background, colour and alpha "
        "alike; text 'DID YOU TAKE YOUR ... TODAY?' kept", lambda a, v: C.flat(a, (660, 4, 360, 504)))


def glass_blank(a, v):
    """Stained-glass window: the coloured glyph in the centre oval becomes the oval's own white glass."""
    x, y, w, h = 40, 150, 180, 230
    sub = a[y:y + h, x:x + w]
    r, g, b = sub[..., 0], sub[..., 1], sub[..., 2]
    glow = "_glow" in v  # blurred, dull copy of the window
    thr = 6 if glow else 14
    col = (r - np.maximum(g, b) > thr) if "_red" in v else (b - np.maximum(r, g) > thr)
    yy, xx = np.mgrid[0:h, 0:w]
    oval = ((xx - w / 2) / 82.0) ** 2 + ((yy - h / 2) / 104.0) ** 2 < 1
    m = G.dilate(col & oval, 6 if glow else 3) & oval
    white = oval & ~m & (sub.max(-1) - sub.min(-1) < (12 if glow else 40)) & (glow | (G.lum(sub) > 150))
    low = G.fill(sub, white, False, (3, 6, 12, 24, 48))
    yl = G.lum(sub)
    detail = np.clip(yl / np.maximum(G.blur(yl, 2.5, False), 1), 0.35, 1.3)[..., None]
    if glow:
        detail = 1.0
    wgt = np.maximum(G.blur(m.astype(np.float64), 0.8, False), m)[..., None]
    out = a.copy()
    out[y:y + h, x:x + w] = sub * (1 - wgt) + np.clip(low * detail, 0, 255) * wgt
    return out


for _c in ("blue", "red"):
    for _s in ("", "_glow", "_qei"):
        fix(T + f"tznex01/stained_glass_nexlogo_{_c}{_s}.jpg", "Nexuiz logo glyph in the centre oval recoloured to the "
            "oval's own white glass (lead lines kept): a plain white oval window; coloured panes unchanged", glass_blank)

# --- splatter decals (earlier pass only recoloured them to dark brown)
def _splat_keep(al):
    """Soft weight (0..1) of the decal's main body: spray droplets and thin flicks drop out."""
    m = al > 60
    body = G.dilate(G.erode(m, 3), 3) & m  # opening: thin streaks and small drops vanish
    body = G.drop_small(body, 500)
    return np.clip(G.blur(G.dilate(body, 2).astype(np.float64), 3.0, False) * 1.5, 0, 1)


def _splat_colour(a, v):
    w = _splat_keep(load(v.replace(".jpg", "_alpha.jpg")))[..., None]
    y = G.lum(a)[..., None]
    grey = np.clip(y * np.array([0.98, 1.0, 1.02]), 0, 255)  # neutral oil/soot grey instead of dried-blood brown
    return G.blur(grey * w + 255.0 * (1 - w), 1.2, False)


def _splat_alpha(a, v):
    return G.blur(a * _splat_keep(a), 2.0, False)


for _n in "12345":
    fix(T + f"decals/splatter0{_n}.jpg", "splatter decal: the spray droplets and thin flicks around the main stain "
        "removed (white background), the brown tint made neutral soot-grey and the edge softened: reads as a "
        "grime/oil smudge", _splat_colour)
    fix(T + f"decals/splatter0{_n}_alpha.jpg", "alpha mask: the same droplets and flicks removed and the edge "
        "softened (blur 2 px), so the decal is drawn as a soft smudge", _splat_alpha)

# --- screens: random letter/digit noise behind the big word (same noise layer on all nine screens; read at 2x)
keep([T + f"screens/screen_{_v}.jpg" for _v in ("airlock1", "door1", "elevator1", "toggle0")],
     "same noise layer as the other screens, read at 2x: the big word (UNLOCKED / DISABLED) covers the 'FK' line "
     "starts and the 'KK'; what stays visible are long random strings, no word or code stands alone")
for _v in ("airlock0", "door0", "elevator0", "error", "toggle1"):
    fix(T + f"screens/screen_{_v}.jpg",
        "background letter noise: the two bold line starts 'FK' ('FK34FKJ...', 'FK34F34...') and the 'KK' in "
        "'34KKHKLH' erased to the screen background (three small boxes); the rest of the noise was read at full "
        "size: only long random strings, no word or code stands alone",
        lambda a, v: C.heal(C.heal(a, (31, 215, 17, 30), "dark", 9, 1, pad=16, noref=[(0, 180, 31, 100)]),
                            (45, 265, 18, 15), "dark", 9, 1, pad=16))

fix(T + "final_rage/lamp2.jpg", "emblem: the centre glyph (the Nexuiz logo, reads like the kanji for 'power') erased "
    "to the concrete; the emblem outline and the rest kept",
    lambda a, v: regrain(a, C.heal(a, (84, 54, 72, 84), "dark", 8, 2), None, gain=0.7))
fix(T + "final_rage/lamp2_glow.jpg", "same centre glyph erased in the glow map",
    lambda a, v: C.heal(a, (84, 54, 72, 84), "dev", 5, 2))

# --- deliberately kept (harmless; reasons go to content_kept3.tsv)
_NAME = "pixels are harmless; only the file name has the word, and uploads use neutral names ('Xonotic texture <sha12>', G-047)"
keep([T + "evil1_floors/br_tiles_blood_bump.jpg", T + "evil1_floors/br_tiles_brkblood_bump.jpg",
      T + "evil1_floors/carpet_drty_blood2_bump.jpg", T + "evil2_basewall/cementwall_btm_gore_bump.jpg",
      T + "evil3_floors/cemdrk_oddtile_bld_bump.jpg", T + "evil3_floors/cemdrk_oddtile_bld_gloss.jpg",
      T + "evil3_floors/cemdrk_oddtile_bldb_gloss.jpg", T + "eyeblood.jpg", T + "flesh1.jpg", T + "uzi.jpg",
      T + "uzi_gloss.jpg"], _NAME)
keep([T + "evil1_walls/crude_1.jpg", T + "evil1_walls/crude_2.jpg"],
     "rust drips were already shifted to rust-orange/brown in the earlier pass (content_fix.py); they read as rust")
keep([T + "evil2_misc/barrel_rst_sign2.jpg", T + "evil2_misc/barrel_rst_sign3.jpg"],
     "'Cl' in a triangle = chlorine hazard label: harmless signage")
keep(T + "evil1_misc/ta_wrnsign.jpg", "'TOXIC AREA / RESTRICTED ACCESS': harmless hazard sign")
keep([T + "erebus.jpg", T + "erebusfullbright.jpg"], "small chest text 'EREBUS' = the player model's own name")
keep(T + "eye.jpg", "plain stylised eyeball; veins were already made pale grey (gore_fix.py), no blood")
keep([T + f"facility114{d}/ceiling/ceiling00{s}.jpg" for d, s in (("invx", "inv"), ("invx", "invr"), ("x", ""), ("x", "b"), ("x", "r"))],
     "tiny HUD strip words 'SPACE-TIME SYNTHESIS', 'NO USE', 'D12': harmless sci-fi labels")
keep([T + f"facility114{d}/ceiling/ceiling01{s}.jpg" for d, s in (("invx", "inv"), ("invx", "invr"), ("x", ""), ("x", "b"), ("x", "r"))],
     "Chinese sentence meaning 'This roof is not safe.': harmless warning sign")
keep([T + "facility114invx/wall/corridor02inv.jpg", T + "facility114invx/wall/corridor02invr.jpg",
      T + "facility114x/wall/corridor02.jpg"],
     "joke notice 'THE MANAGEMENT IS NOT RESPONSIBLE FOR ANY ACCIDENTS ...' / 'DO NOT PRESS': harmless signage (the "
     "decapitation sentence was removed in the earlier pass)")
keep(T + "final_rage/nd-lava.jpg", "editor marker text 'LAVA NODRAW': harmless")
keep([T + "flamethrower.jpg", T + "flamethrower_gloss.jpg", T + "items/a_bullets.jpg"],
     "'AT CORP' / 'MACHINEGUN AMMO' stencils: fictional in-game maker and item label, not a real brand")
keep([T + "glsight01_glow.jpg", T + "glsight02_glow.jpg", T + "glsight03_glow.jpg"],
     "scope HUD text 'TYPE: IMPACT / RANGE: 2000M ...': harmless game UI")
keep([T + "ignishead.jpg", T + "ignisheadfb.jpg"],
     "fictional character's face sheet; the red marks were already made charcoal (gore_fix.py); 'IGNIS' = model name")
keep(T + "items/explosiveammo.jpg", "stencil 'EXPLOSIVES' on an ammo crate: harmless item label")
keep([T + f"logos/logo02/logo02_{s}.jpg" for s in (
    "black", "black_alpha", "blue", "blueg", "blueg_glow", "cyan", "cyang", "cyang_glow", "green", "greeng",
    "greeng_glow", "purple", "purpleg", "purpleg_glow", "red", "redg", "redg_glow", "white", "yellow",
    "yellowg_glow")] + [T + "map_implosion/xonoticdecal.jpg", T + "map_implosion/xonoticdecal_glow.jpg",
                        T + "map_implosion/terminal_blue2.jpg"],
     "XONOTIC wordmark / 'Hello XONOTIC!' (the game's own name), no URL: kept as the owner said")
keep(T + "morphed/flagred.jpg", "team-red banner with an abstract symmetric black emblem: no cross, hooked shape, "
     "disc or text; the same banner exists in the other team colours")
keep(T + "ons_text.jpg", "Onslaught HUD strings with 'CONTROL POINT' fully spelled (no 'CP'), plus two harmless "
     "pop-culture quotes")
keep([T + "phillipk2x/decals/pk02_dec_num08.jpg", T + "phillipk2x/decals/pk02_dec_num08_alpha.jpg"],
     "a single digit '8' floor-number decal: one digit is not a code")
keep(T + "seraphina.jpg", "fictional character's face sheet with shoulder digits '4' and '2': harmless")
keep([T + "savdm6ish/light3_7.jpg", T + "savdm6ish/light3_7_luma.jpg"],
     "plain Latin cross light panel (church/graveyard style): an ordinary religious symbol, not a hate symbol")
keep(T + "sniperrifle.jpg", "fictional model codes 'GE-ZOx IR' / 'GE-HD40': no real brand")
keep([T + f"stralenex1/{n}.jpg" for n in (
    "slime_rev-1", "slime_rev-1_glow", "slime_rev-2", "slime_rev-2_glow", "slime_rev", "slime_rev_glow",
    "slimepit_ad-1", "slimepit_ad-10", "slimepit_ad-11", "slimepit_ad-2", "slimepit_ad-4", "slimepit_ad-5",
    "slimepit_ad-6", "slimepit_ad-7", "slimepit_ad-8", "slimepit_ad-9")],
     "billboard frames with ordinary words ('presents', 'a', '2.3', 'map', 'even', 'more', 'slime', 'on', "
     "'slimepit', 'revisited', 'by'); the frames with the handle and the other game's name are blanked")
keep([T + "terrain01x/blends/mars-rock01-ground01.jpg", T + "terrain01x/blends/mars-rock01-sand04.jpg",
      T + "terrain01x/blends/mars-rock02-ground01.jpg"] +
     [T + f"terrain_dotproduct2/{n}.jpg" for n in ("grass01-rock05", "leafs01-rock02", "mossrock02-mudground04",
                                                   "mudground01_rock01", "mudground02-rock06", "sand-rock07", "snow-rock05")],
     "editor preview labels ('Mars Rock01 Ground01', 'Horizontal' / 'Vertical'): harmless")
keep(T + "train02.jpg", "tiny faint illegible mark on the panel: nothing readable")
keep([T + f"trak4x/decal/decal_{n}.jpg" for n in (
    "door", "exit", "exit_alpha", "iso1", "iso1_alpha", "iso2", "iso2_alpha", "iso3", "iso3_alpha", "northwing",
    "northwing_alpha", "southwing", "southwing_alpha", "wallpainting", "wallpainting_alpha")],
     "harmless signage (PLEASE KEEP DOOR CLOSED, EXIT, ISOLATION 1-3, NORTH/SOUTH WING, 'ANGER IS NEVER THE ANSWER' "
     "cartoon)")
keep(T + "trak5x/panel/panel_comp1a_glow.jpg", "tiny filler text ('Zone 17 ... Sector B ... This text is just "
     "filler'): harmless and barely legible")
keep([T + "tymo3t5/wf1.jpg", T + "tymo3t5/wf2.jpg"], "in-game screenshot with the map name and HUD numbers: harmless")
keep(T + "wyvern.jpg", "monster skin sheet (mouth lining, nostril): creature art, nothing body-like out of context")

# --- symbols: point-down stars, cross in a ring
for _v in ("e7/e7wgrate.jpg", "e7/e7wgrate_alpha.jpg"):
    fix(T + _v, "point-down five-pointed star inside the ring (inverted-pentagram look) turned 180 degrees so it "
        "points up: exact pixel swap inside the ring between the two plates; ring, bars and plates untouched; "
        "colour and alpha get the identical swap",
        lambda a, v: rot_disc(a, 255.5, 124.5, 61.5, 180, 0.01, band=45))
for _v in ("e7/e7walldesign01.jpg", "e7/e7walldesign01_bump.jpg"):
    fix(T + _v, "point-down star under the horned ornament turned 180 degrees (points up); colour and bump identical",
        lambda a, v: rot_disc(a, 127.5, 190.5, 73, 180, 1.5))
fix(T + "e7/e7bigwall.jpg", "large point-down star in the gothic window turned 180 degrees (points up)",
    lambda a, v: rot_disc(a, 127.5, 373.5, 95, 180, 3.0))
for _c in "brwy":
    for _n in "12":
        _b = T + f"egyptsoc_sfx/lig_064-04{_c}{_n}"
        _w = "lamp lens: the equal-armed cross inside the ring (sun-cross look) turned 45 degrees inside the ring, " \
             "so it is a diagonal X grille; ring and stone frame untouched"
        fix(_b + ".jpg", _w, lambda a, v: rot_disc(a, 31.5, 31.5, 21.5, 45))
        fix(_b + "_norm.jpg", _w + " (normal map: same turn, normal vectors turned with it)",
            lambda a, v: rot_disc(a, 31.5, 31.5, 21.5, 45, normal=True))
        fix(_b + "_norm_alpha.jpg", _w + " (height map: same turn)", lambda a, v: rot_disc(a, 31.5, 31.5, 21.5, 45))
        if _n == "1":
            fix(_b + "_glow.jpg", _w + " (glow map: same turn)", lambda a, v: rot_disc(a, 31.5, 31.5, 21.5, 45))
keep([T + f"egyptsoc_trim/128-05{c}{s}.jpg" for c in "efgh" for s in ("", "_norm", "_norm_alpha")],
     "colourful Egyptian vulture (Nekhbet) relief holding rings: clearly ancient-Egyptian art, not a heraldic eagle "
     "emblem; no text or symbol")
keep([T + f"evil8_fx/e8_jumppad02{s}.jpg" for s in ("", "_gloss", "_norm", "_norm_alpha", "r", "w")],
     "faint jump-pad stencil ('JMP-3'-like): harmless signage, no flagged letter/digit combination")


# ------------------------------------------------------------------------------------------- main
def main() -> None:
    only = sys.argv[1:]
    fnd = findings()
    both = set(FIX) & set(KEEP)
    assert not both, f"fixed and kept: {sorted(both)}"
    missing = sorted(set(fnd) - set(FIX) - set(KEEP))
    if missing and not only:
        sys.exit("findings neither fixed nor kept:\n  " + "\n  ".join(missing))
    for v, ops in FIX.items():
        if only and not any(o in v for o in only):
            continue
        a = load(v)
        shape = a.shape
        for _, fn in ops:
            a = fn(a, v)
        assert a.shape == shape, v
        save(v, a)
        print("fixed", v)
    if only:
        return

    def key(v):
        n = fnd.get(v, ("", "", ""))[0]
        return (0, int(n)) if n else (1, 0), v

    with open(LOG_FIXED, "w", encoding="utf-8", newline="\n") as f:
        f.write("# n (strict review; - = added here)\tvpath\tseverity\tissue\twhat changed (content_fix3.py -> work/upload/fixed3/)\n")
        for v in sorted(FIX, key=key):
            n, sev, issue = fnd.get(v, ("-", "-", "same change as its base texture"))
            f.write(f"{n}\t{v}\t{sev}\t{issue}\t{'; '.join(w for w, _ in FIX[v])}\n")
    with open(LOG_KEPT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# n\tvpath\tseverity\tissue\tkept unchanged because\n")
        for v in sorted(KEEP, key=key):
            n, sev, issue = fnd.get(v, ("-", "-", "-"))
            f.write(f"{n}\t{v}\t{sev}\t{issue}\t{KEEP[v]}\n")
    print(f"{len(FIX)} fixed, {len(KEEP)} kept ({len(fnd)} findings)")


if __name__ == "__main__":
    main()
