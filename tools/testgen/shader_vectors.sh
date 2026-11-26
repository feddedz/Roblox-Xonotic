#!/usr/bin/env bash
# Regenerate tests/vectors/shader.tsv: the release's model_shared.c (included by shader_vectors.c so the static
# shader hash can be read) and common.c compiled unchanged (needs gcc and the release source:
# tools/release/fetch.sh source), run on the fixture shader scripts of tests/fixtures/shaders/ (no game data).
# Everything Mod_LoadQ3Shaders / Mod_LoadTextureFromQ3Shader do not reach is dropped at link time (--gc-sections).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
gcc -std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" \
	-o "$out/shader_vectors" tools/testgen/shader_vectors.c "$dp/common.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/shader_vectors" > tests/vectors/shader.tsv
rm -rf "$out"
