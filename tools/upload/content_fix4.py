#!/usr/bin/env python3
"""UPLOAD-FIX4: Roblox-safe versions of the flagged images that were uploaded BEFORE the 2026-11-22 ban and are
still the versions the game uses (assets/manifest/review/live_findings_{a..c}.tsv, G-051), changed as subtly as
possible (D-025). Also the one needed image Roblox rejected (account check 2026-11-25).

  python3 tools/upload/content_fix4.py [substring ...]   -> work/upload/fixed4/<vpath>   (nothing is uploaded)

Same method and rule as content_fix3.py (its helpers are reused): every recipe starts from the file that is live
today (fixed3 > fixed > fixed2 > blurred > original), output has the same size and mode (one exception, see
background_ingame_alpha), JPEG quality 95, 4:4:4, deterministic. Boxes are (x, y, w, h) in full-resolution pixels.

Every live finding is fixed (assets/manifest/review/content_fixes4.tsv), kept with a reason (content_kept4.tsv),
or was already replaced by an earlier tool (REPLACED); main() refuses to run otherwise.
Rule (owner, 2026-11-24/25): fix every high and medium item, and low items with real names/handles, brands,
other games' names, anything blood/gore-like, crosses/stars/hooked-cross shapes, body-like shapes, letters or
digits that could read as a flagged code. Harmless signage and the XONOTIC wordmark/emblem (no URL) stay - that
includes the medium "brand logo" findings, which are kept on that rule and listed for the owner.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import content_fix as C  # noqa: E402
import content_fix3 as F3  # noqa: E402  (soft_patch, clone_patch, rot_disc, regrain)
import gore_fix as G  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ORIG = ROOT / "work/vfs-high"
CHAIN = [ROOT / "work/upload/fixed3", ROOT / "work/upload/fixed", ROOT / "work/upload/fixed2",
         ROOT / "work/upload/blurred", ORIG]
DST = ROOT / "work/upload/fixed4"
REVIEW = ROOT / "assets/manifest/review"
LOG_FIXED = REVIEW / "content_fixes4.tsv"
LOG_KEPT = REVIEW / "content_kept4.tsv"
REJECTED = "gfx/menu/luminos/background_ingame_alpha.jpg"


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
    return _arr(src_path(v))


def save(v: str, a: np.ndarray) -> None:
    out = DST / v
    out.parent.mkdir(parents=True, exist_ok=True)
    a = np.clip(np.rint(a), 0, 255).astype(np.uint8)
    Image.fromarray(a, "L" if a.ndim == 2 else "RGB").save(out, quality=95, subsampling=0)


def findings() -> dict[str, tuple[str, str, str]]:
    """vpath -> (n, severity, issue) of the live-asset review."""
    out = {}
    for f in sorted(REVIEW.glob("live_findings_*.tsv")):
        for ln in f.read_text(encoding="utf-8").splitlines():
            if ln.strip() and not ln.startswith("#"):
                c = ln.split("\t")
                out[c[1]] = (c[0], c[4], c[3])
    return out


# ---------------------------------------------------------------------------------------------- ops
def const_box(a, *boxes):
    """Decal sheet with a flat background: boxes set to the background value (the image's corner)."""
    out = a.copy()
    bg = np.median(a[:3, :3].reshape(-1, *a.shape[2:]), axis=0)
    for x, y, w, h in boxes:
        out[y:y + h, x:x + w] = bg
    return out


def heal_lines(a, boxes, mode, thr, grow=1, grain=True):
    """Erase several text boxes to the surrounding surface, then give the healed strokes the paper's grain."""
    h = a
    for b in boxes:
        h = C.heal(h, b, mode, thr, grow)
    return F3.regrain(a, h, None) if grain else h


def mirror_glyph(a, glow, normal=False, grow=14, feather=3.0):
    """Two-letter sign on a left-right symmetric panel: the right letter is replaced by the mirror image of the
    left letter (and of the panel behind it), so the pair is one symmetric bracket emblem and no longer two
    letters. glow: the sign's glow map (bright = letters), used as the mask for every map of the set.
    normal=True: tangent-space normal map, the x component is flipped with the picture."""
    H, W = a.shape[:2]
    lit = G.lum(glow) > 60
    lit[:120] = lit[-120:] = False  # corner triangles are not letters
    lit[:, :120] = lit[:, -120:] = False
    m = lit | lit[:, ::-1]
    m = G.dilate(m, grow)
    w = np.clip(G.blur(m.astype(np.float64), feather, False) * 1.5, 0, 1)
    w[:, :W // 2] = 0  # the left half is the source and stays as it is
    mir = a[:, ::-1].copy()
    if normal:
        mir[..., 0] = 255.0 - mir[..., 0]
    if a.ndim == 3:
        w = w[..., None]
    return a * (1 - w) + mir * w


def quad_fill(a, box):
    """2x2 checker of flat greys with a label across the middle: the label box becomes the flat quadrant greys."""
    x, y, w, h = box
    out = a.copy()
    H, W = a.shape[:2]
    m = np.zeros((H, W), bool)
    m[y:y + h, x:x + w] = True
    for ys in (slice(0, H // 2), slice(H // 2, H)):
        for xs in (slice(0, W // 2), slice(W // 2, W)):
            q, mq, sub = a[ys, xs], m[ys, xs], out[ys, xs]
            sub[mq] = np.median(q[~mq].reshape(-1, *a.shape[2:]), axis=0)
    return out


def smooth_shape(a, sigma, thr=14.0):
    """Blur only inside the lit shape (normalised, so the black background does not bleed in)."""
    m = (G.lum(a) > thr).astype(np.float64)
    num = G.blur(a * m[..., None], sigma, False)
    den = G.blur(m, sigma, False)[..., None]
    sm = num / np.maximum(den, 1e-3)
    w = m[..., None]
    return a * (1 - w) + sm * w


def hatch_yards(a, seeds, base=44.0, line=82.0, period=9):
    """Radar image: the enclosed empty yards (flood fill from `seeds`, bounded by the wall outlines) are drawn
    as hatched solid blocks, the floor-plan sign for 'not walkable'. No outline or corridor pixel changes."""
    out = a.copy()
    lab = G.labels(a < 24)
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    for sx, sy in seeds:
        reg = lab == lab[sy, sx]
        assert lab[sy, sx] > 0 and 3000 < reg.sum() < 12000, (sx, sy, int(reg.sum()))
        reg = G.erode(reg, 3)
        out[reg] = np.where((xx + yy) % period < 2, line, base)[reg]
    return out


def drop_lines(a, box, keep_to, move_from, move_to, thr=12.0):
    """Text block on a smooth plate: the ink (image minus healed plate) of rows >= move_from is moved up to
    move_to; rows keep_to..move_from are dropped. Lines above keep_to stay where they are."""
    bg = C.heal(a, box, "dark", thr, 1)
    ink = a - bg
    out = bg.copy()
    out[:keep_to] += ink[:keep_to]
    n = a.shape[0] - move_from
    out[move_to:move_to + n] += ink[move_from:]
    return out


# ------------------------------------------------------------------------------------------ recipes
FIX: dict[str, list[tuple[str, object]]] = {}
KEEP: dict[str, str] = {}
REPLACED = {  # live findings whose flagged asset is no longer used: an earlier tool's version is live instead
    "gfx/hud/default/notify_headshot.jpg", "gfx/menu/luminos/skinpreview.jpg", "gfx/menu/wickedx/background_ingame.jpg",
    "models/containers/crate01.jpg", "models/trak/tablet_xon3.jpg", "models/trak/pbox.jpg", "models/trak/pen.jpg",
}


def fix(vs, what: str, fn) -> None:
    for v in [vs] if isinstance(vs, str) else vs:
        FIX.setdefault(v, []).append((what, fn))


def keep(vs, reason: str) -> None:
    for v in [vs] if isinstance(vs, str) else vs:
        assert v not in KEEP, v
        KEEP[v] = reason


T, DF, HUD = "textures/", "models/desertfactory/textures/", "gfx/hud/"

# --- HIGH: the 'CP' control-point sign (the text that caused the ban, G-051)
_CP = "sign letters 'CP': the 'P' replaced by the mirror image of the 'C' (and of the symmetric circuit panel " \
      "behind it), so the sign is one symmetric bracket/ring emblem and no longer reads as letters; frame, " \
      "corner triangles and the left half unchanged; same mask on all five maps"
for _s in ("", "_gloss", "_glow", "_norm_alpha"):
    fix(T + f"cp{_s}.jpg", _CP, lambda a, v: mirror_glyph(a, load(T + "cp_glow.jpg")))
fix(T + "cp_norm.jpg", _CP + "; normal vectors mirrored with the picture",
    lambda a, v: mirror_glyph(a, load(T + "cp_glow.jpg"), normal=True))

# --- HIGH: damage overlay sprite (splat with droplets)
fix("gfx/blood.jpg", "splat body and all droplets dissolved into a soft cloud (Gaussian blur, sigma 14 px); the "
    "sprite keeps its place, size and overall light/dark", lambda a, v: G.blur(a, 14.0, False))
fix("gfx/blood_alpha.jpg", "alpha mask: droplet shapes dissolved, a soft vignette stays (Gaussian blur, sigma 14 px, "
    "same as the colour map)", lambda a, v: G.blur(a, 14.0, False))

# --- HIGH: radar image whose corridor layout reads as a bent-arm cross
fix("gfx/leave_em_behind_mini.jpg",
    "the two enclosed empty yards (upper left, lower right) drawn as hatched solid blocks, so the picture reads as "
    "two blocks joined at a corner and no longer as four bent arms; every corridor and wall outline is unchanged "
    "(the radar still matches the map exactly)",
    lambda a, v: hatch_yards(a, ((181, 181), (331, 331))))

# --- desertfactory paper notes and graffiti: usernames, software brands, another game's name
fix(DF + "documents/note01.jpg", "the signature name 'sev' under 'So long' erased to the paper; title, greeting, "
    "the ring emblem (owner said keep) and the pen scribble kept",
    lambda a, v: heal_lines(a, [(48, 128, 62, 28)], "dark", 14))
fix(DF + "documents/note02.jpg", "the line 'The programs I used:' and the seven program names (NetRadiant, Blender, "
    "GIMP, Q3Map2, xsane, Nexuiz, p7zip) erased to the paper; 'Credits' and the thank-you sentence kept",
    lambda a, v: heal_lines(a, [(58, 87, 142, 18), (8, 111, 154, 29), (8, 146, 110, 29), (168, 146, 80, 29),
                                (8, 179, 110, 31), (168, 181, 80, 28), (8, 213, 96, 28), (168, 214, 80, 31)], "dark", 14))
fix(DF + "documents/note03.jpg", "everything below the thank-you sentence erased to the paper (the username "
    "'Tenshihan', 'The Blender Texture Disc', 'Textures provided with Nexuiz' and their lead-in lines); 'Credits' "
    "and the thank-you sentence kept",
    lambda a, v: heal_lines(a, [(50, 85, 158, 16), (66, 100, 126, 26), (4, 123, 250, 14), (42, 150, 174, 17),
                                (62, 166, 130, 18), (4, 189, 212, 20), (4, 210, 250, 22)], "dark", 14))
fix([DF + "documents/writing01_alpha.jpg", DF + "shaders/writing01.jpg"],
    "graffiti 'sev was here': the username 'sev' removed (set to the sheet's background); 'was here' kept",
    lambda a, v: const_box(a, (0, 8, 86, 66), (86, 8, 8, 36)))
fix([DF + "documents/writing02_alpha.jpg", DF + "shaders/writing02.jpg"],
    "graffiti 'Nexuiz Rulez': the other game's name 'Nexuiz' removed (set to the sheet's background); 'Rulez' kept",
    lambda a, v: const_box(a, (0, 0, 256, 64)))
fix([DF + "documents/writing05_alpha.jpg", DF + "shaders/writing05.jpg"],
    "graffiti 'MEXL WAR HIER' (German: Mexl was here): the nickname 'MEXL' removed (set to the sheet's "
    "background); 'WAR HIER' kept",
    lambda a, v: const_box(a, (0, 0, 384, 122)))
fix(DF + "documents/newspaper01.jpg", "the tiny credit 'by sev' at the end of the line under the masthead erased to "
    "the paper; headline and picture kept (owner said keep)",
    lambda a, v: heal_lines(a, [(174, 28, 26, 7)], "dark", 8, grain=False))

# --- race checkpoint ring: rune-style text naming a contributor, S drawn as a lightning rune
_RING = "the two columns of rune-style letters ('MORPHED IS THE BEST ...', S drawn like a lightning rune) on the " \
        "left stone strip replaced by the plain stone 289 px to the right in the same texture (fine grain cloned, " \
        "shading kept); ribs and the cyan glyph panels unchanged"
for _s in ("", "_bump", "_gloss"):
    fix(f"models/race/checkpoint/outerring{_s}.jpg", _RING,
        lambda a, v: F3.clone_patch(a, (16, 6, 62, 500), (289, 0), lowfreq=True))

# --- trak tablets
fix("models/trak/tablet.jpg", "last words of the report 'More technical BS plz.' erased to the plate",
    lambda a, v: C.heal(a, (160, 159, 62, 9), "all"))
fix("models/trak/tablet_xon0.jpg", "the two lines 'IT IS THE DIRECT / SUCCESSOR OF NEXUIZ.' (another game's name) "
    "removed and the lines below moved up two rows; logo and the rest of the text kept",
    lambda a, v: drop_lines(a, (140, 77, 88, 105), 120, 140, 120))
fix("models/trak/tablet_xon2.jpg", "the last sentence 'XONOTIC IS A DIRECT SUCCESSOR OF THE NEXUIZ PROJECT.' "
    "(three lines, another game's name) erased to the plate; logo and the rest kept",
    lambda a, v: C.heal(a, (140, 138, 88, 34), "all"))

# --- vehicle rocket skin
fix("models/vehicles/rockets.jpg", "the dark blood-red paint (nose cone, disc, stripe, vent) turned to a lighter "
    "red-orange (hue +14 degrees, value x1.12) so the UV sheet reads as paint; the words 'FALCON PUNCH' (a game "
    "meme) erased from the label, 'MISSILE MK.V' kept; the signature 'Fricka' erased to the camouflage",
    lambda a, v: C.heal(C.heal(C.hue(a, 0.04, 1.0, 1.12, 0.35, 0.6), (553, 431, 56, 12), "light", 6, 1,
                               noref=[(500, 400, 52, 80)]),
                        (429, 687, 26, 64), "dev", 12, 2))

# --- cockpit gauges (photo based; earlier pass removed the maker logos)
fix(T + "cockpit.jpg", "photographer credit '(c) Mehdad Arshad Rad' under the rev counter erased to black; the LCD "
    "letters 'dPIC' (a product name that also reads badly) erased to the dark display; gauges kept",
    lambda a, v: C.heal(C.heal(a, (512, 241, 56, 10), "light", 6, 2), (58, 112, 134, 40), "light", 10, 2))
fix(T + "cockpit_glow.jpg", "photographer credit '(c) Mehdad Arshad Rad' erased to black (same box as cockpit.jpg)",
    lambda a, v: C.heal(a, (512, 241, 56, 10), "light", 6, 2))

# --- MEDIUM: yellow domination icon = ring with an upright cross through it (Celtic/sun-cross look)
_DOM = "whole icon turned 45 degrees about its centre: the upright cross through the ring becomes a diagonal X " \
       "(reticle look); same turn on colour and alpha"
for _d, _c in (("luminos/dom_icon_yellow", (127.5, 127.0)), ("luminos/dom_icon_yellow-highlighted", (127.5, 127.0)),
               ("old/dom_icon_yellow", (124.0, 124.0)), ("old/dom_icon_yellow-highlighted", (122.0, 122.5))):
    fix([HUD + _d + ".jpg", HUD + _d + "_alpha.jpg"], _DOM,
        lambda a, v, c=_c: F3.rot_disc(a, c[0], c[1], 400.0, 45.0))

# --- LOW items that fall under the rule
fix(HUD + "old/armor.jpg", "green torso icon: the muscle relief (chest line, abdominal blocks, shoulder knobs) "
    "smoothed away inside the shape (blur sigma 4 px), so it is a plain green vest silhouette and not a bare body",
    lambda a, v: smooth_shape(a, 4.0))
for _n in ("014", "069", "088"):
    fix(T + f"alphamod/alpha_{_n}.jpg", f"the big label '{int(_n)}%' erased (label box set to the flat greys of the "
        "four quadrants); the texture's grey levels, which are its whole function, are unchanged",
        lambda a, v: quad_fill(a, (30, 46, 70, 34)))
fix(T + "bloodyskull.jpg", "replaced by its clean sibling textures/cleanskull.jpg (same size and UV layout, the "
    "skull without the stains)", lambda a, v: _arr(src_path(T + "cleanskull.jpg")))
fix(T + "cake/pipe1d_msg.jpg", "the mapper's nickname 'FRUITIEX' on the last line erased to the green board; the "
    "message and 'ENJOY!' kept", lambda a, v: heal_lines(a, [(0, 235, 92, 21)], "all", 0, grain=False))
fix(T + "cmp1-dm8/e8circle_pur.jpg",
    "the upright cross inside the ring (sun-cross look) turned 45 degrees inside the ring, so it is a diagonal X; "
    "ring and outside unchanged (same as the lamp lenses in UPLOAD-FIX3); its _alpha map is only the ring, unchanged",
    lambda a, v: F3.rot_disc(a, 63.5, 63.5, 56.5, 45.0, 1.0))

# --- the needed image Roblox rejected (1x1 grey; identical re-uploads of a rejected file are refused at once)
fix(REJECTED, "1x1 pixel of grey 239 stored as 4x4 pixels of the same grey: a new file with the same picture when "
    "stretched (the only size change in this tool)", lambda a, v: np.full((4, 4), float(a.flat[0])))

# ----------------------------------------------------------------------------------------------- kept
_XON = "the game's own XONOTIC wordmark/eagle emblem, no URL or address: kept on the owner's rule (brief of 2026-11-24)"
keep(["gfx/conback3.jpg", "gfx/conback3_alpha.jpg", "gfx/loading.jpg", "gfx/winner.jpg",
      "gfx/menu/luma/background_ingame_l2.jpg", "gfx/menu/luma/background_ingame_l2_alpha.jpg",
      "gfx/menu/luminos/background_ingame_l2.jpg", "gfx/menu/luminos/background_ingame_l2_alpha.jpg",
      "gfx/menu/wickedx/skinpreview.jpg", "models/trak/ccup_xon.jpg"]
     + [HUD + f"default/minigames/{m}.jpg" for m in (
         "c4/board", "c4/board_alpha", "c4/board_over", "c4/board_under", "c4/board_under_alpha", "nmm/board",
         "nmm/board_alpha", "pong/board", "pong/board_alpha", "ttt/board", "ttt/board_alpha")], _XON)
keep(["maps/finalrage.jpg", "maps/leave_em_behind.jpg", "maps/trident.jpg"],
     "map preview screenshot; the only finding is the game's own XONOTIC emblem on a wall/floor: " + _XON)
keep("models/trak/tablet_xon1.jpg", "XONOTIC emblem and a harmless sentence about the project's community; no other "
     "game, name or address: " + _XON)
keep("models/trak/tablet_xon4.jpg", "XONOTIC emblem, a Latin motto and 'good luck and have fun': harmless text")
keep("models/trak/tablet_xon5.jpg", "XONOTIC emblem and a famous quotation signed '- NOT VOLTAIRE': a joke about a "
     "historical author (died 1778), not a user, handle or living person")
keep(["darkplaces-icon.jpg", "darkplaces-icon2.jpg"], "the engine's own icon (bird in a ring), no text; this game "
     "runs on that engine")
keep(["env/newsky_asteroids/asteroids.jpg", "env/newsky_nebulae/nebulae.jpg", "env/newsky_planets/planets.jpg"],
     "64x64 sky preview with a plain descriptive label ('NewSky Asteroids/Nebulae/Planets'): harmless signage")
keep(["gfx/conback.jpg", "gfx/conback_alpha.jpg"], "console background: blurred, illegible lines of program code")
keep("gfx/crosshair19.jpg", "crosshair made of four plain triangles (bow-tie); straight edges, no hooked arms")
keep(["gfx/crosshairt.jpg", "gfx/crosshairt_alpha.jpg"], "T-shaped crosshair (an italic 't'); a single letter, not a logo")
keep([HUD + "default/ammo_bullets.jpg", HUD + "default/ammo_rockets.jpg"], "ammo icons; the stencilled text on them "
     "is too small to read")
keep([HUD + "default/health.jpg", HUD + "old/health.jpg", HUD + "default/minigames/bd/brick6.jpg"],
     "health cross, the usual video-game health sign (dark/red 3D cross on black, a red tile); not red on white")
keep(HUD + "default/minigames/pp/piece_taken.jpg", "white paint-splat game piece on black; nothing red in the image")
keep([HUD + "default/notify_camping.jpg", HUD + "default/notify_melee_shotgun.jpg"], "harmless photo icons (a tent; "
     "a trout), no people, text or brand")
keep([HUD + "default/shield.jpg", HUD + "default/strength.jpg"], "single kanji used as power-up icons (longevity; "
     "power): ordinary words")
keep(HUD + "luma/superweapons.jpg", "warning-triangle icon with a mushroom cloud: a hazard sign, no gore")
keep([HUD + "old/armor_big.jpg", HUD + "old/armor_mega.jpg", HUD + "old/item_large_armor.jpg"],
     "plated armour suits with glowing lights and a helmet: clearly armour, not a body")
keep(["gfx/menu/luma/gametype_" + g + ".jpg" for g in (
    "ca", "ca_alpha", "lms", "lms_alpha", "mayhem", "mayhem_alpha", "tmayhem", "tmayhem_alpha")],
     "game-mode icons with a clenched fist (fight/last-man-standing): a common game icon, no slogan or emblem")
keep("gfx/menu/xaw/skinpreview.jpg", "menu-skin preview screenshot; its small text is blurred and unreadable")
keep("models/containers/crate01_lod.jpg", "crate label 'CARGO EXPRESS': made-up harmless signage")
keep(DF + "documents/document01.jpg", "hand-drawn graph with tiny handwriting: no name, brand or code")
keep(DF + "documents/writing04_alpha.jpg", "graffiti 'All generalisations are wrong!': a harmless sentence")
keep("models/it/lcd.jpg", "monitor bezel with a tiny made-up label 'ALIEN TX'")
keep("models/sprites/minigame_busy.jpg", "generic gamepad drawing with A/B/X/Y buttons; no maker's logo")
keep(["models/weapons/g_crylink_luma.jpg", "models/weapons/g_crylink_luma_alpha.jpg"],
     "weapon icon: three rounded commas in a ring (the Japanese tomoe motif); round blobs, no straight hooked arms")
keep("particles/particlefont-template.jpg", "particle-sheet template: every cell carries its running index number "
     "in tiny digits; no number stands alone")
keep("particles/particlefont.jpg", "particle sheet: small white smoke/spark/splat sprites; nothing red, no text "
     "beyond 'used for beam'")
keep(T + "cleanskull.jpg", "plain bone-coloured skull skin: no blood, wound or gore")


def main() -> None:
    only = sys.argv[1:]
    fnd = findings()
    both = set(FIX) & set(KEEP)
    assert not both, f"fixed and kept: {sorted(both)}"
    missing = sorted(set(fnd) - set(FIX) - set(KEEP) - REPLACED)
    if missing and not only:
        sys.exit("findings neither fixed nor kept:\n  " + "\n  ".join(missing))
    for v, ops in FIX.items():
        if only and not any(o in v for o in only):
            continue
        a = load(v)
        shape = a.shape
        for _, fn in ops:
            a = fn(a, v)
        assert a.shape == shape or v == REJECTED, v
        save(v, a)
        print("fixed", v)
    if only:
        return

    def key(v):
        n = fnd.get(v, ("", "", ""))[0]
        return (0, int(n)) if n else (1, 0), v

    with open(LOG_FIXED, "w", encoding="utf-8", newline="\n") as f:
        f.write("# n (live review; - = added here)\tvpath\tseverity\tissue\twhat changed (content_fix4.py -> work/upload/fixed4/)\n")
        for v in sorted(FIX, key=key):
            n, sev, issue = fnd.get(v, ("-", "-", "Rejected by Roblox" if v == REJECTED else "same change as its base texture"))
            f.write(f"{n}\t{v}\t{sev}\t{issue}\t{'; '.join(w for w, _ in FIX[v])}\n")
    with open(LOG_KEPT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# n\tvpath\tseverity\tissue\tkept unchanged because\n")
        for v in sorted(KEEP, key=key):
            n, sev, issue = fnd.get(v, ("-", "-", "-"))
            f.write(f"{n}\t{v}\t{sev}\t{issue}\t{KEEP[v]}\n")
        for v in sorted(REPLACED, key=key):
            n, sev, issue = fnd[v]
            f.write(f"{n}\t{v}\t{sev}\t{issue}\tnot kept: already replaced by an earlier fix (gore_fix/content_fix), "
                    "the flagged upload is no longer used and is on the archive list\n")
    print(f"{len(FIX)} fixed, {len(KEEP)} kept, {len(REPLACED)} replaced earlier ({len(fnd)} findings)")


if __name__ == "__main__":
    main()
