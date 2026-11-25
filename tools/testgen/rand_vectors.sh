#!/usr/bin/env bash
# Regenerate tests/vectors/rand.tsv from the real glibc rand() (needs gcc).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -o "$out/rand_vectors" tools/testgen/rand_vectors.c
"$out/rand_vectors" > tests/vectors/rand.tsv
rm -rf "$out"
