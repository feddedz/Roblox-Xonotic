#!/usr/bin/env bash
# Regenerate tests/vectors/strftime.tsv from the real glibc strftime (needs gcc).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -o "$out/strftime_vectors" tools/testgen/strftime_vectors.c
LC_ALL=C TZ=UTC "$out/strftime_vectors" > tests/vectors/strftime.tsv
rm -rf "$out"
