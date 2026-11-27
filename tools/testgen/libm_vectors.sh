#!/usr/bin/env bash
# Regenerate tests/vectors/libm.tsv: the runner's glibc sin / cos / tan / asin / acos / atan / atan2 / pow / log
# (plus sqrt / fmod) on hard inputs, as bit patterns (needs gcc; no engine source). -fno-builtin keeps gcc from
# folding the calls at compile time.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -fno-builtin -o "$out/libm_vectors" tools/testgen/libm_vectors.c -lm
"$out/libm_vectors" > tests/vectors/libm.tsv
rm -rf "$out"
