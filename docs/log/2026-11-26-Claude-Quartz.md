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

## Next step
1. C reference for the movers and sv_move: extend tools/testgen/svphys_vectors.c (it already has the prog,
   the map and an ExecuteProgram stub) to run SV_Physics frames, SV_FlyMove, SV_PushMove, SV_Physics_Toss /
   Step, SV_WalkMove, SV_movestep, SV_NewChaseDir on scripted entities and print every edict field after each
   call; the builtins (static in svvm_cmds.c) need a generator that includes svvm_cmds.c.
2. Still stubs: setmodel #3 (Mod_ForName / model registry), checkclient / checkpvs / aim (PVS), SV_StartSound,
   SV_ClientThink (sv_user.c).
3. SV_SpawnServer (sv_main.c): worldmodel, sv.models, World_SetSize, then the stormkeep entity load of
   M2-RUNNER with real traces, then the host frame loop calling SV_Physics.
4. Mod_Q3BSP_LoadLightmaps, tokenizer speed, BIH leaf memory, cached field offsets in sv_phys / builtins.
