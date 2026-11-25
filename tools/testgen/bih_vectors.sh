#!/usr/bin/env bash
# Regenerate tests/vectors/bih.tsv: the release's bih.c compiled unchanged (needs gcc and the release source:
# tools/release/fetch.sh source). Floats are printed as bit patterns.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -ffp-contract=off -I work/source/Xonotic/source/darkplaces -o "$out/bih_vectors" tools/testgen/bih_vectors.c -lm
"$out/bih_vectors" > tests/vectors/bih.tsv
rm -rf "$out"
