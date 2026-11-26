#!/usr/bin/env bash
# Regenerate tests/vectors/movers.tsv: the release's sv_phys.c compiled into movers_vectors.c (with model_brush.c
# and the synthetic map of trace_vectors.c), linked with sv_main.c, world.c, collision.c, polygon.c, bih.c,
# mathlib.c and matrixlib.c, all unchanged (needs gcc and the release source: tools/release/fetch.sh source).
# Everything the called functions do not reach is dropped at link time (--gc-sections). movers_vectors.c is
# built with gcov instrumentation (it does not change the arithmetic): tests/vectors/movers_coverage.txt lists
# the lines of sv_phys.c L893-3232 the cases never ran (not committed; read it from the workflow artifact).
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
flags=(-std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" -I tools/testgen)
gcc "${flags[@]}" --coverage -c -o "$out/movers_vectors.o" tools/testgen/movers_vectors.c
gcc "${flags[@]}" --coverage -o "$out/movers_vectors" "$out/movers_vectors.o" "$dp/sv_main.c" "$dp/world.c" \
	"$dp/collision.c" "$dp/polygon.c" "$dp/bih.c" "$dp/mathlib.c" "$dp/matrixlib.c" \
	-Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/movers_vectors" > tests/vectors/movers.tsv || { tail -n 3 tests/vectors/movers.tsv | cut -c1-300; exit 1; }
root=$PWD
(
	cd "$out"
	gcov -f -o "$out" "$root/tools/testgen/movers_vectors.c" > gcov.log 2>&1 || true
	awk '/^Function/ { f = $2 } /^Lines executed/ && f ~ /SV_|ClipVelocity|AngleVectorsFLU/ { print f, $0; f = "" }' gcov.log
	g=$(ls ./*sv_phys.c.gcov 2>/dev/null | head -n 1)
	echo "gcov files: $(ls ./*.gcov 2>/dev/null | tr '\n' ' ')"
	awk -F: '{ c = $1; gsub(/ /, "", c); l = $2 + 0 }
		l >= 893 && l <= 3232 && c != "-" { n++; if (c ~ /#####/) { u++; miss = miss " " l } }
		END { printf "sv_phys.c L893-3232: %d executable lines, %d never run\nnever run:%s\n", n, u, miss }' "$g"
) > tests/vectors/movers_coverage.txt 2>&1 || true
rm -rf "$out"
