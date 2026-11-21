#!/usr/bin/env bash
# Regenerate tests/vectors/libc.tsv from the real glibc (needs gcc).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
gcc -O0 -o "$out/libc_vectors" tools/testgen/libc_vectors.c
"$out/libc_vectors"
rm -rf "$out"
