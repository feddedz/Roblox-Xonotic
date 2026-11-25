#!/usr/bin/env bash
# Regenerate tests/vectors/mathlib.tsv: DarkPlaces mathlib.c functions compiled from the release source
# (code copied verbatim into tools/testgen/mathlib_vectors.c; needs gcc). Outputs are float bit patterns.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -ffp-contract=off -o "$out/mathlib_vectors" tools/testgen/mathlib_vectors.c -lm
"$out/mathlib_vectors" > tests/vectors/mathlib.tsv
rm -rf "$out"
