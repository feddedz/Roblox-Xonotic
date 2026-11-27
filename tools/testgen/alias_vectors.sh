#!/usr/bin/env bash
# Regenerate tests/vectors/alias.tsv: the release's model_shared.c, model_alias.c and model_sprite.c (included by
# alias_vectors.c so their statics can be reached), model_brush.c, bih.c, collision.c, polygon.c, mathlib.c,
# matrixlib.c, common.c and the two skeletal vertex files compiled unchanged (needs gcc and the release source:
# tools/release/fetch.sh source), run on the fixture models of tests/fixtures/models/ (no game data;
# tools/testgen/make_model_fixtures.py). Everything the loaders do not reach is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/alias_vectors" tools/testgen/alias_vectors.c "$dp/model_brush.c" "$dp/bih.c" "$dp/collision.c" \
	"$dp/polygon.c" "$dp/mathlib.c" "$dp/matrixlib.c" "$dp/common.c" \
	"$dp/mod_skeletal_animatevertices_generic.c" "$dp/mod_skeletal_animatevertices_sse.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/alias_vectors" > tests/vectors/alias.tsv
rm -rf "$out"
