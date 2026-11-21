#!/usr/bin/env python3
"""M1-SOUNDS: moderation state of every uploaded sound (Open Cloud GET /assets/v1/assets/{id}).

  python3 tools/sounds/check_moderation.py      -> assets/manifest/roblox-audio-moderation.tsv + counts

Rejected sounds must be reported to the owner (HANDOFF §QUESTIONS), never replaced or dropped silently.
"""
import json
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_audio import API, IDS, ROOT, request  # noqa: E402

OUT = ROOT / "assets/manifest/roblox-audio-moderation.tsv"


def main() -> None:
    rows = [l.split("\t") for l in IDS.read_text().splitlines() if l and not l.startswith("#")]
    latest = {}
    for r in rows:
        if r[4] == "ok":
            latest[r[0]] = r  # a later upload for the same file (e.g. censored, D-022) replaces the earlier one
    rows = list(latest.values())

    def one(r):
        try:
            a = request("GET", f"{API}/assets/{r[2]}?readMask=moderationResult")
            return r[1], r[2], a.get("moderationResult", {}).get("moderationState", "?")
        except RuntimeError as e:
            return r[1], r[2], "error " + str(e)[:80]

    with ThreadPoolExecutor(max_workers=8) as ex:
        res = sorted(ex.map(one, rows))
    OUT.write_text("# vpath\tasset_id\tmoderationState\n" + "".join(f"{v}\t{i}\t{s}\n" for v, i, s in res))
    c = Counter(s for _, _, s in res)
    print(json.dumps(c), "->", OUT.relative_to(ROOT))
    for v, i, s in res:
        if s not in ("Approved", "Reviewing"):
            print("  ", s, v, i)


if __name__ == "__main__":
    main()
