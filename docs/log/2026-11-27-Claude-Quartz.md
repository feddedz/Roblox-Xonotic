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

---

# Part 2 — M6-SEND (same day)

## Goal
What the server sends to a real client: the entity-frame encoders of protocol.c and the send side of sv_main.c.

## Done
- **engine/protocol.luau** (Helper P): protocol table, defaultstate / entity_state_t, CSQC entity frames
  (EntityFrameCSQC_*), stats (Protocol_UpdateClientStats, Protocol_WriteStatsReliable), DP5+ entity frames
  (EntityFrame5_AllocDatabase .. EntityFrame5_WriteFrame, EntityState5_WriteUpdate / DeltaBits / Priority).
  C reference `tools/testgen/protocol_vectors.c` → `tests/vectors/protocol.tsv` (9.5 MB, equal to the Testgen
  artifact by hash): 7,747 checks, all identical. NOT YET PORTED (logged): EntityFrameQuake_WriteFrame,
  EntityState_Write*, EntityFrame_* (DP1-3), EntityFrame4_* write sides; all client readers.
- **engine/sv_main.luau** (Helper Q): SV_SendServerinfo, SV_PrepareEntityForSending / EntitiesForSending,
  SV_CanSeeBox, SV_MarkWriteEntityStateToClient, SV_AddCameraEyes, SV_WriteEntitiesToClient,
  SV_WriteClientdataToMessage, SV_WriteUnreliableMessages, SV_SendClientDatagram, SV_Prepare_CSQC; csqc upkeep
  in SVVM_free_edict. host_cmd.luau: Host_PreSpawn_f / Host_Spawn_f / Host_Begin_f as
  `host_cmd.CLIENTCOMMANDS` (nothing calls them yet: SV_ReadClientMessage is not ported).
- NetConn is a hook table: `sv_main.netconn = { NetConn_CanSend, NetConn_SendUnreliableMessage }`,
  `sv_main.lhnet = { LHNETADDRESS_GetAddressType }` (nil = logged once; msg.data is reused every frame).
- **Fake client on the stormkeep bot match** (tests/integration/sv_send_client.test.luau): serverinfo
  (protocol 3504, 311 models, 434 sounds, csqc progs info) as a 21,762-byte reliable message, prespawn /
  spawn / begin run, then a datagram every frame for 200 frames: max 1,399 bytes (limit 1,400), average 135;
  per frame ~196 send entities, ~121 visible, 4 entity states + ~117 csqc entities to the encoders.
- C quirks kept (list in the helpers' reports): qsort with swapped count / size in EntityFrame5_LostFrame
  (no-op), csqcentityversion as unsigned char, RENDER_LOWPRECISION against the previous client's entity
  number, SV_AddCameraEyes off-by-one, host_client->ping where client->ping is meant.

## Files changed
engine/protocol.luau (new), engine/sv_main.luau, engine/server.luau, engine/host_cmd.luau,
tools/testgen/protocol_vectors.{c,sh}, .github/workflows/testgen.yml, tests/vectors/protocol.tsv,
tests/unit/{protocol_ref,sv_send}.test.luau, tests/integration/sv_send_client.test.luau.

## Tests run and results
- unit folder: 28 files, 0 failed (protocol_ref 7,747; sv_send 89). sv_send_client 42 checks, sv_botmatch
  (600 frames) 13 checks, sv_spawnserver pass. stylua / selene clean, check_port_lines 0 wrong.
- sv_botmatch with BOTMATCH_FRAMES below ~450 fails "every bot moves" (warmup): use 600 or more.

## Problems / dead ends
- Not checked against C: the send side of sv_main.c (next: a Testgen generator around sv_main.c, as for
  sv_phys.c). Custom stats (VM_SV_UpdateCustomStats) are not filled in: the HUD needs them.
- No PVS culling yet (Mod_Q1BSP_FatPVS, FindBoxClusters); progs crc sent as 0 (prog->filecrc).

## Next step
1. netconn.c on RemoteEvents (platform/net) + SV_ReadClientMessage / SV_ExecuteClientMoves (sv_user.c), so a
   connection can sign on and move by packets; VM_SV_UpdateCustomStats, FatPVS, filecrc, SV_SetIdealPitch.
2. C reference for the send side. 3. Client: cl_parse.c + cl_ents*.c readers, CSQC VM (csprogs.c,
   clvm_cmds.c), then the renderer.