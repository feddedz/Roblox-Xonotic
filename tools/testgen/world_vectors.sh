#!/usr/bin/env bash
# Regenerate tests/vectors/world.tsv: the release's world.c compiled unchanged (needs gcc and the release
# source: tools/release/fetch.sh source). Only the area grid functions are called; the physics half of the file
# and everything else it references is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/world_vectors" tools/testgen/world_vectors.c "$dp/world.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/world_vectors" > tests/vectors/world.tsv
rm -rf "$out"
