#!/usr/bin/env bash
# Regenerate tests/vectors/svmove.tsv: the release's sv_move.c, svvm_cmds.c, sv_main.c, prvm_cmds.c, sv_phys.c,
# world.c, collision.c, polygon.c, bih.c, mathlib.c and matrixlib.c compiled unchanged, with model_brush.c and the
# synthetic map of trace_vectors.c / the server of svphys_vectors.c included by svmove_vectors.c (needs gcc and
# the release source: tools/release/fetch.sh source). svmove_vectors.c is compiled once per part (see its
# header); prvm_cmds.c gets the three frame / skeleton functions svphys_vectors.c stubs renamed. Everything the
# called functions do not reach is dropped at link time (--gc-sections), so the rest of the engine does not
# have to be linked.
set -euo pipefail
cd "$(dirname "$0")/../.."
dp=work/source/Xonotic/source/darkplaces
out=$(mktemp -d)
cf=(-std=gnu11 -O0 -ffp-contract=off -ffunction-sections -fdata-sections -w -I "$dp" -I tools/testgen)
gcc "${cf[@]}" -DSMV_PART_SVVM -c -o "$out/svvm.o" tools/testgen/svmove_vectors.c
gcc "${cf[@]}" -DSMV_PART_SVMAIN -c -o "$out/svmain.o" tools/testgen/svmove_vectors.c
gcc "${cf[@]}" -DSMV_PART_SVMOVE -c -o "$out/svmove.o" tools/testgen/svmove_vectors.c
gcc "${cf[@]}" -DVM_GenerateFrameGroupBlend=smv_unused_VM_GenerateFrameGroupBlend \
	-DVM_FrameBlendFromFrameGroupBlend=smv_unused_VM_FrameBlendFromFrameGroupBlend \
	-DVM_UpdateEdictSkeleton=smv_unused_VM_UpdateEdictSkeleton -c -o "$out/prvm_cmds.o" "$dp/prvm_cmds.c"
gcc "${cf[@]}" -o "$out/svmove_vectors" tools/testgen/svmove_vectors.c "$out/svvm.o" "$out/svmain.o" "$out/svmove.o" \
	"$out/prvm_cmds.o" "$dp/sv_phys.c" "$dp/world.c" "$dp/collision.c" "$dp/polygon.c" "$dp/bih.c" "$dp/mathlib.c" \
	"$dp/matrixlib.c" -Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all -lm
"$out/svmove_vectors" > tests/vectors/svmove.tsv || { tail -n 3 tests/vectors/svmove.tsv | cut -c1-300; exit 1; }
rm -rf "$out"
