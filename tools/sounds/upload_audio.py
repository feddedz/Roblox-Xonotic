#!/usr/bin/env python3
"""M1-SOUNDS: upload the release's sounds to Roblox as audio assets (Open Cloud Assets API v1).

  python3 tools/sounds/upload_audio.py --user-id <id> [--limit N] [--dry-run]

Reads assets/manifest/audio-plan.tsv (tools/sounds/audio_plan.py) and uploads each *unique* file
(dup_of empty) exactly as it is in the release (work/vfs-high/<vpath>, no re-encoding), or a pack
from work/audio/packs/ when the plan packs it (not the case with the current quota, G-036).
Results go to assets/manifest/roblox-audio.tsv (sha256 -> asset id), one line written as soon as each
upload finishes, so an interrupted run resumes where it stopped (done sha256s are skipped).
audio_plan.py then fills the plan's asset_id column from that file, duplicates included.

Safety: `expectedPrice: 0` (Roblox fails the upload instead of charging Robux), one request at a time,
HTTP 429 -> wait x-ratelimit-reset seconds. The API key is never read here: in cloud sessions the
network proxy injects it (environment secret for apis.roblox.com); locally set ROBLOX_API_KEY.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "assets/manifest/audio-plan.tsv"
IDS = ROOT / "assets/manifest/roblox-audio.tsv"
API = "https://apis.roblox.com/assets/v1"
CTYPE = {".ogg": "audio/ogg", ".wav": "audio/wav", ".mp3": "audio/mpeg", ".flac": "audio/flac"}
HEADER = "# sha256\tvpath\tasset_id\toperation\tstatus\tdetail\n"


def key() -> str:
    return os.environ.get("ROBLOX_API_KEY") or "proxy-injected"


def request(method: str, url: str, body: bytes | None = None, ctype: str | None = None) -> dict:
    for attempt in range(8):
        req = urllib.request.Request(url, data=body, method=method, headers={"x-api-key": key()})
        if ctype:
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace")
            if e.code == 429 or e.code >= 500:
                wait = float(e.headers.get("x-ratelimit-reset") or 0) or min(60, 2 ** attempt)
                print(f"  HTTP {e.code}, waiting {wait:.0f} s", flush=True)
                time.sleep(wait + 1)
                continue
            raise RuntimeError(f"HTTP {e.code}: {text[:500]}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            time.sleep(min(60, 2 ** attempt))
            last = e
            continue
    raise RuntimeError(f"giving up after retries: {url}")


def multipart(fields: dict[str, tuple[str | None, str, bytes]]) -> tuple[bytes, str]:
    b = "----xonotic" + uuid.uuid4().hex
    out = bytearray()
    for name, (filename, ctype, data) in fields.items():
        out += f"--{b}\r\n".encode()
        disp = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        out += f"Content-Disposition: {disp}\r\nContent-Type: {ctype}\r\n\r\n".encode()
        out += data + b"\r\n"
    out += f"--{b}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={b}"


def display_name(vpath: str) -> str:
    # e.g. "Xonotic weapons/rocket_fire.ogg"; kept short (names are shown in the Creator Dashboard)
    name = "Xonotic " + vpath.removeprefix("sound/")
    return name if len(name) <= 50 else "Xonotic …" + name[-41:]


def upload(path: Path, vpath: str, sha: str, user_id: str) -> tuple[str, str, str, str]:
    meta = {
        "assetType": "Audio",
        "displayName": f"Xonotic sound {sha[:12]}",
        "description": f"Sound from the open-source game Xonotic 0.8.6 (GPLv3+), sha256 {sha[:16]}",
        "creationContext": {"creator": {"userId": user_id}, "expectedPrice": 0},
    }
    body, ctype = multipart({
        "request": (None, "application/json", json.dumps(meta).encode()),
        "fileContent": (path.name, CTYPE[path.suffix.lower()], path.read_bytes()),
    })
    op = request("POST", f"{API}/assets", body, ctype)
    opid = op.get("path", "").removeprefix("operations/") or op.get("operationId", "")
    for _ in range(120):
        if op.get("done"):
            break
        time.sleep(2)
        op = request("GET", f"{API}/operations/{opid}")
    if not op.get("done"):
        return "", opid, "pending", "operation not done after 240 s (re-run to resume)"
    if op.get("error"):
        return "", opid, "error", json.dumps(op["error"])[:300]
    resp = op.get("response", {})
    mod = json.dumps(resp.get("moderationResult", {}))
    return str(resp.get("assetId", "")), opid, "ok", mod


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--user-id", required=True)
    ap.add_argument("--limit", type=int, default=0, help="upload at most N files this run")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--jobs", type=int, default=1, help="parallel uploads (each waits for its own operation)")
    a = ap.parse_args()
    done: dict[str, str] = {}
    if IDS.exists():
        for line in IDS.read_text().splitlines():
            if line and not line.startswith("#"):
                c = line.split("\t")
                if c[4] == "ok":
                    done[c[0]] = c[2]
    else:
        IDS.write_text(HEADER)
    todo = []
    for line in PLAN.read_text().splitlines():
        if line.startswith("#"):
            continue
        c = line.split("\t")
        vpath, sha, up, dup = c[0], c[1], c[2], c[3]
        if dup or sha in done:
            continue
        src = ROOT / up if up.startswith("work/") else ROOT / "work/vfs-high" / up
        todo.append((vpath, sha, src))
    if a.limit:
        todo = todo[: a.limit]
    print(f"{len(done)} already uploaded, {len(todo)} to upload this run")
    n = {"ok": 0, "err": 0, "i": 0}
    lock = threading.Lock()

    def one(item):
        vpath, sha, src = item
        if n["err"] >= 10 and n["ok"] == 0:
            return
        try:
            aid, opid, status, detail = upload(src, vpath, sha, a.user_id)
        except RuntimeError as e:
            aid, opid, status, detail = "", "", "error", str(e)[:300]
        with lock:
            with open(IDS, "a") as f:
                f.write("\t".join([sha, vpath, aid, opid, status, detail.replace("\t", " ").replace("\n", " ")]) + "\n")
            n["ok" if status == "ok" else "err"] += 1
            n["i"] += 1
            print(f"[{n['i']}/{len(todo)}] {status} {vpath} -> {aid or detail[:120]}", flush=True)

    if a.dry_run:
        for vpath, _sha, src in todo:
            print(f"  would upload {vpath} ({src.stat().st_size} bytes) as {display_name(vpath)!r}")
    else:
        with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
            list(ex.map(one, todo))
    if n["err"] >= 10 and n["ok"] == 0:
        sys.exit("10 failures and no success: stopped (check the key / quota / errors above)")
    n_ok, n_err = n["ok"], n["err"]
    print(f"done: {n_ok} ok, {n_err} not ok -> {IDS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
