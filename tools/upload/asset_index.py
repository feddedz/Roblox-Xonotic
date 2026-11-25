#!/usr/bin/env python3
"""The one place that says which Roblox asset the game must use for every texture file of the release.

  python3 tools/upload/asset_index.py           -> check only: is every file covered by a current asset?
  python3 tools/upload/asset_index.py --write   -> assets/manifest/texture-assets.tsv
                                                   + platform/render/texture_assets.luau (+ _N data parts)

Why it is needed: roblox-images.tsv is an upload log. It also holds old uploads of files that later got a
Roblox-safe fixed version (gore_fix / content_fix / content_fix3 / content_fix4), and it is keyed by checksum,
not by file name. The CURRENT version of a file is: vfs-high.tsv (vpath -> sha256 of the original) ->
upload-ready.tsv (original sha256 -> which version is uploaded: original or fixed*) -> roblox-images.tsv
(sha256 of that version -> asset id). Files with identical bytes (pk3 duplicates, symlinks) share one asset.
This tool resolves that chain for all texture vpaths, refuses to write if any file has no asset, and reports
assets that are not Approved + Active (from roblox-assets-state.tsv, tools/upload/check_assets.py).
Sounds have the same thing already: platform/sound/audio_assets.luau (tools/sounds/audio_plan.py); they are
only checked here. Re-run with --write after every upload.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
M = ROOT / "assets/manifest"
TSV = M / "texture-assets.tsv"
LUA = ROOT / "platform/render/texture_assets.luau"
PART_CHARS = 180_000  # G-024: keep modules under ~190k characters


def rows(name):
    return [l.split("\t") for l in (M / name).read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]


def resolve():
    """[(vpath, asset id or '', source, representative vpath)] for every texture .jpg of the release."""
    ready = {c[3]: c for c in rows("upload-ready.tsv")}  # original sha -> (vpath, source, ready sha, original sha, ...)
    up = {c[0]: c[2] for c in rows("roblox-images.tsv") if len(c) > 4 and c[4] == "ok"}
    out = []
    for c in rows("vfs-high.tsv"):
        v, kind, sha = c[0], c[1], c[4]
        if kind != "texture" or not v.endswith(".jpg"):
            continue
        r = ready.get(sha)
        if r is None:
            out.append((v, "", "not in upload-ready.tsv", ""))
            continue
        out.append((v, up.get(r[3] if r[1] == "original" else r[2], ""), r[1], r[0]))
    return out


def states():
    f = M / "roblox-assets-state.tsv"
    return {c[0]: (c[4], c[5]) for c in rows(f.name)} if f.exists() else {}


def check_sounds(st) -> int:
    plan = {c[0]: c[16].strip() for c in rows("audio-plan.tsv") if len(c) > 16}
    lua = dict(re.findall(r'\["([^"]+)"\] = (\d+),', (ROOT / "platform/sound/audio_assets.luau").read_text(encoding="utf-8")))
    want = [c[0] for c in rows("vfs-high.tsv") if c[1] in ("sound", "music") and not c[0].endswith(".mid")]
    bad = [v for v in want if not plan.get(v) or lua.get(v) != plan.get(v)]
    notok = [(v, *st[plan[v]]) for v in want if plan.get(v) in st and st[plan[v]][0] != "Approved"]
    print(f"sounds: {len(want)} files, {len(want) - len(bad)} in audio_assets.luau with the planned asset id")
    for v in bad:
        print("  MISSING/STALE sound", v)
    for v, mod, s in notok:
        print(f"  sound not usable: {v} ({mod})")
    return len(bad)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()
    res, st = resolve(), states()
    missing = [r for r in res if not r[1]]
    print(f"textures: {len(res)} files, {len({r[1] for r in res if r[1]})} assets, sources:",
          dict(Counter(r[2] for r in res)))
    for v, _, src, rep in missing[:60]:
        print(f"  NO ASSET YET: {v} ({src})")
    if len(missing) > 60:
        print(f"  ... and {len(missing) - 60} more")
    notok = [(r, st[r[1]]) for r in res if r[1] in st and not (st[r[1]][0].startswith("Approved") and st[r[1]][1] in ("Active", "?"))]
    unread = sum(1 for r in res if r[1] and r[1] not in st)
    for r, (mod, s) in notok:
        print(f"  NOT USABLE: {r[0]} asset {r[1]} is {mod}/{s}")
    print(f"textures: {len(missing)} files without an asset, {len(notok)} with an unusable asset, "
          f"{unread} whose asset state has not been read yet (run check_assets.py)")
    bad_sounds = check_sounds(st)
    if not a.write:
        sys.exit(1 if missing or bad_sounds else 0)
    if missing:
        sys.exit("not written: upload the missing files first")
    with open(TSV, "w", encoding="utf-8", newline="\n") as f:
        f.write("# vpath\tasset_id\tversion (original|fixed*|blurred)\tsame file as (the vpath it was uploaded under)\t"
                "moderation/state when last read\n")
        for v, aid, src, rep in res:
            f.write(f"{v}\t{aid}\t{src}\t{'' if rep == v else rep}\t{'/'.join(st.get(aid, ('not read',)))}\n")
    head = ("--!strict\n-- GENERATED by tools/upload/asset_index.py from assets/manifest/{vfs-high,upload-ready,roblox-images}.tsv. "
            "Do not edit.\n")
    parts, cur = [], []
    for v, aid, _, _ in res:
        assert '"' not in v and "\\" not in v, v
        cur.append(f'\t["{v}"] = {aid},\n')
        if sum(map(len, cur)) > PART_CHARS:
            parts.append(cur)
            cur = []
    if cur:
        parts.append(cur)
    for old in LUA.parent.glob("texture_assets_*.luau"):
        old.unlink()
    for i, p in enumerate(parts, 1):
        with open(LUA.parent / f"texture_assets_{i}.luau", "w", encoding="utf-8", newline="\n") as f:
            f.write(head + f"-- Part {i} of {len(parts)} of texture_assets.luau (split to stay under the script size limit, G-024).\n"
                    "return {\n" + "".join(p) + "}\n")
    with open(LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write(head + "-- Roblox image asset id of every texture file of the release (vpath as DarkPlaces opens it), always the\n"
                "-- CURRENT version: files that got a Roblox-safe fixed version point at the fixed upload, never at the old\n"
                "-- one; identical files share an id. Use it as `rbxassetid://<id>`.\n"
                "local all: { [string]: number } = {}\n\n"
                "local function add(part: { [string]: number })\n\tfor vpath, id in part do\n\t\tall[vpath] = id\n\tend\nend\n\n"
                + "".join(f'add(require("./texture_assets_{i}"))\n' for i in range(1, len(parts) + 1))
                + "\nreturn all\n")
    print(f"wrote {TSV.relative_to(ROOT)} and {LUA.relative_to(ROOT)} (+ {len(parts)} parts)")


if __name__ == "__main__":
    main()
