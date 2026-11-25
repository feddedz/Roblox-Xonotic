#!/usr/bin/env bash
# Regenerate tests/vectors/curves.tsv: the release's curves.c and model_shared.c compiled unchanged (needs gcc
# and the release source: tools/release/fetch.sh source). Only the patch functions and three mesh helpers of
# model_shared.c are called; everything else is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/curves_vectors" tools/testgen/curves_vectors.c "$dp/curves.c" "$dp/model_shared.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/curves_vectors" > tests/vectors/curves.tsv
rm -rf "$out"
