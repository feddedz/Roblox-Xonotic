#!/usr/bin/env bash
# Regenerate tests/vectors/printf.tsv from the real glibc printf (needs gcc).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -Wno-format -o "$out/printf_vectors" tools/testgen/printf_vectors.c
LC_ALL=C "$out/printf_vectors" > tests/vectors/printf.tsv
rm -rf "$out"
