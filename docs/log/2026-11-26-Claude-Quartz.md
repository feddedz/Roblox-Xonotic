# 2026-11-26 Claude-Quartz — M3-TRACE (sv traces, world builtins), M3-BSPLOAD (shader C reference)

## Goal
Continue M3-TRACE after the area grid: the server trace / link functions and the QC builtins that use them;
check the Q3 shader code against the C build. Work done by three Opus sub-agents (owner's request), each
reviewed, re-run and committed by this session. Branch M3-TRACE-sv.

## Done
- engine/sv_phys.luau (new): SV_GetPitchSign, SV_GenericHitSuperContentsMask, SV_TracePoint, SV_TraceLine,
  SV_TraceBox, SV_PointSuperContents, SV_EntitiesInBox, SV_LinkEdict_TouchAreaGrid(_Call), RotateBBox,
  SV_LinkEdict, SV_NudgeOutOfSolid. engine/sv_main.luau: SV_GetModelByIndex, SV_GetModelFromEdict,
  SVVM_begin/end_increase_edicts relink, SVVM_free_edict unlink. engine/server.luau: sv.world, sv.worldmodel,
  sv.models (C index i at [i], like the precache lists).
- engine/svvm_cmds.luau: builtins #2 setorigin, #4 setsize (+SetMinMaxSize), #16 traceline, #90 tracebox,
  #22 findradius, #34 droptofloor, #41 pointcontents, copyentity relink; Mod_Q1BSP_NativeContentsFromSuperContents
  (model_brush.c L663-676, placed in svvm_cmds.luau for now). engine/prvm_cmds.luau: VM_SetTraceGlobals.
  New per-edict private tables: prog.ed_mark[n], prog.ed_suspendedinairflag[n].
- Q3 shader code checked against the C build: tools/testgen/shader_vectors.{c,sh} (includes model_shared.c,
  links common.c; FS / Mem / renderer stubbed), fixtures tests/fixtures/shaders/scripts/* (9 shader files +
  custinfoparms.txt), tests/vectors/shader.tsv, tests/unit/q3shaders_ref.test.luau: 4,363 checks (112 shaders
  loaded under two cvar settings, 222 texture cases). Fixes it forced in engine/model_shared.luau: strtol low
  32 bits / LONG_MAX clamp for custinfoparms values; shader pass indexes 8 and 9 land on materialshaderpass /
  backgroundshaderpass as in C (no bounds check in C); q3shaders() no longer skips a chained shader named "".
  engine/_port/libc.luau: strtod("nan") is a positive quiet NaN like glibc.

## Files changed
engine/{sv_phys,sv_main,server,svvm_cmds,prvm_cmds,model_shared}.luau, engine/_port/libc.luau,
tests/unit/{sv_phys,sv_world_builtins,q3shaders_ref}.test.luau, tests/fixtures/shaders/**,
tests/vectors/shader.tsv, tools/testgen/shader_vectors.{c,sh}, .github/workflows/testgen.yml, HANDOFF.md,
docs/log/INDEX.md, this log.

## Tests run and results
- Lune unit: 17 files, 0 failed (sv_phys 65, sv_world_builtins 192, q3shaders_ref 4,363, trace 8,685, world 745).
  q3shaders (release data) 73 checks pass. StyLua, Selene clean; check_port_lines 0 wrong.
- **Not checked against the C build:** sv_phys.luau and the new builtins (their tests compare against the
  already verified Collision_ClipTo* / World_* functions and against the C formulas, not against C output).

## Diffs added or closed
None.

## Decisions
None new. (sv.models uses the C index directly, matching model_precache; noted in server.luau.)

## Problems / dead ends
- sv_phys must be required lazily from svvm_cmds / sv_main (sv_phys -> sv_main -> svvm_cmds is a load loop).
- Edict field access in sv_phys / the new builtins goes through FieldOfs(name) per access (a hash lookup) and
  allocates small vectors: correct but slow; cache the offsets when the movers are ported.
- The frameblend / skeleton arguments of the entity traces are nil (VM_GenerateFrameGroupBlend,
  VM_FrameBlendFromFrameGroupBlend, VM_UpdateEdictSkeleton: NOT YET PORTED, logged once).

## Part 2 (same day): M4-PHYS claimed — movers, sv_move, C reference for the sv traces
- PR 11 merged. M4-PHYS claimed on main (sv_phys.c movers, sv_move.c). Branch M4-PHYS-movers. Three Opus
  sub-agents again; their work re-run and committed by this session.
- **sv traces now checked against the C build:** tools/testgen/svphys_vectors.{c,sh} (includes trace_vectors.c
  for the synthetic map, links the real sv_phys.c, sv_main.c, world.c, collision.c ...; prog with hand-made
  field / global offsets), tests/vectors/svphys.tsv, tests/unit/sv_phys_ref.test.luau: 2,524 checks, no
  difference found (363 SV_LinkEdict, 372 touch calls, 860 traces of which 417 hit an entity, 120
  SV_PointSuperContents, 130 SV_EntitiesInBox, 80 SV_NudgeOutOfSolid, cvar variants).
- engine/sv_phys.luau: the rest of sv_phys.c in C order: SV_TestEntityPosition, SV_CheckContentsTransition,
  SV_CheckVelocity, SV_RunThink, SV_Impact, ClipVelocity, SV_FlyMove, SV_Gravity,
  SV_NudgeOutOfSolid_PivotIsKnownGood, SV_PushEntity, SV_PushMove, SV_Physics_Pusher, SV_UnstickEntity(+
  ReturnOffset), SV_CheckStuck, SV_CheckWater, SV_WallFriction, SV_WalkMove, SV_Physics_Follow,
  SV_CheckWaterTransition, SV_Physics_Toss, SV_Physics_Step, SV_Physics_Entity, SV_Physics_ClientEntity*,
  SV_Physics_ClientMove, SV_Physics. Also there for now, with their own port lines: SV_Trace_Toss
  (svvm_cmds.c L703-748) and AngleVectorsFLU (mathlib.c L498-550) -- move them to their modules later.
  engine/server.luau: sv.frametime, server.host_client. New per-edict tables: prog.ed_move,
  ed_waterposition_forceupdate / _origin, ed_moved_from / _fromangles, ed_cullmins / ed_cullmaxs.
- engine/sv_move.luau (new, all of sv_move.c): SV_CheckBottom, SV_movestep, SV_StepDirection,
  SV_FixCheckBottom, SV_NewChaseDir, SV_CloseEnough, VM_SV_MoveToGoal. Builtins: #32 walkmove, #40
  checkbottom, #67 movetogoal, #64 tracetoss. SVVM_init_edict sets ed_move false.
- Stubs (log once): SV_StartSound, SV_ClientThink, World_Physics_Frame (ODE), frameblend / skeleton;
  host_client.cmd is an empty table; ed_cullmins / maxs stay zero until SV_PrepareEntityForSending exists
  (so SV_Physics_Toss's still-touching-ground check returns early).
- Tests: unit 20 files, 0 failed (sv_phys_movers 161, sv_move 129, sv_phys_ref 2,524). StyLua, Selene clean,
  check_port_lines 0 wrong. **The movers, sv_move and the builtins are NOT checked against the C build yet.**
  Helpers' own risk list: SV_PushMove (rotation, crush path, entity order), SV_FlyMove / SV_WalkMove step
  logic, float-vs-double in the frametime updates, cos / sin and the rand() order in sv_move.

## Part 3 (same day): movers, sv_move and builtins checked against the C build
- PR 12 merged. Branch M4-PHYS-ref, two Opus sub-agents.
- tools/testgen/movers_vectors.{c,sh} (`#include "sv_phys.c"` for the statics, the map of trace_vectors.c,
  gcov-instrumented), tests/vectors/movers.tsv (6 MB), tests/unit/sv_phys_movers_ref.test.luau: 3,770 calls,
  13,678 checks, incl. 273 whole SV_Physics frames in 14 sequences under Xonotic's own cvar values and the
  engine defaults. **No difference found; engine/sv_phys.luau unchanged.** gcov: 1012 of 1052 executable
  lines of sv_phys.c L893-3232 ran (24 unreachable with a Q3BSP world / enum defaults; 16 rare paths not hit:
  L960, L1271-1285, L1325-1327, L1371-1373, L1494, L2367, L2392, L2403, L2444).
- tools/testgen/svmove_vectors.{c,sh} (one .c compiled four times to reach the statics of svvm_cmds.c,
  sv_main.c, sv_move.c), tests/vectors/svmove.tsv (6.8 MB), tests/unit/sv_move_ref.test.luau: 12,515 calls,
  50,400 checks over sv_move.c and the builtins setorigin, setsize, traceline, tracebox, tracetoss,
  findradius, walkmove, droptofloor, checkbottom, pointcontents, copyentity, MoveToGoal and the edict hooks.
  One fix: the NaN error text of traceline / tracebox used string.format ("-nan(ind)" on Windows); now
  libc.format1 (svvm_cmds.c L657, L696). libc.snprintf has the same weakness for non-finite %f (open).
- **G-058:** the host's math.cos / math.sin differ from glibc by one ulp for about 3 % of the yaws on
  Windows (277 / 315 of 9,761). No float move changed in any vector, but it can. tests/unit/
  sv_move_libm_ref.test.luau fails only if a float move changes and prints the count. Task PORT-LIBM added.
- Tests: unit 23 files, 0 failed. StyLua, Selene clean; check_port_lines 0 wrong. Vector files are the
  Testgen artifacts byte for byte.

## Part 4 (same day): PORT-LIBM done, M4-SPAWN (a map starts)
- PR 13 merged. PORT-LIBM and M4-SPAWN claimed on main. Branch M4-SPAWN-libm, two Opus sub-agents.
- **PORT-LIBM done:** engine/_port/libm.luau = pure-Luau ports of glibc sin, cos, tan, asin, acos, atan,
  atan2, pow, log (+ fmod wrapper), LGPL notices kept. Reference = the runner's glibc **2.43** on a CPU with
  FMA: the port emulates the fused multiply-adds of the FMA build exactly (double-double product + round to
  odd); branred is built without FMA, as in glibc. tools/testgen/libm_vectors.{c,sh}, tests/vectors/libm.tsv,
  tests/unit/libm.test.luau: 36,631 checks, 0 differences (the host's math.* differed on 3 to 297 of the
  vectors per function). Every caller switched (mathlib, matrixlib, curves, sv_phys, sv_move, prvm_cmds,
  svvm_cmds): no math.sin / cos / tan / asin / acos / atan / atan2 / pow / log / ^ left in engine/. G-058 is
  closed for these functions. Note: the bits are those of an FMA-capable x86-64 with glibc 2.43; a C build on
  a CPU without FMA, or an older glibc, differs in rare last bits -- that machine is our reference.
- **M4-SPAWN:** engine/model_shared.luau: model registry (Mod_Init, Mod_UnloadModel, Mod_LoadModel,
  Mod_ClearUsed, Mod_PurgeUnused, Mod_FindName, Mod_ForName, Mod_Reload, Mem_ExpandableArray slots);
  model_brush submodels go through Mod_FindName. engine/sv_main.luau: SV_ModelIndex, SV_SpawnServer
  (entry: sv_main.SV_SpawnServer(mapname), compiled QC through sv_main.vm_setup_opts). engine/svvm_cmds.luau:
  setmodel #3, precache_model #20, setmodelindex #333, modelnameforindex #334, VM_CustomStats_Clear.
  engine/host_cmd.luau: Host_Map_f (`map <name>`). engine/server.luau: server.Clear(), CStrRef, more fields.
- **Compiled QuakeC on the owner's PC:** `python tools/qcaot/compile.py work/vfs-high/progs.dat
  game/generated/progs` (3 s, 13,042 functions, 37 MB, not in git; .styluaignore added for game/generated).
  The server integration tests now run here instead of skipping.
- tests/integration/sv_spawnserver.test.luau (60 checks): stormkeep and space-elevator spawn with the real
  QC: stormkeep 4,052 live edicts, 38 submodels resolved, 11 brush entities with the C setmodel boxes, 88
  triggers, 311 models / 434 sounds precached, 13 of 13 spawn points land, 100 SV_Physics frames run.
  **The first init frame stops on a QC error** (WarpZone init needs getsurface*, #434-437, still stubs).
  Stubs hit: #277 frameduration, #437 getsurfacetexture, #451 gettagindex, #443 setattachment, #513 uri_get,
  #52 WriteByte, #54 WriteShort.
- Alias / sprite model loaders (md3, iqm, dpm, zym, psk, spr, obj) are NOT YET PORTED: such models keep the
  +-16 box Mod_LoadModel sets before the loader call (as the C does for an unrecognised file), so setmodel on
  them gives a wrong box until the loaders exist (sv_gameplayfix_setmodelrealbox). Biggest gameplay risk.
- tests/integration/sv_loadentities.test.luau fails now that it runs (it loads entities without
  SV_SpawnServer: no area grid; expects stale custom stats): rebase it and sv_config_worldspawn onto
  SV_SpawnServer.
- Not checked against the C build: the registry, SV_SpawnServer, the new builtins.

## Part 5 (2026-11-27): alias / sprite models, surface + message builtins, QC init completes
- PR 14 merged. Branch M4-SPAWN-init, two Opus sub-agents.
- **M4-ALIAS:** engine/model_alias.luau (model_alias.c: skeletal helpers, tag functions, bounding boxes,
  trace functions, skins; loaders mdl, md2, md3, zym, dpm, iqm) and engine/model_sprite.luau (spr, sp2);
  model_shared.luau: Mod_FrameGroupify + parser, Mod_BuildTriangleNeighbors, Mod_ValidateElements,
  Mod_BuildNormals, Mod_LoadSkinFiles / FreeSkinFiles / CountSkinFiles, dispatch hooks; matrixlib.luau: 13 more
  functions (bone poses, quaternions, Normalize3 ...). Census of work/vfs-high by magic: md3 273, iqm 152,
  dpm 52, spr 41, obj 31, bsp 31, mdl 13, sp2 3, zym 2, psk 0, md2 0.
  Check A: tests/integration/model_alias.test.luau, all 536 models load, 12,685 checks against the independent
  decoder tools/testgen/models_vectors.py (tests/vectors/models.tsv). Check B: C build on fixture models
  (tools/testgen/make_model_fixtures.py, alias_vectors.{c,sh}, tests/fixtures/models, tests/vectors/alias.tsv,
  tests/unit/model_alias_ref.test.luau): 1,101 lines identical. Open: Mod_PSKMODEL_Load (no release file),
  the SSE skeletal path (the release uses it on x86; the generic path is ported and equal on the fixtures),
  the OBJ loader (model_brush.c, 31 files), raw MDL normals (m_bytenormals literals) not in the C vectors.
- engine/prvm_cmds.luau: getsurface* (#434-439, #486, #628, #629) with getmodel / animatemodel / getmatrix /
  applytransform_* / clippointtosurface, VM_uri_get (the no-libcurl path); Matrix4x4_Invert_Full and
  Matrix4x4_Transform3x3 are local there for now (move to matrixlib.luau). animatemodel's animated-mesh path
  uses the base arrays (NOT YET PORTED, logged). engine/svvm_cmds.luau: WriteDest + Write* (#52-59, #456),
  WritePicture #501, setattachment #443, setpause #531, SV_GetEntityMatrix, SV_GetTagIndex, gettagindex #451,
  frameforname #276, frameduration #277. MSG_ONE has no netconnection yet ("non-client" branch).
- **The QC init frames now complete** on stormkeep and space-elevator; 300 SV_Physics frames run (sv.state
  ss_active; stormkeep 4,050 live edicts, space-elevator 4,222). tests/unit/getsurface.test.luau 1,899 checks.
- The three older server integration tests were rebased onto SV_SpawnServer (stopped at its
  PRVM_ED_LoadFromFile call) and made order-independent: fixed srand, pinned Sys_DirtyTime and the new
  prvm_cmds.time() hook (worldspawn formats strftime / gettime values, which shifted temp-string offsets).
- Not checked against the C build: registry, SV_SpawnServer, getsurface*, Write*, the tag / frame builtins.

## Part 6 (2026-11-27): M4-CLIENT -- a bot match runs
- PR 15 merged. M4-CLIENT claimed on main. Branch M4-CLIENT-bots, one Opus sub-agent (interrupted by an app
  restart, resumed from its transcript).
- engine/sv_main.luau: SV_ConnectClient, SV_StartSound / SV_StartPointSound / SV_StartParticle /
  SV_StartEffect (in sv_main.c in 0.8.6), SV_CleanupEnts, SV_FlushBroadcastMessages,
  SV_UpdateToReliableMessages, SV_SendClientMessages, SV_ParticleEffectIndex, SV_SaveSpawnparms, client_t.
  engine/host.luau: SV_ClientPrint(f), SV_BroadcastPrint(f), Host_ClientCommands, SV_DropClient, and
  **host.Host_Main_Frame(elapsed)** = one iteration of Host_Main on a dedicated server (what the Roblox server
  will call from Heartbeat). engine/sv_user.luau (new): SV_ClientThink, SV_ApplyClientMove.
  engine/prvm_cmds.luau: VM_GenerateFrameGroupBlend, VM_FrameBlendFromFrameGroupBlend, VM_UpdateEdictSkeleton,
  VM_RemoveEdictSkeleton (sv_phys.luau now passes the real frameblend / skeleton). engine/svvm_cmds.luau:
  sprint, centerprint, particle, sound, pointsound, checkpvs, stuffcmd, setspawnparms, setcolor,
  clientcommand, gettaginfo, dropclient, spawnclient, clienttype, particleeffectnum, trailparticles,
  pointparticles. engine/model_brush.luau: Mod_Q1BSP_BoxTouchingPVS, Mod_Q1BSP_GetPVS.
- **tests/integration/sv_botmatch.test.luau:** `map stormkeep`, 4 bots (serverbench.cfg cvars,
  sv_random_seed 12345), 3,000 host frames at sys_ticrate: no QC error, no engine error, no builtin hit as
  a stub. Bots travel about 27,000-31,000 units each, 0 of 1,137 position checks in solid or outside the
  world, kills and deaths happen, 1,210 entities spawned / 1,469 removed. BOTMATCH_FRAMES overrides the count.
- Speed: 18.4 ms per frame on average (median 14.6, one unexplained 1 s spike) for 4 bots on stormkeep in
  Lune. Before: 113 ms, because Lune resolves the path on every require() call inside hot functions
  (G-059): modules are now required once on first use. Now QC dominates (StartFrame 4.5 ms, EndFrame 2.5,
  PlayerPreThink 1.9, SV_PlayerPhysics 1.2), then the SV_Physics_Entity loop over ~4,200 edicts (3 ms).
- Fix: VM_SV_ambientsound rounds the float products before the int cast (svvm_cmds.c L502-503).
- All C reference tests still pass (sv_phys_ref, sv_phys_movers_ref, sv_move_ref ...). Not checked against
  the C build: the client / host-frame code and the new builtins; the bot match itself has no C reference
  (M4's goal "bot match frame-diff" needs REF-DP: the same seed in the real engine, edict states per frame).

## Next step
1. A first picture in Studio (M5): the loaded map + entity models drawn in Roblox from the running server
   state (Rojo sync of engine/ + platform/, a platform VFS provider and host loop on Heartbeat). Needs
   M1-RTVFS (game data inside Roblox), the mesh route (EditableMesh, G-021) and texture_assets.luau.
2. Networking (M6): netconn / protocol so a real player's client connects (SV_SendServerinfo,
   SV_WriteEntitiesToClient, csqc entities), then cl_* and CSQC for the client side.
3. Bot match frame-diff against the real engine (REF-DP) once a reference DarkPlaces run is available.
4. C reference for the registry / SV_SpawnServer / getsurface* / Write* / client code where feasible;
   Mod_PSKMODEL_Load, SSE skeletal path, OBJ loader, lightmaps; frame-time work (QC AOT speed, edict loop).
