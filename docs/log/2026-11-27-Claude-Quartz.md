# 2026-11-27 Claude-Quartz — STUDIO-BOTMATCH

## Goal
Run the stormkeep bot match (M4-CLIENT) inside Roblox Studio and look at it: first time the ported server
runs in the real Roblox Luau VM, first picture of it.

## Done
- **Packer:** `tools/pk3/pack_runtime.py --also LISTFILE` packs extra files next to the default set (output
  without the option is byte-identical to before). `tools/studio/list_botmatch_files.luau` records what the
  match reads: 756 files, 102.8 MB (496 models, 186 shader scripts, 34 map files; biggest: progs.dat 6.7 MB,
  spider.dpm 4.8, stormkeep.bsp 4.2). Packed: 1,125 files, 141 MB in 1,461 modules.
- **tools/studio/botmatch/BotMatch.luau** (Helper N): boot + frame stepping with dependencies passed in, so
  the same file runs under Lune and as a ModuleScript. Boot is time-sliced: the provider's load, the console
  sink, the QC chunk loader and `model_alias.Mod_Skeletal_AnimateVertices_Generic` (wrapped through the
  module table, no engine edit) call `yield` every ~0.5 s. Longest stretch without a yield point: ~1 s
  (was 12.4 s in Mod_Alias_CalculateBoundingBox of spider.dpm before the wrap).
- **Packed = disk:** two Lune runs (seed 12345, QC time() pinned), 1,500 frames, bot origins every 50
  frames: identical. `tests/integration/sv_botmatch_packed.test.luau` boots from the packed data (skips
  without it).
- **tools/studio/botmatch/ServerView.luau + Run.luau** (debug view, NOT the renderer): sv.worldmodel's
  surfaces as textured MeshParts (EditableMesh), brush-model entities as their surfaces, every other edict
  with a model as its bounding box, players with name + health; chase camera; flat ambient light.
- **In Studio** (`studio-botmatch.project.json` → 84 MB .rbxl, opened as a local file, edit mode,
  `require(game.ReplicatedStorage.BotMatch.Run).start()`): boot 95.5 s, map 37,638 triangles in 47 parts,
  all 47 with their texture; 3,390+ frames without an error, 4 bots moving, taking damage and picking up
  items; server frame + view 4-15 ms; Luau heap 1.96 GB (G-060). Screenshots: work/studio/botmatch_*.jpg.

## Files changed
tools/pk3/pack_runtime.py, tools/studio/list_botmatch_files.luau, tools/studio/botmatch/{BotMatch,ServerView,
Run}.luau, tests/integration/sv_botmatch_packed.test.luau, studio-botmatch.project.json, HANDOFF.md,
docs/log/.

## Tests run and results
- `lune run tests/run.luau sv_botmatch_packed`: PASS, 9 checks (Helper N; 600 frames, 144 yields).
- stylua / selene clean (engine platform tests game tools/studio). No engine file changed.
- Studio run as above (manual, through the Studio MCP).

## Diffs added or closed
None (debug tools only).

## Decisions
- The view runs in Studio **edit mode** (EditableMesh, Heartbeat and screen capture all work there); a
  server-made EditableMesh does not replicate to clients, so the real renderer must build meshes client-side.
- The match's files go into the place as base64 modules for now. This is a test rig: the game needs
  M1-RTVFS proper (models / maps as assets or a compact store), 141 MB of modules and a 1.96 GB heap are
  not shippable.

## Problems / dead ends
- An MCP `execute_luau` call that waits ~100 s times out; poll in calls of ≤ 25 s.
- Without flat ambient light the unlit map is nearly black (its light is in the lightmaps, not drawn here).
- game/generated/progs has CRLF line endings on Windows: c114.luau is 200,239 bytes on disk, but Studio
  counts 0 of 215 chunk modules over 199,999 characters (Rojo normalises line endings).

## Next step
1. M6 / M5 proper: netconn + protocol (SV_SendServerinfo, SV_WriteEntitiesToClient, csqc entities), then the
   client (cl_*, CSQC) and renderer ports, so a player joins and sees models, lightmaps and effects.
2. M1-RTVFS proper (memory: do not hold base64 and decoded copies; drop files after load).
3. Boot time in Roblox (95 s): skeletal bounding boxes of monster models dominate; QC chunk loading.
4. REF-DP bot-match frame-diff; C references for registry / SV_SpawnServer / client code.
