#!/usr/bin/env python3
"""D-024 / DIFF-007: blur the listed text areas (web addresses, phone-number-like digits) of textures.

  python3 tools/upload/blur_text.py      -> work/upload/blurred/<vpath> (originals untouched)

Boxes: assets/manifest/texture-blur.tsv (vpath, x, y, w, h in full-resolution pixels). Each box gets a strong
Gaussian blur (radius scales with the box height) so the text is unreadable; nothing else changes. Output is
saved as high-quality JPEG (quality 95) like the source format.
"""
from pathlib import Path
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    boxes: dict[str, list[tuple[int, int, int, int]]] = {}
    for l in (ROOT / "assets/manifest/texture-blur.tsv").read_text().splitlines():
        if l and not l.startswith("#"):
            c = l.split("\t")
            boxes.setdefault(c[0], []).append(tuple(int(x) for x in c[1:5]))
    for v, bs in boxes.items():
        im = Image.open(ROOT / "work/vfs-high" / v).convert("RGB")
        for x, y, w, h in bs:
            box = (x, y, min(im.width, x + w), min(im.height, y + h))
            region = im.crop(box).filter(ImageFilter.GaussianBlur(radius=max(4, h // 3)))
            im.paste(region, box)
        out = ROOT / "work/upload/blurred" / v
        out.parent.mkdir(parents=True, exist_ok=True)
        im.save(out, quality=95)
        print("blurred", v, len(bs), "areas")


if __name__ == "__main__":
    main()
