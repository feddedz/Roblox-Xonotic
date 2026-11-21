#!/usr/bin/env python3
"""M1-UPLOAD: upload every texture of the release to Roblox as Image assets, byte-for-byte (the -high build
ships only .jpg, which Open Cloud accepts as is; nothing re-encoded or resized).

  python3 tools/upload/upload_images.py --user-id <id> [--jobs 8] [--limit N] [--type Image|Decal]

Unique by sha256 (pk3 symlinks and duplicates share one asset). Resumable: results are appended to
assets/manifest/roblox-images.tsv as each upload finishes; done sha256s are skipped on the next run.
Same safety as tools/sounds/upload_audio.py (expectedPrice 0, 429 back-off; key injected by the proxy).
"""
import argparse, json, sys, threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/sounds"))
import upload_audio as U  # noqa: E402

IDS = ROOT / "assets/manifest/roblox-images.tsv"
CT = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".tga": "image/tga", ".bmp": "image/bmp"}


def upload(path, vpath, sha, user, atype):
    name = "Xonotic " + vpath
    name = name if len(name) <= 50 else "Xonotic …" + name[-41:]
    meta = {"assetType": atype, "displayName": name,
            "description": f"Xonotic 0.8.6 (xonotic.org, GPLv3+) file {vpath}, sha256 {sha[:16]}",
            "creationContext": {"creator": {"userId": user}, "expectedPrice": 0}}
    body, ctype = U.multipart({"request": (None, "application/json", json.dumps(meta).encode()),
                               "fileContent": (path.name, CT[path.suffix.lower()], path.read_bytes())})
    op = U.request("POST", f"{U.API}/assets", body, ctype)
    opid = op.get("path", "").removeprefix("operations/")
    for _ in range(120):
        if op.get("done"):
            break
        U.time.sleep(2)
        op = U.request("GET", f"{U.API}/operations/{opid}")
    if not op.get("done"):
        return "", opid, "pending", "not done after 240 s"
    if op.get("error"):
        return "", opid, "error", json.dumps(op["error"])[:300]
    r = op.get("response", {})
    return str(r.get("assetId", "")), opid, "ok", json.dumps(r.get("moderationResult", {}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user-id", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--type", default="Image")
    ap.add_argument("--tier", default="auto", help="only this tier of assets/manifest/texture-review.tsv (auto/review/approved)")
    ap.add_argument("--batch", type=int, default=300, help="upload N, then wait until Roblox moderated all of them")
    ap.add_argument("--max-batches", type=int, default=1000)
    a = ap.parse_args()
    done = set()
    if IDS.exists():
        for l in IDS.read_text().splitlines():
            c = l.split("\t")
            if not l.startswith("#") and len(c) > 4 and c[4] == "ok":
                done.add(c[0])
    else:
        IDS.write_text("# sha256\tvpath\tasset_id\toperation\tstatus\tdetail\n")
    gore = set()
    gf = ROOT / "assets/optional/gore/textures.tsv"  # GORE-ASSETS: never uploaded to the main account
    if gf.exists():
        gore = {l.split("\t")[0] for l in gf.read_text().splitlines() if l and not l.startswith("#")}
    todo, seen = [], set()
    for l in (ROOT / "assets/manifest/vfs-high.tsv").read_text().splitlines():
        c = l.split("\t")
        if l.startswith("#") or c[1] != "texture" or c[4] in done or c[4] in seen or c[0] in gore:
            continue
        p = ROOT / "work/vfs-high" / c[0]
        if p.suffix.lower() not in CT:
            continue
        seen.add(c[4])
        todo.append((c[0], c[4], p))
    tiers = {}
    tf = ROOT / "assets/manifest/texture-review.tsv"
    for l in tf.read_text().splitlines():
        if l and not l.startswith("#"):
            v, k = l.split("\t")[:2]
            tiers[v] = k
    todo = [x for x in todo if tiers.get(x[0]) == a.tier]
    if a.limit:
        todo = todo[: a.limit]
    print(f"{len(done)} done, {len(todo)} to upload", flush=True)
    lock, n = threading.Lock(), {"ok": 0, "err": 0, "i": 0}

    stop = threading.Event()

    def one(t):
        vpath, sha, p = t
        if stop.is_set():
            return
        try:
            res = upload(p, vpath, sha, a.user_id, a.type)
        except RuntimeError as e:
            res = ("", "", "error", str(e)[:300])
        if "moderated" in res[3] or "403" in res[3]:
            stop.set()  # account blocked (unacknowledged warning / suspension): stop everything at once
        with lock:
            with open(IDS, "a") as f:
                f.write("\t".join([sha, vpath, *res[:3], res[3].replace("\t", " ").replace("\n", " ")]) + "\n")
            n["ok" if res[2] == "ok" else "err"] += 1
            n["i"] += 1
            if res[2] != "ok" or n["i"] % 250 == 0:
                print(f"[{n['i']}/{len(todo)}] {res[2]} {vpath} {res[0] or res[3][:150]}", flush=True)

    def moderation_gate(ids):
        """Wait until every asset of the batch is moderated; False if any is rejected or the account is moderated."""
        pending = set(ids)
        for _ in range(90):  # up to 45 min
            for aid in list(pending):
                try:
                    r = U.request("GET", f"{U.API}/assets/{aid}?readMask=moderationResult")
                except RuntimeError as e:
                    print(f"gate: {e}", flush=True)
                    return False
                st = r.get("moderationResult", {}).get("moderationState", "")
                if st == "Rejected":
                    print(f"gate: asset {aid} REJECTED - stopping", flush=True)
                    return False
                if st == "Approved":
                    pending.discard(aid)
            if not pending:
                return True
            U.time.sleep(30)
        print(f"gate: {len(pending)} still in review after 45 min - stopping to be safe", flush=True)
        return False

    for b in range(min(a.max_batches, (len(todo) + a.batch - 1) // a.batch)):
        chunk = todo[b * a.batch:(b + 1) * a.batch]
        before = n["ok"]
        start = IDS.read_text().count("\n")
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            list(ex.map(one, chunk))
        new = [l.split("\t")[2] for l in IDS.read_text().splitlines()[start:] if "\tok\t" in l]
        if n["err"] or n["ok"] == before:
            print(f"batch {b + 1}: upload errors - stopping", flush=True)
            break
        print(f"batch {b + 1}: {len(new)} uploaded, waiting for moderation...", flush=True)
        if not moderation_gate(new):
            break
        print(f"batch {b + 1}: all approved", flush=True)
    print(f"done: {n['ok']} ok, {n['err']} not ok", flush=True)


if __name__ == "__main__":
    main()
