#!/usr/bin/env bash
# Reproducible build step for everything Rojo syncs that is not committed (D-017, M2-AOT-SHIP):
#   1. pinned Xonotic 0.8.6 release (-high build; sha512-checked)      -> work/release-high/
#   2. the three QuakeC programs from the resolved VFS (fs.c order)     -> work/progs/*.dat
#   3. QuakeC compiled to Luau (tools/qcaot/compile.py)                 -> game/generated/{progs,csprogs,menu}/
# Then: rojo serve (or rojo build default.project.json -o xonotic.rbxl).
# Needs: bash, curl, unzip, python3 (stdlib only for this step). Safe to re-run; skips what is up to date.
set -euo pipefail
cd "$(dirname "$0")/.."
tools/release/fetch.sh high
mkdir -p work/progs
python3 - <<'PY'
import hashlib, sys
from pathlib import Path
sys.path.insert(0, "tools/pk3")
from vfs import Vfs
want = {  # D-001
    "progs.dat": "e6f5c70b8e0e5f329531ce53ac982eb698a12660a1b45622a900a7bc3bb87a62",
    "csprogs.dat": "7d7807166d38521aadb8109830b69580596be4c05924d1b1fd8b71c31d4def13",
    "menu.dat": "dc75076060bac00aacdcd58d6a216cfb33f7a4665a18a622ff970bc73869bbb8",
}
out = Path("work/progs")
todo = [n for n, h in want.items() if not (out / n).exists() or hashlib.sha256((out / n).read_bytes()).hexdigest() != h]
if todo:
    vfs = Vfs(sorted(Path("work/release-high/Xonotic/data").glob("*.pk3")))
    for n in todo:
        data = vfs.read(n)
        if hashlib.sha256(data).hexdigest() != want[n]:
            sys.exit(f"{n}: checksum mismatch with D-001")
        (out / n).write_bytes(data)
print("progs ok:", ", ".join(want))
PY
for p in progs csprogs menu; do
	python3 tools/qcaot/compile.py "work/progs/$p.dat" "game/generated/$p"
done
echo "build ok: game/generated/{progs,csprogs,menu} ready for rojo"
