#!/usr/bin/env bash
# Regenerate tests/vectors/svphys.tsv: the release's sv_phys.c, sv_main.c, world.c, collision.c, polygon.c, bih.c,
# mathlib.c and matrixlib.c compiled unchanged, with model_brush.c and the synthetic map of trace_vectors.c
# included by svphys_vectors.c (needs gcc and the release source: tools/release/fetch.sh source). Everything the
# called functions do not reach is dropped at link time (--gc-sections), so the rest of the engine does not
# have to be linked.
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" -I tools/testgen \
	-o "$out/svphys_vectors" tools/testgen/svphys_vectors.c "$dp/sv_phys.c" "$dp/sv_main.c" "$dp/world.c" \
	"$dp/collision.c" "$dp/polygon.c" "$dp/bih.c" "$dp/mathlib.c" "$dp/matrixlib.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/svphys_vectors" > tests/vectors/svphys.tsv || { tail -n 3 tests/vectors/svphys.tsv | cut -c1-300; exit 1; }
rm -rf "$out"
