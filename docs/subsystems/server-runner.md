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

## Next steps, in order
1. **cvar.c** port (Cvar_Get/Set, flags, defaults) + **cmd.c** config execution (`exec` of the pinned
   default.cfg → quake.rc → xonotic-*.cfg chain) reading from the VFS, so values match a real server.
2. Rest of **PRVM_Prog_Load** (prvm_edict.c L2276-2468): autocvar_* globals initialised from cvars (L2380-2440,
   uses PRVM_SetEngineString for strings), PRVM_Init_Exec, .po handling (prvm_language), field/global
   offset lookup incl. the PROGHEADER_CRC branch of SV_VM_Setup (progs crc 5927 == PROGHEADER_CRC: engine
   field offsets come from entvars_t).
3. **Edicts**: PRVM_ED_Alloc / ED_Free / SVVM_init_edict / SVVM_free_edict (freetime reuse rules), world edict,
   reserved_edicts = maxclients.
4. **Strings**: PRVM_SetTempString / tempstrings buffer (64 KiB, PRVM_ExecuteProgram restores cursize),
   PRVM_AllocString / FreeString (zone strings, knownstrings_freeable).
5. **The 68 builtins world spawn calls** (print order from the test), starting with the pure ones (ftos,
   stof, strcat, strlen, floor, cvar*, buf_*), each a port of prvm_cmds.c / svvm_cmds.c with tests.
6. **SV_SpawnServer** flow (sv_main.c): world model via the M3 BSP loader (or its entity lump only at first),
   precaches (model/sound index order!), ED_LoadFromFile + ED_ParseEdict for the map's entity lump, then
   the spawn functions.
