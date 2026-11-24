#!/usr/bin/env python3
"""Before/after contact sheets for UPLOAD-FIX3 (owner review before any upload).

  python3 tools/upload/fix3_sheets.py   -> work/review_fix3/fNN.jpg (+ index.tsv)

One row per file of assets/manifest/review/content_fixes3.tsv:
  whole image before | whole image after | changed area before (zoom) | changed area after (zoom)
"before" is what would have been uploaded without this task (fixed > fixed2 > blurred > original); the yellow
frame on the whole-image thumbnails marks the changed area.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import content_fix3 as F  # noqa: E402

ROOT = F.ROOT
OUT = ROOT / "work/review_fix3"
S, LBL, ROWS = 232, 30, 7


def thumb(im: Image.Image, box=None) -> Image.Image:
    t = Image.new("RGB", (S, S), (24, 24, 24))
    c = im.crop(box) if box else im
    f = min(S / c.width, S / c.height)
    c = c.resize((max(1, round(c.width * f)), max(1, round(c.height * f))), Image.NEAREST if f > 2 else Image.LANCZOS)
    t.paste(c, ((S - c.width) // 2, (S - c.height) // 2))
    return t


def frame(t: Image.Image, im: Image.Image, box) -> Image.Image:
    f = min(S / im.width, S / im.height)
    ox, oy = (S - round(im.width * f)) // 2, (S - round(im.height * f)) // 2
    d = ImageDraw.Draw(t)
    d.rectangle([ox + box[0] * f - 1, oy + box[1] * f - 1, ox + box[2] * f + 1, oy + box[3] * f + 1], outline=(255, 230, 0))
    return t


def main() -> None:
    rows = [ln.split("\t") for ln in F.LOG_FIXED.read_text(encoding="utf-8").splitlines() if ln and not ln.startswith("#")]
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("f*.jpg"):
        old.unlink()
    idx = ["# sheet\trow\tn\tvpath"]
    for sh in range((len(rows) + ROWS - 1) // ROWS):
        part = rows[sh * ROWS:(sh + 1) * ROWS]
        img = Image.new("RGB", (4 * S + 15, len(part) * (S + LBL) + 16), (45, 45, 45))
        d = ImageDraw.Draw(img)
        d.text((4, 2), "whole before", fill=(200, 200, 200))
        d.text((S + 9, 2), "whole after", fill=(200, 200, 200))
        d.text((2 * S + 14, 2), "changed area before", fill=(200, 200, 200))
        d.text((3 * S + 19, 2), "changed area after", fill=(200, 200, 200))
        for r, (n, v, sev, issue, what) in enumerate(part):
            b = Image.open(F.src_path(v)).convert("RGB")
            a = Image.open(F.DST / v).convert("RGB")
            diff = np.abs(np.asarray(b).astype(int) - np.asarray(a).astype(int)).max(-1) > 10
            ys, xs = np.nonzero(diff)
            if len(ys):
                pad = max(6, int(0.15 * max(xs.max() - xs.min(), ys.max() - ys.min())))
                box = (max(0, xs.min() - pad), max(0, ys.min() - pad), min(b.width, xs.max() + pad + 1), min(b.height, ys.max() + pad + 1))
            else:
                box = (0, 0, b.width, b.height)
            y = 16 + r * (S + LBL)
            img.paste(frame(thumb(b), b, box), (0, y))
            img.paste(frame(thumb(a), a, box), (S + 5, y))
            img.paste(thumb(b, box), (2 * S + 10, y))
            img.paste(thumb(a, box), (3 * S + 15, y))
            d.text((3, y + S + 1), f"#{n} [{sev}] {v}  ({b.width}x{b.height})", fill=(255, 230, 0))
            d.text((3, y + S + 14), what[:150], fill=(230, 230, 230))
            idx.append(f"f{sh:02d}\t{r + 1}\t{n}\t{v}")
        img.save(OUT / f"f{sh:02d}.jpg", quality=90)
    (OUT / "index.tsv").write_text("\n".join(idx) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(rows)} files -> {OUT}")


if __name__ == "__main__":
    main()
