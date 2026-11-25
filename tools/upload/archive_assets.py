#!/usr/bin/env python3
"""Archive every asset we uploaded that the game no longer uses (old versions that got a fixed replacement,
the archive lists, rejected leftovers). Never touches a needed asset.

  python3 tools/upload/archive_assets.py            -> list what would be archived (nothing is changed)
  python3 tools/upload/archive_assets.py --apply    -> archive them (owner's OK needed; reversible)

Open Cloud (G-052, read 2026-11-25): POST /assets/v1/assets/{id}:archive, no body, scope asset:write; the asset
then has "state": "Archived", disappears from the website and is not usable in experiences; POST ...:restore
undoes it. Results are appended to assets/manifest/roblox-archived.tsv; ids already there are skipped.
"needed" comes from tools/upload/check_assets.py (upload-ready.tsv / audio-plan.tsv), so run this only after
the replacement uploads are done and approved.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_assets as K  # noqa: E402

U = K.U
LOG = K.M / "roblox-archived.tsv"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    assets, _ = K.classify(quiet=True)
    up = {c[0] for c in K.rows("roblox-images.tsv") if len(c) > 4 and c[4] == "ok"}
    waiting = [c[0] for c in K.rows("upload-ready.tsv") if (c[3] if c[1] == "original" else c[2]) not in up]
    if waiting:  # a replacement is not on Roblox yet: its old version would look unused and the game would lose it
        print(f"{len(waiting)} upload-ready files have no asset yet (e.g. {waiting[0]})")
        if a.apply:
            sys.exit("upload them first - nothing archived")
    done = set()
    if LOG.exists():
        done = {l.split("\t")[0] for l in LOG.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")
                and l.split("\t")[3] == "Archived"}
    todo = [(aid, *v) for aid, v in sorted(assets.items(), key=lambda kv: (kv[1][0], kv[1][1])) if v[2] != "needed"
            and aid not in done]
    needed = sum(1 for v in assets.values() if v[2] == "needed")
    print(f"{needed} needed assets stay; {len(done)} archived before; {len(todo)} to archive", flush=True)
    for aid, kind, v, role in todo:
        if not a.apply:
            print(f"  would archive {kind} {aid} {v} ({role})")
    if not a.apply:
        return
    if not LOG.exists():
        LOG.write_text("# asset_id\tkind\tvpath\tstate after the call\n", encoding="utf-8", newline="\n")
    ok = 0
    for aid, kind, v, role in todo:
        assert assets[aid][2] != "needed"
        try:
            r = U.request("POST", f"{U.API}/assets/{aid}:archive", b"", "application/json")
            st = r.get("state", "?")
        except RuntimeError as e:
            st = "error " + str(e)[:160].replace("\t", " ").replace("\n", " ")
        with open(LOG, "a", encoding="utf-8", newline="\n") as f:
            f.write(f"{aid}\t{kind}\t{v}\t{st}\n")
        ok += st == "Archived"
        if st != "Archived":
            print("  ", st, kind, aid, v, flush=True)
            if "403" in st:
                sys.exit("403 - stopping")
    print(f"archived {ok} of {len(todo)}")


if __name__ == "__main__":
    main()
