#!/usr/bin/env python3
"""G-047: replace the display name and description of every asset uploaded so far (they contained the file
path and "xonotic.org") with neutral text. Metadata only: the asset content and id stay the same.

  python3 tools/upload/patch_metadata.py [--limit N] [--dry-run]

Reads assets/manifest/roblox-audio.tsv and roblox-images.tsv (ok rows, latest per file), sends
PATCH /assets/v1/assets/{id}?updateMask=description,displayName (Open Cloud, asset:write), one at a time,
stops at the first 403 (account moderated). Resumable: done ids go to assets/manifest/metadata-patched.tsv.
"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/sounds"))
import upload_audio as U  # noqa: E402

DONE = ROOT / "assets/manifest/metadata-patched.tsv"


def rows(path: Path, kind: str):
    latest = {}
    if path.exists():
        for l in path.read_text().splitlines():
            c = l.split("\t")
            if not l.startswith("#") and len(c) > 4 and c[4] == "ok" and c[2]:
                latest[c[0]] = (c[2], c[0], kind)
    return list(latest.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    done = set(l.split("\t")[0] for l in DONE.read_text().splitlines()[1:]) if DONE.exists() else set()
    if not DONE.exists():
        DONE.write_text("# asset_id\tkind\n")
    todo = [r for r in rows(ROOT / "assets/manifest/roblox-audio.tsv", "sound") +
            rows(ROOT / "assets/manifest/roblox-images.tsv", "texture") if r[0] not in done]
    if a.limit:
        todo = todo[: a.limit]
    print(f"{len(done)} done, {len(todo)} to patch", flush=True)
    for i, (aid, sha, kind) in enumerate(todo, 1):
        meta = {"assetId": int(aid), "displayName": f"Xonotic {kind} {sha[:12]}",
                "description": f"{kind.capitalize()} from the open-source game Xonotic 0.8.6 (GPLv3+), sha256 {sha[:16]}"}
        if a.dry_run:
            print(meta)
            continue
        body, ctype = U.multipart({"request": (None, "application/json", json.dumps(meta).encode())})
        try:
            U.request("PATCH", f"{U.API}/assets/{aid}?updateMask=description%2CdisplayName", body, ctype)
        except RuntimeError as e:
            print(f"stop at {aid}: {e}", flush=True)
            sys.exit(1)
        with open(DONE, "a") as f:
            f.write(f"{aid}\t{kind}\n")
        if i % 200 == 0:
            print(f"{i}/{len(todo)}", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
