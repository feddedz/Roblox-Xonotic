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

## Next step
1. C reference for sv_phys.luau + the world builtins: a generator that builds a prog with the entity fields by
   hand (like tools/testgen/world_vectors.c does for the area grid) and runs the real SV_TraceBox / SV_LinkEdict
   on the synthetic map of trace_vectors.c.
2. Still stubs: tracetoss #64 (SV_Trace_Toss, SV_CheckVelocity), walkmove #32 (sv_move.c SV_movestep),
   checkbottom #40 (SV_CheckBottom), setmodel #3 (Mod_ForName / model registry), checkclient / checkpvs / aim (PVS).
3. Then M4: sv_phys.c movers (SV_FlyMove, SV_PushMove, SV_Physics_*), sv_move.c, SV_SpawnServer filling
   sv.worldmodel / sv.models / World_SetSize, so the stormkeep entity load of M2-RUNNER runs with real traces.
4. Mod_Q3BSP_LoadLightmaps, tokenizer speed, BIH leaf memory layout (see 2026-11-25 log).
