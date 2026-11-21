# M2-RUNNER: headless server QuakeC

Goal (done criterion): the server QC runs world spawn on a stock map headless, with the engine doing what
DarkPlaces does (SV_SpawnServer → ED_LoadFromFile → spawn functions), builtins either ported or stubbed
with logged `NOT YET PORTED` messages.

## Done so far (2026-11-20, 017gQiyN)
- `engine/sv_main.luau` SV_VM_Setup (partial): builtins table, max_edicts 512, limit MAX_EDICTS, PRVM_Prog_Load
  with sv_reqfields / sv_reqglobals.
- `engine/prvm_offsets.luau` + `engine/_port/builtin_names.luau`: generated from prvm_offsets.h and
  vm_sv/cl/m_builtins[] by `tools/engine/gen_tables.py` (644 server entries, 256 non-NULL).
- `engine/svvm_cmds.luau`: builtin table with logging stubs; real builtins go in `PORTED`.
- `engine/prvm_edict.luau`: PRVM_SetEngineString (C pointer identity = Luau table identity), ED_FindField /
  FindGlobal / FindFunction; required defs named with engine strings in C order (globals, then fields).
- `tests/integration/sv_vm_setup.test.luau`: layout = file + required (unconditional append), every builtin
  progs.dat uses exists except the 3 that are NULL in DarkPlaces too (#352, #566, #608), and
  `spawnfunc_worldspawn` with self = world **completes identically on interpreter and AOT** with all
  builtins stubbed (282,036 builtin calls, 68 distinct). Meaningless as gameplay (cvars all 0) but proves
  the pipeline.

## Done 2026-11-21 (Claude-Anvil): settings
- `engine/cvar.luau` (cvar.c), `engine/cmd.luau` (cmd.c), partial `fs.luau`, `filematch.luau`, `common.luau`,
  `console.luau`, `host.luau`, `host_cmd.luau` (MaxPlayers_f), `prvm_cmds.luau` (cvar builtins),
  `_port/libc.luau` (glibc atof/strtol/atoi/(int), vectors from real glibc: tools/testgen/libc_vectors.sh).
- `tools/engine/gen_cvars.py` → `engine/_port/sv_init_defs.luau`: follows Host_Init's dedicated path through the
  OBJ_SV sources (USEODE on, CONFIG_MENU/CONFIG_CD off) and lists every Cvar_RegisterVariable / Cmd_AddCommand
  in order (488 cvars, 132 commands). Conditional registrations are printed for review (crypto_* need the
  d0_blind_id library, present in release builds; net_tos_dscp; r_skeletal_use_sse). Validate with
  REF-CVARLIST (real `cvarlist` dump).
- `host.Host_Init_Dedicated()`: registrations, dedicated value changes (sv_public 1, deathmatch 1, fs_gamedir
  "data", cmdline ""), Cmd_SaveInitState, Host_AddConfigText, Cbuf_Execute: the real quake.rc chain runs
  (36 files, 6,075 cvars, ≈ 2 s in Lune). Unported engine commands are stubs logging `NOT YET PORTED: command`.
- PRVM_Prog_Load tail: required funcs, PRVM_Init_Exec, autocvars both ways (all 3,308 match),
  prog.loaded, prvm_prog_list; PRVM_SetTempString, PRVM_ChangeEngineString.
- Tests: unit/libc, unit/cvar_cmd, integration/config_load, integration/sv_config_worldspawn (fresh engine per
  run: interpreter and AOT identical incl. cvars afterwards).

## Done 2026-11-21 (Claude-Anvil): strings
- `engine/utf8lib.luau` (u8_analyze/strlen/bytelen/byteofs/getchar), PRVM_AllocString/FreeString (+ freeable flags),
  builtins print, ftos, stof, floor, pow, strlen, strcat, substring, strzone, strunzone, str2chr, strncmp
  (tests/unit/string_builtins). Worldspawn with real cvars: 22k stub calls (was 280k), interp == AOT; stops at
  "PRVM_FreeString: attempt to free a constant string" caused by the remaining stubs.
- Remaining worldspawn stubs, in call order: nextent, remove, fopen/fclose/fgets, changelevel, buf_create,
  buf_cvarlist, buf_getsize, buf_del, spawn, etof, bufstr_set/get, ftoe, digest_hex, SV_AddStat, SV_precache_model.
  strtoupper/strtolower need u8_tolower/u8_toupper tables (utf8lib.c).

## Done 2026-11-21 (Claude-Anvil): edicts
- PRVM_MEM_Alloc/IncreaseEdicts, ED_ClearEdict/CanAlloc/Alloc/Free (reuse rules with prvm_reuseedicts_*),
  prvm_edict.FieldOfs (name lookup = PRVM_FindOffsets result for Xonotic), SVVM_init_edict / SVVM_free_edict
  (world unlink, skeletons, ODE, csqc versions logged NOT YET PORTED), builtins spawn, remove, nextent, ftoe, etof
  (tests/unit/edicts). Worldspawn: 12k stub calls, interp == AOT, stops at "NULL function in server" (a QC
  callback not set because of the remaining stubs).
- Remaining worldspawn stubs: fopen/fclose/fgets, changelevel, buf_create/cvarlist/getsize/del, SV_copyentity,
  bufstr_set/get, digest_hex, SV_AddStat, SV_precache_model, bound.

- (later the same day) bound, buf_create/del/getsize, bufstr_get/set, buf_cvarlist: worldspawn 2,334 stub calls,
  remaining stubs fopen/fclose/fgets, changelevel, SV_copyentity, digest_hex, SV_AddStat, sprintf, localcmd,
  SV_precache_model; still "NULL function in server".

## Next steps, in order
1. Still open from the settings work: PRVM_FindOffsets + the PROGHEADER_CRC branch of SV_VM_Setup (engine
   field offsets from entvars_t, progs crc 5927), .po translation when prvm_language is set (default "").
2. REF-CVARLIST once REF-DP exists.
3. **Edicts**: PRVM_ED_Alloc / ED_Free / SVVM_init_edict / SVVM_free_edict (freetime reuse rules), world edict,
   reserved_edicts = maxclients.
4. **Strings**: PRVM_SetTempString / tempstrings buffer (64 KiB, PRVM_ExecuteProgram restores cursize),
   PRVM_AllocString / FreeString (zone strings, knownstrings_freeable).
5. **The 68 builtins world spawn calls** (print order from the test), starting with the pure ones (ftos,
   stof, strcat, strlen, floor, cvar*, buf_*), each a port of prvm_cmds.c / svvm_cmds.c with tests.
6. **SV_SpawnServer** flow (sv_main.c): world model via the M3 BSP loader (or its entity lump only at first),
   precaches (model/sound index order!), ED_LoadFromFile + ED_ParseEdict for the map's entity lump, then
   the spawn functions.
