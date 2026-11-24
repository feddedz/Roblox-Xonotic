#!/usr/bin/env python3
"""Contact sheets for the 2026-11-23 strict review (6x6 thumbnails, 220 px, labeled #n).

  python3 tools/upload/review_sheets.py remaining  -> work/review2/sNNN.jpg + index.tsv (upload-ready minus uploaded)
  python3 tools/upload/review_sheets.py live       -> work/review3/sNNN.jpg + index.tsv (uploaded assets, with ids)

Findings of that review: assets/manifest/review/upload_findings_*.tsv (remaining set, by sheet range) and
live_findings_*.tsv (live assets); copies of the indexes: assets/manifest/review/*_review_index.tsv.
"""
import math, os, sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]


def items(kind):
    up = {}
    for l in (ROOT / "assets/manifest/roblox-images.tsv").read_text().splitlines():
        if l.startswith("#"):
            continue
        c = l.split("\t")
        if c[4] == "ok":
            up.setdefault(c[1], c[2])
    if kind == "live":
        return list(up.items())
    ready = [l.split("\t")[0] for l in (ROOT / "assets/manifest/upload-ready.tsv").read_text().splitlines() if not l.startswith("#")]
    return [(v, "") for v in ready if v not in up]


def main():
    kind = sys.argv[1]
    out = ROOT / ("work/review3" if kind == "live" else "work/review2")
    out.mkdir(parents=True, exist_ok=True)
    its = items(kind)
    N, S, L = 6, 220, 18
    with open(out / "index.tsv", "w") as idx:
        idx.write("# n\tvpath\tasset_id\n")
        for sh in range(math.ceil(len(its) / 36)):
            img = Image.new("RGB", (N * S, N * (S + L)), (30, 30, 30))
            d = ImageDraw.Draw(img)
            for k in range(36):
                n = sh * 36 + k
                if n >= len(its):
                    break
                v, a = its[n]
                idx.write(f"{n}\t{v}\t{a}\n")
                x, y = (k % N) * S, (k // N) * (S + L)
                p = ROOT / "work/upload/ready" / v
                if not p.exists():
                    p = ROOT / "work/vfs-high" / v
                try:
                    im = Image.open(p).convert("RGB")
                    im.thumbnail((S, S))
                    img.paste(im, (x + (S - im.width) // 2, y + (S - im.height) // 2))
                except Exception:
                    d.text((x + 5, y + 5), "ERR", fill=(255, 0, 0))
                d.text((x + 3, y + S + 3), f"#{n}", fill=(255, 255, 0))
            img.save(out / f"s{sh:03d}.jpg", quality=88)
    print(f"{len(its)} images -> {out}")


if __name__ == "__main__":
    main()
