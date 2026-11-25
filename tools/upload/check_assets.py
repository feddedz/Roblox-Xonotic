#!/usr/bin/env python3
"""Account check (read-only): moderation + archive state of every asset we ever uploaded.

  python3 tools/upload/check_assets.py   -> assets/manifest/roblox-assets-state.tsv + a summary

One Open Cloud GET per asset id in roblox-images.tsv and roblox-audio.tsv (nothing is uploaded or changed).
Each row says what the asset is for:
  needed      the game uses it (upload-ready.tsv row / audio-plan.tsv asset_id)
  archive     listed in archive-now.tsv or replace-after-review.tsv (owner archives it; must end as Archived)
  superseded  an older upload of a file that later got a fixed version or a re-upload; not used by the game
Done when: every needed asset is Approved + Active, and every archive asset is Archived.
"""
import argparse
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/sounds"))
import upload_audio as U  # noqa: E402

M = ROOT / "assets/manifest"
OUT = M / "roblox-assets-state.tsv"


def rows(name):
    return [l.split("\t") for l in (M / name).read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-last", type=int, default=0, help="do not re-read the last N image uploads (they just "
                    "passed the upload's own moderation gate); written as 'Approved(gate)'. GETs are rate-limited.")
    a = ap.parse_args()
    assets = {}  # asset id -> [kind, vpath, role]
    img = {}
    okrows = [c for c in rows("roblox-images.tsv") if len(c) > 4 and c[4] == "ok"]
    gated = {c[2] for c in okrows[len(okrows) - a.skip_last:]} if a.skip_last else set()
    for c in okrows:
        img[c[0]] = c[2]
        assets[c[2]] = ["image", c[1], "superseded"]
    for c in rows("upload-ready.tsv"):
        aid = img.get(c[3] if c[1] == "original" else c[2])
        if aid:
            assets[aid] = ["image", c[0], "needed"]
        else:
            print("NO ASSET for", c[0])
    for c in rows("roblox-audio.tsv"):
        if len(c) > 4 and c[4] == "ok":
            assets[c[2]] = ["audio", c[1], "superseded"]
    for c in rows("audio-plan.tsv"):
        aid = c[16].strip() if len(c) > 16 else ""
        if aid:
            assets.setdefault(aid, ["audio", c[0], "needed"])[2] = "needed"
        else:
            print("NO ASSET for", c[0])
    for name in ("archive-now.tsv", "replace-after-review.tsv"):
        for c in rows(name):
            if c[0] in assets and assets[c[0]][2] != "needed":
                assets[c[0]][2] = "archive"
            elif c[0] in assets:
                print("LISTED FOR ARCHIVE BUT NEEDED:", c[0], c[1])
            else:
                assets[c[0]] = ["image", c[1], "archive"]
    ids = sorted(assets)
    print(len(ids), "assets,", len(ids) - len(gated & set(ids)), "to read", flush=True)
    n = [0]

    def one(aid):
        if aid in gated:
            return "Approved(gate)", "?"
        try:
            r = U.request("GET", f"{U.API}/assets/{aid}?readMask=moderationResult,state")
            res = r.get("moderationResult", {}).get("moderationState", "?"), r.get("state", "?")
        except RuntimeError as e:
            res = "error", str(e)[:120].replace("\t", " ").replace("\n", " ")
        n[0] += 1
        if n[0] % 250 == 0:
            print(f"  {n[0]}/{len(ids)}", flush=True)
        return res

    with ThreadPoolExecutor(max_workers=3) as ex:
        res = list(ex.map(one, ids))
    with open(OUT, "w", newline="\n", encoding="utf-8") as f:  # LF on every OS
        f.write("# asset_id\tkind\tvpath\trole\tmoderationState\tstate\n")
        for aid, (mod, st) in zip(ids, res):
            f.write("\t".join([aid, *assets[aid], mod, st]) + "\n")
    c = Counter((assets[a][0], assets[a][2], mod, st if mod != "error" else "") for a, (mod, st) in zip(ids, res))
    for k, v in sorted(c.items()):
        print(f"{v:6d}  " + "  ".join(k))
    for aid, (mod, st) in zip(ids, res):
        kind, v, role = assets[aid]
        if mod == "Approved(gate)":
            continue
        if (role == "needed" and (mod != "Approved" or st != "Active")) or mod == "error":
            print("  PROBLEM", role, kind, v, aid, mod, st)


if __name__ == "__main__":
    main()
