#!/usr/bin/env python3
"""Debug viewer data: pack one stock map so the ported loader can read it inside Roblox Studio.

  python3 tools/studio/pack_map.py stormkeep   -> work/studio/mapview/data/part001.luau ... + info.luau
  rojo build studio-mapview.project.json -o work/studio/mapview.rbxl     (then open it in Studio)

The .bsp bytes go base64 into ModuleScripts of at most 180k characters (D-020), in a gitignored folder. This is
only for tools/studio/mapview/MapView.luau (a debug viewer, not the game's renderer); the game will get maps
through the runtime VFS (M1-RTVFS).
"""
import base64
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 180_000


def main() -> None:
    name = sys.argv[1] if len(sys.argv) > 1 else "stormkeep"
    data = (ROOT / "work/vfs-high/maps" / f"{name}.bsp").read_bytes()
    out = ROOT / "work/studio/mapview/data"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.luau"):
        old.unlink()
    b64 = base64.b64encode(data).decode("ascii")
    step = LIMIT - LIMIT % 4  # whole base64 quanta per part
    parts = [b64[i:i + step] for i in range(0, len(b64), step)]
    for i, p in enumerate(parts, 1):
        (out / f"part{i:03d}.luau").write_text(f'return "{p}"\n', encoding="ascii", newline="\n")
    (out / "info.luau").write_text(
        f'return {{ name = "{name}", parts = {len(parts)}, bytes = {len(data)} }}\n', encoding="ascii", newline="\n")
    print(f"{name}: {len(data)} bytes -> {len(parts)} parts in {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
