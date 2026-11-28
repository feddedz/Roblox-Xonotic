#!/usr/bin/env bash
# Regenerate tests/vectors/netconn.tsv: the release's netconn.c and lhnet.c (included by netconn_vectors.c to reach
# their statics), common.c and crypto.c (no d0_blind_id library gets loaded) compiled unchanged (needs gcc and the
# release source: tools/release/fetch.sh source). What the scenario does not reach (the client side, the server
# list, rcon, the rest of common.c / crypto.c) is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
cf=(-std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" -I tools/testgen)
gcc "${cf[@]}" -o "$out/netconn_vectors" tools/testgen/netconn_vectors.c "$dp/common.c" "$dp/crypto.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/netconn_vectors" > tests/vectors/netconn.tsv || { tail -n 3 tests/vectors/netconn.tsv | cut -c1-300; exit 1; }
rm -rf "$out"
