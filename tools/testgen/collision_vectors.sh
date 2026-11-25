#!/usr/bin/env bash
# Regenerate tests/vectors/collision.tsv: the release's collision.c and polygon.c compiled unchanged (needs gcc
# and the release source: tools/release/fetch.sh source). Only Collision_NewBrushFromPlanes and the PolygonD
# functions are called; every other function of collision.c is dropped at link time (--gc-sections), so the
# rest of the engine does not have to be linked.
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/collision_vectors" tools/testgen/collision_vectors.c "$dp/collision.c" "$dp/polygon.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/collision_vectors" > tests/vectors/collision.tsv
rm -rf "$out"
