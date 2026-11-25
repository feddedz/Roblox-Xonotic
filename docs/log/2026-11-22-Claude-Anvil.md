# 2026-11-22 Claude-Anvil — M1-UPLOAD (texture upload after unban), M2-RUNNER builtins

## Goal
Owner unbanned ~08:00 UTC: clean old asset metadata, run the gated texture upload unattended; meanwhile keep
porting M2-RUNNER builtins (docs/subsystems/server-runner.md).

## Done
- Unban check (read-only GET) → account clear. `tools/upload/patch_metadata.py`: all 3,201 uploaded assets
  renamed to neutral names/descriptions (no domain text, G-047). Resumed once after a connection reset.
- Gated upload started: `tools/upload/run_unattended.sh 876999276 6` (8,537 images, batches of 300, waits for
  Approved, stops at first Rejected/403). Batches 1–2 all approved; 3,296 images live at 09:25 UTC.
- Builtins ported (all registered in prvm_cmds.BUILTINS → svvm PORTED):
  strtolower/strtoupper (u8_toupper/u8_tolower tables generated from utf8lib.c), search_begin/end/getsize/
  getfilename, digest_hex (mdfour.c ported whole; SHA256), fopen/fgets/fputs/fclose (fs file handles,
  in-memory gamedir `fs.realfiles`), checkextension (vm_sv_extensions generated), random (glibc srand/rand),
  strftime (glibc C-locale strftime), entityfieldname, whichpack (FS_WhichPack; runtime VFS now carries the
  pk3 of each file), sprintf (full VM_sprintf + u8_strpad/_colorcodes), strdecolorize, makevectors,
  vectorvectors, normalize, vectoyaw, vectoangles, ceil, fabs, sin, cos, sqrt, asin, acos, atan, atan2, tan,
  log, randomvec, bitshift, changeyaw, changepitch, vtos, etos, stov (Math_atov), chr2str, strlennocol,
  isserver, wasfreed, dprint, find, findfloat, findflags, findchain, findchainfloat, findchainflags.
- engine/mathlib.luau: AngleVectors, AnglesFromVectors, VectorVectors, vector macros (bit-exact vs mathlib.c).

## Files changed
engine/{prvm_cmds,utf8lib,common,fs,sv_main,mdfour,mathlib}.luau, engine/_port/{libc,sha256,u8_case,extensions}.luau,
tools/engine/{gen_tables,check_port_lines}.py, tools/pk3/pack_runtime.py, tools/testgen/{rand,strftime,printf,mathlib}_vectors.{c,sh},
tests/vectors/{rand,strftime,printf,mathlib}.tsv, tests/unit/{libc,string_builtins,edicts,mathlib}.test.luau,
tests/_lib/vfs_provider.luau, assets/manifest/{metadata-patched,roblox-images}.tsv.

## Tests run and results
`lune run tests/run.luau`: 13 files, 0 failed. New reference vectors from the real glibc / C source: rand (9 seeds × 40),
strftime (451), printf single conversions (19,000), mathlib (50, bit-exact floats). stylua/selene clean, port lines 0 wrong,
python unittests OK. worldspawn: completes, stubs left are world/model/sound builtins (setorigin, setmodel, setsize,
precache_*, lightstyle, tracebox, AddStat, gettagindex, frameduration) + changelevel.

## Diffs added or closed
None.

## Decisions
- Crypto_Available() is true (the release ships d0_blind_id): DP_CRYPTO / SHA256 digest available.
- Files QC writes (fopen append/write) live in memory for now (fs.realfiles); persistence is a new task (M2-FSWRITE).

## Problems / dead ends
- Full test run now > 120 s (qcaot_diff alone 69 s): run it with a longer timeout.
- Luau string.format refuses widths/precisions > 99: libc.format1 pads those itself (float precision > 99 logs NOT YET PORTED).

## Next step
Buffer builtins (buf_copy/sort/implode, bufstr_add/free/find, buf_loadfile/writefile), strpad, strconv, strireplace,
matchpattern, tokenize, entity field string builtins, error/objerror/eprint, callfunction/isfunction; then world builtins (M3/M4).

## Update 2026-11-22 .. 11-24
- More builtins (error/objerror/eprint, field strings, buf_loadfile/writefile, precache_sound, lightstyle, AddStat,
  ambientsound), PRVM_ED_LoadFromFile & co., engine/server.luau, SZ/MSG writes. M2-RUNNER done.
- M2-AOT-SHIP: lazy chunk loading (saves ~20% on the server; Q-014).
- Upload: cp_glow.jpg sat in review 4 h, then the account was moderated (child safety, "CP" letters). Appeal granted.
- Strict re-review with 9 agents: 275 flagged in the remaining set, 119 in the live set; 28 live assets to archive
  (assets/manifest/archive-now.tsv). Fix agents stopped by the owner before writing anything → task UPLOAD-FIX3.
