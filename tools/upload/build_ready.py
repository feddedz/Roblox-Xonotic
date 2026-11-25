#!/usr/bin/env python3
"""Build the upload-ready texture set (nothing is uploaded here).

  python3 tools/upload/build_ready.py   -> work/upload/ready/<vpath> + assets/manifest/upload-ready.tsv

For every unique texture of the release (one per sha256, like tools/upload/upload_images.py), the file that
goes to Roblox is, in priority order:
  0. work/upload/fixed4/<vpath>  fixes of the flagged images uploaded before the ban (tools/upload/content_fix4.py,
                                 UPLOAD-FIX4); built on top of 1-4, so it must win
  1. work/upload/fixed3/<vpath>  strict-review fixes (tools/upload/content_fix3.py, UPLOAD-FIX3, G-051); built on
                                 top of 2-4, so it must win
  2. work/upload/fixed/<vpath>   gore fixes (tools/upload/gore_fix.py, owner decisions D-022/D-024 style)
  3. work/upload/fixed2/<vpath>  content fixes: text/URL/phone/brand/drug/blood (tools/upload/content_fix.py)
  4. work/upload/blurred/<vpath> text blurs (tools/upload/blur_text.py, D-024)
  5. the original                work/vfs-high/<vpath>
Manifest columns: vpath, source (fixed4|fixed3|fixed|fixed2|blurred|original), sha256 of the ready file, original
sha256, already_uploaded (asset id of the ORIGINAL if it went up before the review; a fixed version is a new asset).
"""
import hashlib, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    rows = [l.split("\t") for l in (ROOT / "assets/manifest/vfs-high.tsv").read_text().splitlines()
            if l and not l.startswith("#")]
    up = {}
    for l in (ROOT / "assets/manifest/roblox-images.tsv").read_text().splitlines():
        c = l.split("\t")
        if not l.startswith("#") and len(c) > 4 and c[4] == "ok":
            up[c[0]] = c[2]
    seen, out, counts = set(), [], {}
    for c in rows:
        v, sha = c[0], c[4]
        if c[1] != "texture" or not v.endswith(".jpg") or sha in seen:
            continue
        seen.add(sha)
        src, kind = ROOT / "work/vfs-high" / v, "original"
        for k, d in (("fixed4", "work/upload/fixed4"), ("fixed3", "work/upload/fixed3"), ("fixed", "work/upload/fixed"), ("fixed2", "work/upload/fixed2"),
                     ("blurred", "work/upload/blurred")):
            p = ROOT / d / v
            if p.exists():
                src, kind = p, k
                break
        dst = ROOT / "work/upload/ready" / v
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        h = hashlib.sha256(dst.read_bytes()).hexdigest()
        out.append(f"{v}\t{kind}\t{h}\t{sha}\t{up.get(sha, '')}")
        counts[kind] = counts.get(kind, 0) + 1
    with open(ROOT / "assets/manifest/upload-ready.tsv", "w", newline="\n") as f:  # LF on every OS
        f.write("# vpath\tsource\tready_sha256\toriginal_sha256\toriginal_asset_id(if uploaded before review)\n"
                + "\n".join(out) + "\n")
    print(len(out), "textures ready:", counts)


if __name__ == "__main__":
    main()
