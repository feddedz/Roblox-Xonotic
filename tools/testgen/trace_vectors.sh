#!/usr/bin/env bash
# Regenerate tests/vectors/trace.tsv: the release's model_brush.c (included by trace_vectors.c so its static
# trace functions can be called), collision.c, polygon.c, bih.c, mathlib.c and matrixlib.c compiled unchanged (needs gcc and
# the release source: tools/release/fetch.sh source). Everything the trace functions do not reach is dropped at
# link time (--gc-sections), so the rest of the engine does not have to be linked.
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/trace_vectors" tools/testgen/trace_vectors.c "$dp/collision.c" "$dp/polygon.c" "$dp/bih.c" "$dp/mathlib.c" "$dp/matrixlib.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/trace_vectors" > tests/vectors/trace.tsv
rm -rf "$out"
