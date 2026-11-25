#!/usr/bin/env python3
"""Build the asset manifest of the pinned release and optionally extract it.

  python3 tools/pk3/manifest.py --build standard [--extract]
  python3 tools/pk3/manifest.py --build high     [--extract]

Reads work/release-<build>/Xonotic/data/*.pk3 (tools/release/fetch.sh), resolves the
DarkPlaces VFS (tools/pk3/vfs.py) and writes assets/manifest/vfs-<build>.tsv:
  vpath  kind  pk3  size  sha256  shadowed(pk3s whose copy is hidden, comma-separated)  symlink_to
For a pk3 symlink, size/sha256/extracted bytes are those of the file DarkPlaces really opens
(FS_OpenReadFile follows the link) and symlink_to is that file's vpath; empty for normal files.
plus assets/manifest/pk3-<build>.tsv with the sha256 of every pk3.
--extract writes every winning file to work/vfs-<build>/<vpath> (input for all converters).
"""
import argparse, hashlib, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vfs import Vfs, kind_of  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def file_sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", choices=["standard", "high"], required=True)
    ap.add_argument("--extract", action="store_true")
    a = ap.parse_args()
    data = ROOT / f"work/release-{a.build}/Xonotic/data"
    pk3s = sorted(data.glob("*.pk3"))
    if not pk3s:
        sys.exit(f"no pk3 files in {data}; run tools/release/fetch.sh {a.build}")
    vfs = Vfs(pk3s)
    out = ROOT / "assets/manifest"
    out.mkdir(parents=True, exist_ok=True)
    with open(out / f"pk3-{a.build}.tsv", "w") as f:
        f.write("# pk3\tsize\tsha256\tsearch_order(1=searched first)\n")
        for i, p in enumerate(reversed(vfs.pk3s)):
            f.write(f"{p.name}\t{p.stat().st_size}\t{file_sha256(p)}\t{i + 1}\n")
    xdir = ROOT / f"work/vfs-{a.build}"
    rows = []
    for vpath in sorted(vfs.entries):
        e = vfs.entries[vpath]
        try:
            real = vfs.resolve(vpath)
        except KeyError as err:  # broken link: DarkPlaces fails to open it too
            print(f"warning: {err}", file=sys.stderr)
            real = None
        link = (real or "<broken>") if e.symlink else ""
        size = vfs.entries[real].size if real else e.size
        if real is None:
            digest = ""
        elif a.extract:
            dst = xdir / vpath
            dst.parent.mkdir(parents=True, exist_ok=True)
            blob = vfs.read(vpath)
            dst.write_bytes(blob)
            digest = hashlib.sha256(blob).hexdigest()
        else:
            digest = vfs.sha256(vpath)
        rows.append(f"{vpath}\t{kind_of(vpath)}\t{e.pk3}\t{size}\t{digest}\t{','.join(e.shadowed)}\t{link}")
    with open(out / f"vfs-{a.build}.tsv", "w") as f:
        f.write("# vpath\tkind\tpk3\tsize\tsha256\tshadowed\tsymlink_to\n")
        f.write("\n".join(rows) + "\n")
    kinds = {}
    for vpath in vfs.entries:
        k = kind_of(vpath)
        kinds[k] = kinds.get(k, 0) + 1
    shadowed = sum(1 for e in vfs.entries.values() if e.shadowed)
    links = sum(1 for e in vfs.entries.values() if e.symlink)
    print(f"{a.build}: {len(vfs.entries)} files, {shadowed} with shadowed copies, {links} symlinks; " +
          ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
