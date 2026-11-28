#!/usr/bin/env bash
# Regenerate tests/vectors/protocol.tsv: the release's protocol.c (included by protocol_vectors.c to reach its
# statics), common.c, matrixlib.c and mathlib.c compiled unchanged (needs gcc and the release source:
# tools/release/fetch.sh source). Everything the called functions do not reach (the client side readers, the
# rest of common.c) is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
cf=(-std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" -I tools/testgen)
gcc "${cf[@]}" -o "$out/protocol_vectors" tools/testgen/protocol_vectors.c "$dp/common.c" "$dp/matrixlib.c" \
	"$dp/mathlib.c" -Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/protocol_vectors" > tests/vectors/protocol.tsv || { tail -n 3 tests/vectors/protocol.tsv | cut -c1-300; exit 1; }
rm -rf "$out"
