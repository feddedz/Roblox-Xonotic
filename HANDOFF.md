# HANDOFF — Xonotic → Roblox one-to-one port

Single source of project state (project overview for people: `WELCOME.md`). **Do not read this whole file.** Print one section with
`tools/handoff.sh STATUS` (or find its unique marker line `<!-- §NAME -->`; it ends at `<!-- /§NAME -->`).
Every section except §MAP and §DIFFS stays under ~60 lines; detail lives in `docs/subsystems/`.

| Section | Contents |
|---|---|
| §STATUS | ≤15 lines: milestone, works, broken, FPS / tick time, next step. Rewritten each session. |
| §RULES | The project rules (condensed owner brief). Absolute. |
| §TASKS | Task board: ID, title, status, files, deps. |
| §MAP | Every DarkPlaces C file + platform backend: role, module, status, tests. |
| §DIFFS | Every remaining difference from real Xonotic. Not listed = not allowed. |
| §DECISIONS | Numbered, dated decisions. Never contradict; supersede with a new one. |
| §QUESTIONS | Open questions for the owner (+ the faithful default taken meanwhile). |
| §GOTCHAS | Verified limits (with date) and hard-won lessons. |

<!-- §STATUS -->
## §STATUS (rewritten 2026-11-25, Claude-Quartz)
- **Owner's account: clear** after a child-safety ban (2026-11-22) over textures/cp_glow.jpg (letters "CP" =
  Control Point; appeal granted, G-051). **Any further upload: only reviewed files, gated in batches of 100
  (tools/upload/run_unattended.ps1 / .sh), with the owner's OK.** Key on the owner's PC: tools/upload/set_key.ps1.
- **Textures: done.** All 13,676 texture files (10,905 assets) have an Approved asset. Three review rounds made
  Roblox-safe versions (DIFF-008, DIFF-009, DIFF-010): gore_fix/content_fix (fixed, fixed2), content_fix3
  (UPLOAD-FIX3: 124 fixed, 153 kept), content_fix4 (UPLOAD-FIX4: 43 of the pre-ban flagged images fixed incl. the
  CP sign, 70 kept; reasons in assets/manifest/review/content_{fixes,kept}{3,4}.tsv). Owner approved both sheets.
- **THE LOOKUP THE GAME MUST USE: platform/render/texture_assets.luau** (5 data parts; vpath → current asset id)
  = assets/manifest/texture-assets.tsv, written by tools/upload/asset_index.py --write (re-run after every
  upload; tools/upload/test_asset_index.py fails if it is stale). Never read ids from roblox-images.tsv directly:
  it is an upload log that also holds the old, replaced uploads. Sounds: platform/sound/audio_assets.luau.
- **Sounds:** 804 of 805 Approved; sound/cdtracks/heavymetal.ogg Rejected (Q-013: owner appeals or decides).
- **Old uploads:** 16 old rejected sound uploads archived by API (assets/manifest/roblox-archived.tsv). Images
  cannot be archived by Open Cloud (G-052); 68 unused old images stay on the account (assets/manifest/
  archive-now.tsv: old CP set, blood decal, ...; none is used by the game; owner chose to leave them).
  State of every asset: tools/upload/check_assets.py → assets/manifest/roblox-assets-state.tsv.
- **2026-11-27: the server runs a bot match, also inside Roblox Studio** (M4-CLIENT; STUDIO-BOTMATCH, G-060:
  `rojo build studio-botmatch.project.json`, then `require(game.ReplicatedStorage.BotMatch.Run).start()` shows
  stormkeep + bots as boxes; a debug view, not the renderer). Next: networking (M6), client + renderer (M5).
- **M2-RUNNER done** (stormkeep entities load, first StartFrame spawns them; world builtins wait on M3).
  ~170 builtins ported; server state (engine/server.luau), SZ/MSG writes, mathlib bit-exact.
- **M2-AOT-SHIP (claimed, Claude-Anvil):** lazy chunk loading + background preload; Q-014 (startup 17.7 s).
- **Tests:** 37 Lune files, all pass (with game data and the locally compiled QuakeC); StyLua/Selene clean; check_port_lines 0 wrong.
- **Stale claims:** M3-BSPLOAD and REF-DP branches have only claim commits from 2026-11-20 — owner to reassign.
- **Local + Studio (2026-11-25):** the owner cannot use cloud sessions; work happens on the owner's Windows PC.
  Toolchain there: `rokit install` (shims in %USERPROFILE%/.rokit/bin; stylua, selene, lune 14/14, rojo pass).
  Roblox Studio is reachable from the session through the Studio MCP tools (run Luau, playtest, screenshots), so
  **[needs Studio] tasks can be done now.** Experience **"Xonotic"** on the owner's account: placeId
  130462204737495, universeId 10779065323 (private; built with `rojo build default.project.json`, Team Create
  on, AI data sharing off). Never touch the owner's other places (e.g. "walled in").
- **M3-BSPLOAD (claimed, Claude-Quartz):** ported and checked against the release's C code compiled
  unchanged: bih.c, curves.c (complete), polygon.c (PolygonD_*), collision.c (brush builder, triangle brushes,
  Collision_BrushForBox, every brush / line / point trace against brushes and triangle meshes), model_shared.c
  mesh helpers, matrixlib.c (4 functions). model_brush.c: the Q3 BSP loader (all lumps except lightmaps,
  collision + render BIH, submodels; 30 stock maps match an independent decoder, q3bsp_load 84,795 checks) and
  **all Q3BSP trace functions** (Mod_CollisionBIH_* and the BSP-tree path Mod_Q3BSP_Trace*, PointSuperContents,
  TraceLineOfSight) and Collision_ClipTo* / Collision_CombineTraces / Collision_ClipTrace_Box+Point with the
  entity-matrix helpers of matrixlib.c: tests/unit/trace.test.luau = 8,685 checks bit-identical to the C build on a synthetic map
  (tools/testgen/trace_vectors.c includes model_brush.c to reach its statics); tests/integration/
  q3bsp_trace.test.luau on stock maps (BIH = plain loop over all leafs, 77/77 spawn points land). The loader
  sets mod.TraceBox / TraceBrush / TraceLine / TracePoint / PointSuperContents / TraceLineAgainstSurfaces /
  brush.TraceLineOfSight. Trace cvars are bound by collision.Collision_Init / model_brush.Mod_BrushInit
  (host.luau calls both). Q3 shader scripts: Mod_LoadQ3Shaders / Mod_LookupQ3Shader and
  Mod_LoadTextureFromQ3Shader ported (all 2,447 release shaders agree with tools/shaders/parse.py; map textures
  get basematerialflags, shader passes, skybox name; load maps with the VFS provider set; checked against the C
  build with fixture shaders: tests/unit/q3shaders_ref.test.luau, 4,363 checks). **Next in this task:** lightmaps,
  the model registry; then M3-TRACE (world.c area grid, sv_phys.c SV_Trace*, the world builtins). C
  reference vectors: push tools/testgen/*_vectors.{c,sh} -> the Testgen workflow builds them on GitHub (no C
  compiler on the owner's PC, G-054) -> `gh run download`.
- **M3-TRACE (claimed, Claude-Quartz):** engine/world.luau (area grid) and the trace / link part of
  engine/sv_phys.luau (SV_TracePoint / Line / Box, SV_LinkEdict + touch calls, SV_EntitiesInBox,
  SV_PointSuperContents, SV_NudgeOutOfSolid) are **bit-identical to the C build** (world 745 checks,
  sv_phys_ref 2,524 checks on a synthetic map). Open: the stock-map reference (M3-TRACEREF / REF-DP).
- **M4-PHYS done:** all of sv_phys.c and sv_move.c + the world builtins, bit-identical to the C build on
  synthetic maps (sv_phys_movers_ref 13,678 checks, sv_move_ref 50,400).
- **PORT-LIBM done:** engine/_port/libm.luau = glibc 2.43 (FMA build) sin / cos / tan / asin / acos / atan /
  atan2 / pow / log in pure Luau, 36,631 vectors identical; no host math.* transcendental call is left in
  engine/ -- **never call math.sin / cos / ... or `^` in engine code, use libm** (G-058).
- **M4-SPAWN / M4-CLIENT: a bot match runs.** `map stormkeep` with 4 bots runs 3,000 host frames through
  host.Host_Main_Frame with the compiled QuakeC: no QC error, no builtin hit as a stub, bots move and fight
  (tests/integration/sv_botmatch.test.luau; compile the QC locally: `python tools/qcaot/compile.py
  work/vfs-high/progs.dat game/generated/progs`). About 18 ms per frame in Lune. Client slots exist only for
  bots (no netconnection: M6-NET). Not checked against the C build (needs REF-DP for a frame-diff).
  Next: first picture in Studio (M5) / networking (M6). Log: docs/log/2026-11-26-Claude-Quartz.md (part 6).
- **M4-ALIAS done (except PSK, SSE path, OBJ):** engine/model_alias.luau + engine/model_sprite.luau load all
  536 alias / sprite models of the release (independent decoder: 12,685 checks; C build on fixture models:
  1,101 lines identical). Log: docs/log/2026-11-26-Claude-Quartz.md (part 5).
- **Branches (2026-11-25):** PRs 1, 2, 3 merged into main: start every new branch from main (D-012). Owner
  decided NOT to archive the 68 old images (archive-now.tsv is only a list).
- **Next:** owner: heavymetal.ogg appeal (optional); M1-TEX / M5-RENDER use texture_assets.luau;
  M3-BSPLOAD (if reassigned) → world builtins.

## §RULES (condensed from the owner's brief; absolute)

**Goal.** Xonotic on Roblox one-to-one: no difference in gameplay or visuals (code, assets, engine
behaviour, hitboxes, movement, weapon numbers, timings, look). Nothing simplified, "Roblox-ified",
rebalanced or removed. Anything unavoidable goes in §DIFFS with justification, never silently. "Easier",
"Roblox players prefer", "close enough", "probably fine" are never reasons.

**Fixed decisions (owner; do not revisit).**
1. Match the latest stable release exactly (pinned in D-001). Never mix code/assets from master or other versions.
2. DarkPlaces is hand-ported to Luau line by line: one module per C file, same file/function/variable names,
   same order of operations; each function has `-- port: <file>.c <Function> L<a>-<b> @xonotic-v0.8.6`.
   Only OS-facing parts (OpenGL, sound mixer/output, sockets, filesystem, window/input) are replaced, in
   `platform/`. CPU simulations (particles, dlights, decals, beams, view bob/kick, viewmodel) are ported
   and Roblox only displays their result.
3. QuakeC runs unchanged: release `progs.dat`/`csprogs.dat`/`menu.dat` compiled ahead of time to Luau
   (one function per QC function, flat typed storage, `buffer` where useful). Never hand-rewrite gameplay.
   `qcsrc` is reference + debug symbols only.
4. Float32 exactness: everywhere C stores/computes a 32-bit float, round to f32 exactly like C (D-004).
   When in doubt, round. Differential tests decide.
5. Visual fidelity first; FPS only needs to stay playable (report FPS in §STATUS; if fidelity makes it
   unplayable, ask in §QUESTIONS — never cut fidelity yourself). Reference look = Ultra preset (D-009).
   Main renderer = Roblox 3D pushed to max; a software renderer may exist only as a comparison mode.
6. GitHub + Rojo; owner tests in Studio; sessions test headless with Lune; Selene + StyLua.
7. GPLv3+, public repo; menu gets a small "Credits & License" entry (repo link, GPL text, Team Xonotic and
   asset authors). Keep all original copyright notices in ported files.

**Visual fidelity (close every gap; log only what remains after real effort, verified against current docs).**
Exact geometry/models/animations/skins (EditableMesh/MeshParts/bones; split meshes, never simplify).
Never downscale textures: tile over meshes/UV regions beyond Roblox's max size (incl. skies). Bake
lightmaps/deluxemaps at full res; highest lighting tech with shadows; every light entity and dlight as a
Roblox light matched in radius/colour/intensity/falloff/timing; neutralise Roblox ambient/sky/atmosphere.
Normal maps via SurfaceAppearance; gloss/specular → roughness/metalness calibrated by screenshots; glow
maps glow. Parse every Q3 shader; implement every stage (tcMod, animMap, rgbGen/alphaGen, deformVertexes,
blend modes, env/reflection, sky, fog); keep `docs/shaders.md` status table (exact/close/approximate).
Ported particle sim (effectinfo.txt) drawn with pooled quads/Beams/EditableMesh, matching texture, size,
colour, alpha, additive blend, stretch, orientation; same for decals, beams, trails, explosions.
Camera: exact DarkPlaces projection (horizontal FOV on 4:3 basis → Roblox vertical FOV per aspect), near
plane, viewmodel FOV/depth, bob, roll, kick, zoom. Post: bloom, HDR, gamma, contrast, saturation, damage
flash, powerup tints, underwater. Best texture filtering; detect graphics quality and prompt for max;
log every uncontrollable setting. Screenshot comparison: fixed cameras on every stock map + effect scenes;
references from real Xonotic at Ultra; diff tool highlights worst regions; a visual task is done when the
owner confirms, or the residual is in §DIFFS as impossible with what was tried.

**Allowed differences (complete list; each still logged in §DIFFS with how it was done).**
Accounts/names from Roblox (colour codes only if they pass text filtering; bots keep Xonotic names).
Persistence to DataStores per player instead of disk, same behaviour to the player. Chat through
TextChatService filtering, otherwise identical. Networking transport: Roblox servers only (no browser for
external servers, no IP connect, no external hosting); server list/create-server/voting rebuilt to look
and behave like the original; DarkPlaces message protocol kept byte-exact, only transport changes to
RemoteEvents (UnreliableRemoteEvent where DP is unreliable). Proven-impossible platform limits, only
after every technique was tried (log tries + closeness); settings may hide options that control nothing,
if logged. Roblox policy requirements — **never change content for policy on your own**: put the exact
guideline in §QUESTIONS and wait. **Owner-approved planned differences (D-018; do not build until the
owner defines them, Q-009):** own controls for console (gamepad) and mobile (touch) players with *slight*
gameplay assists for those inputs only; game passes, much later. Keyboard-and-mouse gameplay stays exactly Xonotic.

**Performance.** Server tick keeps up with Xonotic's tick rate (D-005): non-negotiable. Client playable,
fidelity first: `--!native`/`--!strict` where they help (verify codegen), no hot-path allocations, `buffer`
storage, Parallel Luau only where it measurably helps without changing results. Every optimisation passes
the same differential and screenshot tests as the code it replaces.

**Differential testing: done = matches the reference on recorded data.** Collision: thousands of
traceline/tracebox per stock map from real DarkPlaces, bit-identical (tolerances justified in writing).
Physics: frame-by-frame entity diffs from scripted inputs/demos/bot matches. Network: byte-compare.
Particles: diff sim state vs instrumented DP. Visuals: screenshot process. Data or regeneration scripts in
`tests/reference/`; instrumented DP in `tools/`. Can't fetch something? Tell the owner exactly what/where.
**Protocol:** `CLAUDE.md` (start, claim, work, log, finish; stubs log `NOT YET PORTED: <name>`).
<!-- /§RULES -->

<!-- §TASKS -->
## §TASKS

Status: `open` · `claimed by <session> <date>` · `done` · `blocked (<why>)`. **[needs Studio]** = can only be
checked in Roblox Studio (available on the owner's PC since 2026-11-25, see STATUS). Claim = edit + commit + push
before working. One claimed task per subsystem at a time. Details per task in the linked subsystem doc.

| ID | Title | Status | Files | Deps |
|---|---|---|---|---|
| M0-SETUP | Layout, CLAUDE.md, HANDOFF.md, Rojo, Lune runner, lint/format, CI, README | done | * | — |
| M0-F32 | float32 approach + verified helper | done | engine/_port/f32.luau, tests/unit/f32* | — |
| M0-PIN | Version pin + checksums + tick rate | done | §DECISIONS, tools/release/ | — |
| M1-VFS | pk3 VFS resolution (fs.c order) + manifests for both builds | done | tools/pk3/, assets/manifest/ | M0-PIN |
| M1-SHADERS | Parse every shader script → structured table + docs/shaders.md | done | tools/shaders/, assets/data/shaders.json | M1-VFS |
| M1-RTVFS | (partial 2026-11-21: configs + progs.dat packed by tools/pk3/pack_runtime.py → game/generated/vfs, server provider; Claude-Anvil) Runtime VFS on Roblox: ship engine-read files (bsp, cfg, txt, shader, progs data) as Rojo-syncable chunks; verify script/string size limits | open | tools/pk3/, platform/storage, engine/fs.luau | M1-VFS |
| M1-TEX | Texture converter: jpg/tga/png + `_alpha` merge exactly as image.c; tile > max size; never downscale | open | tools/textures/ | M1-VFS, Q-002 |
| M1-LMAP | Lightmap + deluxemap extraction from Q3 BSP at full res | open | tools/bsp/ | M1-VFS |
| M1-BSP | Q3 BSP → render meshes (split ≤20k tris/≤60k verts), per-surface material refs | open | tools/bsp/ | M1-VFS |
| M1-MODELS | MD3/IQM/DPM/ZYM/OBJ/ASE/SP2 → meshes, skins, animations (framegroups) | open | tools/models/ | M1-VFS |
| M1-SOUNDS | Sound pipeline: uploader for assets/manifest/audio-plan.tsv (rate, loop points, packs already planned: docs/subsystems/audio.md), fill asset_id, runtime vpath→asset lookup | partial (Claude-Anvil 2026-11-21): all 805 unique sounds uploaded (user-owned), ids in assets/manifest/roblox-audio.tsv, runtime table platform/sound/audio_assets.luau (851 vpaths); open: 13 rejected by moderation (Q-013), 36 still in review (re-run tools/sounds/check_moderation.py) | tools/sounds/ | M1-VFS |
| M1-UPLOAD | Open Cloud uploader + `assets/manifest/roblox-ids.tsv`; key via env var, never committed | open | tools/upload/ | M1-TEX, Q-004 |
| M2-PROGS | progs.dat reader (all 3 .dat) + CFG/reducibility analysis | done | tools/qcaot/progs.py, cfg.py | M1-VFS |
| M2-INTERP | Straight port of prvm_exec.c + prvm_execprogram.h (reference interpreter for AOT diffing) | done (29 semantic tests) | engine/prvm_exec.luau | M2-PROGS |
| M2-AOT | QC bytecode → Luau AOT compiler (f32 globals/fields in buffers, one Luau fn per QC fn); docs/subsystems/qcvm.md | done v1 (all 25,509 functions == interpreter) |
| M2-AOT-STRUCT | Structured control flow for reducible CFGs (performance only; must pass qcaot_diff unchanged) | open | tools/qcaot/ | M2-AOT |
| CHAT-SETUP | Shared session chat (docs/chat/, one append-only file per UTC day, posted to `main` by tools/chat.sh; D-021) | done (Claude-Anvil 2026-11-21) | — | — |
| ROSTER | Session names Claude-<Word> (WELCOME.md list) + docs/chat/roster.md (name, start, task, status); D-021 | done (Claude-Anvil 2026-11-21) | — | — |
| AUDIO-PLAN | Audio upload plan: one asset per sound; if over the 30-day quota pack short sounds by group with 0.5 s gaps; dedupe by checksum; manifest slices; related: M8-SOUND, M1-SOUNDS; docs/subsystems/audio.md, tools/sounds/audio_plan.py | done (Claude-Anvil 2026-11-21); no packing needed (G-036: 1,970 uploads left ≥ 805) | docs/subsystems/ | — |
| PERF-SVBENCH | **[needs Studio]** Benchmark compiled server QC in a Roblox server with native codegen: SV_Frame cost at 30 Hz, worst case per frame (early answer to "does the tick keep up") | open | tests/studio/, game/generated/ | M2-RUNNER |
| CONTROLS-ASSIST | Console/mobile controls + assists (DIFF-002) | blocked (Q-009) | platform/input | Q-009 |
| GAMEPASSES | Game passes (DIFF-003) | blocked (Q-009), much later | — | Q-009 |
| M2-AOT-SHIP | Ship generated code: build step + Rojo mapping + 190k-char modules done (D-020); **[needs Studio]** confirm rojo serve/publish with 380 modules, client load time + memory | partial, claimed by Claude-Anvil 2026-11-22 (lazy chunk loading: AOT install takes 17.7 s headless) | tools/qcaot/, game/generated/ | M2-AOT |
| M2-INTERP-DEBUG | Port tracing/profiling/coverage/watchpoints of prvm_exec.c (console commands use them) | open | engine/prvm_exec.luau | M2-INTERP | tools/qcaot/, game/generated/ | M2-PROGS |
| M2-RUNNER | Headless runner: rest of PRVM_Prog_Load (required fields/globals of svvm, field lookup), edict alloc, strings, all builtins stubbed + logged; done = server QC runs worldspawn on a stock map | done (Claude-Anvil 2026-11-22: stormkeep entities load, first StartFrame spawns them; world builtins stubbed for M3/M4) | tests/, engine/prvm_*.luau, engine/sv_main.luau, engine/svvm_cmds.luau | M2-AOT, M2-INTERP |
| M2-FSWRITE | Persist files QC writes (fopen append/write, fs.realfiles in engine/fs.luau) across server restarts (Roblox DataStore or similar); in memory today | open | engine/fs.luau, platform/ | M2-RUNNER |
| UPLOAD-FIX3 | Fix the 275 images flagged by the 2026-11-23 strict review (assets/manifest/review/upload_findings_*.tsv) as subtly as possible (D-025): all high+medium, plus low items with names/brands/blood/symbols/ambiguous letters or digits; keep harmless signage; matching _norm/_gloss/_alpha; owner sees before/after; then gated upload (batches of 100, stop on Reviewing > 45 min, Rejected or 403) | done (Claude-Quartz 2026-11-24: 124 fixed, 153 kept, owner approved, 7,634 uploaded in 77 gated batches, all Approved) | tools/upload/, work/upload/fixed3 | — |
| UPLOAD-FIX4 | Same as UPLOAD-FIX3 for the images uploaded before the ban: the 112 flagged live images still in use (assets/manifest/review/live_findings_*.tsv; 13 high incl. textures/cp*.jpg, gfx/blood*.jpg, gfx/leave_em_behind_mini.jpg) + the Rejected gfx/menu/luminos/background_ingame_alpha.jpg. Fix subtly (D-025), keep-list with reasons, owner sees before/after, gated upload (batch 100), then archive the old assets (archive-now.tsv, replace-after-review.tsv + the newly replaced ones). Check with tools/upload/check_assets.py | done (Claude-Quartz 2026-11-25: 43 fixed + uploaded, all Approved; 70 kept; texture_assets.luau; 16 sounds archived; 68 images left for the owner to archive, G-052) | tools/upload/ | UPLOAD-FIX3 |
| M2-DEBUG | Rebuild progs.dat from qcsrc with the pinned gmqcc; prove byte-identical; emit line-number debug info | open | tools/qcaot/ | M2-PROGS |
| REF-CVARLIST | From REF-DP's dedicated server after startup: `cvarlist` (name/value/default/flags) and `cmdlist` → tests/reference/cvars/; diff against engine/host.luau's result (validates tools/engine/gen_cvars.py and the config chain) | open | tests/reference/cvars/, tests/integration/ | REF-DP, M2-RUNNER |
| REF-DP | Instrumented DarkPlaces (from release source) that records traces, server frames, net messages, particles | open | tools/darkplaces-ref/ | M0-PIN |
| M3-BSPLOAD | Port model_brush.c (Q3 BSP), model_shared.c, bih.c, collision.c; headless reads work/vfs-high (Roblox runtime loading needs M1-RTVFS later) | claimed by Claude-Quartz 2026-11-25 (partial: bih, curves, polygon, brush builder, Q3 lump + face loaders done and verified; BIH build + submodels + all Q3BSP traces done and verified; shaders, lightmaps, model registry open; the 2026-11-20 claim on branch M3-BSPLOAD-collision was stale) | engine/ | M1-VFS |
| M3-TRACEREF | Record ≥1000 traceline/tracebox per stock map from REF-DP | open | tests/reference/traces/ | REF-DP |
| M3-TRACE | Port world.c/sv traces; bit-identical vs M3-TRACEREF on all stock maps | claimed by Claude-Quartz 2026-11-25 (world.c area grid, sv_phys.c SV_Trace*, world builtins; M3-TRACEREF / REF-DP are not available on the owner's PC: checked against the C build on synthetic maps through the Testgen workflow instead, the stock-map reference stays open) | engine/ | M3-BSPLOAD, M3-TRACEREF |
| M4-* | Server: sv_phys/sv_main/sv_user/sv_move, prvm_*, svvm_cmds builtins, host loop; bot match frame-diff | open (split when M3 done); part M4-PHYS (sv_phys.c movers, sv_move.c and their builtins) done 2026-11-26; part M4-SPAWN (model registry, setmodel / precache builtins, SV_SpawnServer) and M4-ALIAS (alias / sprite model loaders) done 2026-11-27; part M4-CLIENT (bot / client slots: SV_ConnectClient, SV_DropClient, spawnclient builtins, the server frame loop, a bot match on a stock map) claimed by Claude-Quartz 2026-11-27 | engine/ | M2-RUNNER, M3-TRACE |
| PORT-LIBM | Pure-Luau, glibc-exact sin / cos (+ other libm calls the engine makes) in engine/_port, checked against the runner's glibc via Testgen; switch mathlib / matrixlib / sv_move / svvm_cmds to it (G-058) | done 2026-11-26 (Claude-Quartz) | engine/_port | — |
| M5-* | Client: map render, models, input, CSQC + prediction, camera/viewmodel (CPU logic headless; visual check **[needs Studio]**) | open (split later) | engine/, platform/render, platform/input | M1-*, M4 |
| M6-NET | DarkPlaces message layer on RemoteEvents, fragmentation, byte-match | open; part M6-SEND (protocol.c DP7 entity frames + CSQC entity frames -> engine/protocol.luau with C reference; sv_main.c send side: SV_SendServerinfo, SV_WriteClientdataToMessage, SV_PrepareEntitiesForSending, SV_WriteEntitiesToClient, SV_SendClientDatagram) claimed by Claude-Quartz 2026-11-27 | engine/netconn, platform/net | M4 |
| M7-* | 2D draw builtins, menu.dat, fonts, DataStore persistence, Credits & License entry | open | engine/, platform/ | M2, M5 |
| M8-SOUND | Channels, attenuation, spatialisation, timing | open | engine/snd_main, platform/sound | M1-SOUNDS |
| M9-* | Dlights, shader stages, particles/decals/beams, post-processing (sims headless; screenshot passes **[needs Studio]**) | open | platform/render | M5 |
| TOOL-SHOTDIFF | Screenshot diff tool + camera position list per map + effect scenes | open | tools/shotdiff/, tests/reference/screens/ | — |
| REF-SHOTS | Capture Ultra reference screenshots from real Xonotic 0.8.6-high | open | tests/reference/screens/ | TOOL-SHOTDIFF |
| POLICY-1 | Content-ratings questionnaire (owner, from docs/policy/gentle-mode.md) | deferred by owner (Q-007) | docs/policy/ | — |
| CONTENT-POLICY | Switch module (done) + wiring: locked cvars after config load, VFS placeholders, gore-group loader | partial (module done) | platform/contentpolicy, engine/fs, engine/cvar | M1-RTVFS, M7-* |
| GORE-ASSETS | (partial 2026-11-21: 59 textures in assets/optional/gore/textures.tsv, Claude-Anvil) Classify gore-only assets (gib models+skins, gore sounds, gore-only particle-atlas tiles, stains, damage flash) → `assets/optional/gore/manifest.tsv`; same-name placeholder models/sounds for `removed` (D-019): identical load/precache order and index numbers, no server missing-model error | open | tools/, assets/optional/gore/ | M1-VFS |
| GORE-MODE-TESTS | Server frame-diff + net byte tests identical in all 3 modes; `removed` runs with zero missing-asset errors | open | tests/ | M4, CONTENT-POLICY, GORE-ASSETS |
| GENTLE-TESTS | Differential tests for both paths: gib/blood messages and effects with cl_gentle 0 and 1 match real DP | open | tests/ | M4, M9 |
| STUDIO-BOTMATCH | Run the bot match (M4-CLIENT) inside Roblox Studio from packed data and show it with a debug view of the server (map surfaces + entity boxes; NOT the renderer): packer `--also`, `tools/studio/botmatch/`, `studio-botmatch.project.json` | done 2026-11-27 (Claude-Quartz; runs in Studio edit mode, G-060; how: tools/studio/botmatch/Run.luau header) | tools/studio/botmatch/, tools/pk3/pack_runtime.py | M4-CLIENT |
| STUDIO-TESTS | **[needs Studio]** Run the Studio test place (tests/studio/README.md), results → §GOTCHAS | open (place built) | tests/studio/, studio-tests.project.json | — |
| VIS-SPECCAL | **[needs Studio]** Specular calibration per texture against Ultra screenshots (docs/subsystems/specular-calibration.md) | open | tools/, assets/data/ | STUDIO-TESTS, REF-SHOTS, M1-TEX |
| M10/M11 | Full content pass; performance pass | open (later) | — | M9 |
<!-- /§TASKS -->

<!-- §MAP -->
## §MAP

Roles: **engine port** → `engine/<file>.luau` mirror · **split** → CPU logic in `engine/`, OS/GL calls in
`platform/` · **platform** → replaced by a Roblox backend · **offline tool** → done ahead of time in
`tools/` · **n/a** → other-OS backend not compiled into the Linux SDL client/dedicated server ·
**needs §DIFFS** → falls under an allowed difference, log before closing · **optional** → comparison
mode only. Status: not started / partial / done / verified (= passes differential tests).
Source: `work/source/Xonotic/source/darkplaces/` (`tools/release/fetch.sh source`; identical to tag xonotic-v0.8.6, D-003).

| C file | lines | role | Luau module | status | tests | notes |
|---|---:|---|---|---|---|---|
| bih.c | 216 | engine port | engine/bih.luau | not started | — |  |
| builddate.c | 17 | n/a | — | not started | — | other OS backend |
| cap_avi.c | 720 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| cap_ogg.c | 1121 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| cd_bsd.c | 283 | n/a | — | not started | — | other OS backend |
| cd_linux.c | 256 | n/a | — | not started | — | other OS backend |
| cd_null.c | 91 | n/a | — | not started | — | other OS backend |
| cd_sdl.c | 283 | n/a | — | not started | — | other OS backend |
| cd_shared.c | 783 | engine port | engine/cd_shared.luau | not started | — |  |
| cd_win.c | 268 | n/a | — | not started | — | other OS backend |
| cl_collision.c | 976 | engine port | engine/cl_collision.luau | not started | — |  |
| cl_demo.c | 621 | engine port | engine/cl_demo.luau | not started | — |  |
| cl_dyntexture.c | 93 | split | engine/cl_dyntexture.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| cl_input.c | 2333 | engine port | engine/cl_input.luau | not started | — |  |
| cl_main.c | 2802 | engine port | engine/cl_main.luau | not started | — |  |
| cl_parse.c | 4332 | engine port | engine/cl_parse.luau | not started | — |  |
| cl_particles.c | 3164 | engine port | engine/cl_particles.luau | not started | — |  |
| cl_screen.c | 2961 | engine port | engine/cl_screen.luau | not started | — |  |
| cl_video.c | 745 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| cl_video_jamdecode.c | 378 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| cl_video_libavw.c | 386 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| clvm_cmds.c | 4965 | engine port | engine/clvm_cmds.luau | not started | — |  |
| cmd.c | 2235 | engine port | engine/cmd.luau | partial | unit/cvar_cmd, integration/config_load | Cbuf/tokenizer/$-expansion/alias/exec/set/toggle/defer; client forwarding, csqc commands, completion not yet |
| collision.c | 1952 | engine port | engine/collision.luau | not started | — |  |
| common.c | 2312 | engine port | engine/common.luau | partial | unit/cvar_cmd | COM_ParseToken_Console only |
| conproc.c | 365 | n/a | — | not started | — | other OS backend |
| console.c | 3035 | engine port | engine/console.luau | partial | — | Con_Print/Printf/DPrint(f) to a line sink only |
| crypto-keygen-standalone.c | 773 | needs §DIFFS | — | not started | — | d0_blind_id player keys → Roblox accounts (allowed diff: accounts) — log in §DIFFS |
| crypto.c | 2628 | needs §DIFFS | — | not started | — | d0_blind_id player keys → Roblox accounts (allowed diff: accounts) — log in §DIFFS |
| csprogs.c | 1260 | engine port | engine/csprogs.luau | not started | — |  |
| curves.c | 440 | engine port | engine/curves.luau | not started | — |  |
| cvar.c | 1070 | engine port | engine/cvar.luau | partial | unit/cvar_cmd, integration/config_load | all of cvar.c; client hooks (CL_SetInfo, SV_BroadcastPrintf notify) log NOT YET PORTED |
| dpsoftrast.c | 5690 | optional | — | not started | — | optional software-renderer comparison mode |
| dpvsimpledecode.c | 656 | needs §DIFFS | — | not started | — | video capture/cinematics: check use in Xonotic data before deciding |
| filematch.c | 223 | engine port | engine/filematch.luau | partial | unit/cvar_cmd | matchpattern, stringlistsort |
| fractalnoise.c | 226 | engine port | engine/fractalnoise.luau | not started | — |  |
| fs.c | 4160 | split | engine/fs.luau | partial | unit/cvar_cmd, integration/config_load | FS_LoadFile/FS_Search/FS_CheckNastyPath over a file provider (G-031 symlinks) |
| ft2.c | 1693 | split | engine/ft2.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| gl_backend.c | 4914 | platform | platform/… | not started | — | → platform/render |
| gl_draw.c | 2156 | split | engine/gl_draw.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| gl_rmain.c | 12480 | split | engine/gl_rmain.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| gl_rsurf.c | 1643 | split | engine/gl_rsurf.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| gl_textures.c | 3179 | platform | platform/… | not started | — | → platform/render |
| hmac.c | 61 | needs §DIFFS | — | not started | — | d0_blind_id player keys → Roblox accounts (allowed diff: accounts) — log in §DIFFS |
| host.c | 1468 | engine port | engine/host.luau | partial | integration/config_load | dedicated Host_Init registrations (engine/_port/sv_init_defs.luau, tools/engine/gen_cvars.py) + config chain |
| host_cmd.c | 3109 | engine port | engine/host_cmd.luau | partial | integration/config_load | MaxPlayers_f; other commands are logging stubs |
| image.c | 1649 | offline tool | — | not started | — | decode offline in tools/textures; runtime image API → platform/render |
| image_png.c | 561 | offline tool | — | not started | — | decode offline in tools/textures; runtime image API → platform/render |
| jpeg.c | 1114 | offline tool | — | not started | — | decode offline in tools/textures; runtime image API → platform/render |
| keys.c | 1993 | engine port | engine/keys.luau | not started | — |  |
| keysym2ucs.c | 849 | n/a | — | not started | — | other OS backend |
| lhnet.c | 1437 | platform | platform/… | not started | — | → platform/net (RemoteEvent transport) |
| libcurl.c | 1833 | needs §DIFFS | — | not started | — | HTTP autodownload: no external servers (allowed diff: networking) — log in §DIFFS when M6 lands |
| mathlib.c | 1082 | engine port | engine/mathlib.luau | not started | — |  |
| matrixlib.c | 1873 | engine port | engine/matrixlib.luau | not started | — |  |
| mdfour.c | 223 | needs §DIFFS | — | not started | — | d0_blind_id player keys → Roblox accounts (allowed diff: accounts) — log in §DIFFS |
| menu.c | 5620 | engine port | engine/menu.luau | not started | — |  |
| meshqueue.c | 151 | engine port | engine/meshqueue.luau | not started | — |  |
| mod_skeletal_animatevertices_generic.c | 136 | engine port | engine/mod_skeletal_animatevertices_generic.luau | not started | — |  |
| mod_skeletal_animatevertices_sse.c | 446 | n/a | — | not started | — | SIMD variant of the generic file; port generic only (same results) |
| model_alias.c | 4072 | engine port | engine/model_alias.luau | not started | — |  |
| model_brush.c | 8790 | engine port | engine/model_brush.luau | not started | — |  |
| model_shared.c | 4851 | engine port | engine/model_shared.luau | not started | — | Mod_LoadQ3Shaders mirrored offline by tools/shaders/parse.py |
| model_sprite.c | 489 | engine port | engine/model_sprite.luau | not started | — |  |
| mvm_cmds.c | 1638 | engine port | engine/mvm_cmds.luau | not started | — |  |
| netconn.c | 3963 | split | engine/netconn.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| palette.c | 371 | engine port | engine/palette.luau | not started | — |  |
| polygon.c | 310 | engine port | engine/polygon.luau | not started | — |  |
| portals.c | 480 | engine port | engine/portals.luau | not started | — |  |
| protocol.c | 3418 | engine port | engine/protocol.luau | not started | — |  |
| prvm_cmds.c | 7366 | engine port | engine/prvm_cmds.luau | partial | integration/sv_config_worldspawn | cvar builtins (cvar, cvar_string/defstring/description/type, cvar_set, registercvar) |
| prvm_edict.c | 3442 | engine port | engine/prvm_edict.luau | partial | tests/unit/prvm_exec.test.luau | PRVM_Prog_Load (to statement checks) + PRVM_GetString done; rest M2-RUNNER |
| prvm_exec.c | 1054 | engine port | engine/prvm_exec.luau | partial | tests/unit/prvm_exec.test.luau, qcaot_* | Enter/Leave/ExecuteProgram + all opcodes done; debug/profiling not yet (M2-INTERP-DEBUG); docs/subsystems/qcvm.md |
| r_explosion.c | 285 | engine port | engine/r_explosion.luau | not started | — |  |
| r_lerpanim.c | 0 | engine port | engine/r_lerpanim.luau | not started | — |  |
| r_lightning.c | 196 | engine port | engine/r_lightning.luau | not started | — |  |
| r_modules.c | 134 | engine port | engine/r_modules.luau | not started | — |  |
| r_shadow.c | 7671 | split | engine/r_shadow.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| r_sky.c | 475 | engine port | engine/r_sky.luau | not started | — |  |
| r_sprites.c | 435 | engine port | engine/r_sprites.luau | not started | — |  |
| sbar.c | 2263 | engine port | engine/sbar.luau | not started | — |  |
| snd_3dras.c | 1042 | n/a | — | not started | — | other OS backend |
| snd_alsa.c | 524 | n/a | — | not started | — | other OS backend |
| snd_bsd.c | 243 | n/a | — | not started | — | other OS backend |
| snd_coreaudio.c | 399 | n/a | — | not started | — | other OS backend |
| snd_main.c | 2343 | split | engine/snd_main.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| snd_mem.c | 377 | offline tool | — | not started | — | decode offline in tools/sounds; sample metadata kept for engine |
| snd_mix.c | 536 | platform | platform/… | not started | — | → platform/sound (Roblox mixes; port channel/volume math) |
| snd_null.c | 169 | n/a | — | not started | — | other OS backend |
| snd_ogg.c | 718 | offline tool | — | not started | — | decode offline in tools/sounds; sample metadata kept for engine |
| snd_oss.c | 344 | n/a | — | not started | — | other OS backend |
| snd_sdl.c | 267 | n/a | — | not started | — | other OS backend |
| snd_wav.c | 348 | offline tool | — | not started | — | decode offline in tools/sounds; sample metadata kept for engine |
| snd_win.c | 897 | n/a | — | not started | — | other OS backend |
| sv_demo.c | 99 | engine port | engine/sv_demo.luau | not started | — |  |
| sv_main.c | 4089 | engine port | engine/sv_main.luau | partial | tests/integration/sv_vm_setup.test.luau | SV_VM_Setup up to Prog_Load; docs/subsystems/server-runner.md |
| sv_move.c | 448 | engine port | engine/sv_move.luau | not started | — |  |
| sv_phys.c | 3232 | engine port | engine/sv_phys.luau | not started | — |  |
| sv_user.c | 975 | engine port | engine/sv_user.luau | not started | — |  |
| svbsp.c | 453 | engine port | engine/svbsp.luau | not started | — |  |
| svvm_cmds.c | 3862 | engine port | engine/svvm_cmds.luau | partial | tests/integration/sv_vm_setup.test.luau | builtin table (generated names) + logging stubs; no builtin ported yet |
| sys_linux.c | 184 | n/a | — | not started | — | other OS backend |
| sys_sdl.c | 262 | platform | platform/… | not started | — | → platform/boot (time, main loop) |
| sys_shared.c | 652 | engine port | engine/sys_shared.luau | not started | — |  |
| sys_win.c | 401 | n/a | — | not started | — | other OS backend |
| thread_null.c | 82 | n/a | — | not started | — | other OS backend |
| thread_pthread.c | 226 | n/a | — | not started | — | other OS backend |
| thread_sdl.c | 173 | n/a | — | not started | — | other OS backend |
| thread_win.c | 303 | n/a | — | not started | — | other OS backend |
| utf8lib.c | 3055 | engine port | engine/utf8lib.luau | not started | — |  |
| vid_agl.c | 1130 | n/a | — | not started | — | other OS backend |
| vid_glx.c | 1763 | n/a | — | not started | — | other OS backend |
| vid_null.c | 97 | n/a | — | not started | — | other OS backend |
| vid_sdl.c | 3023 | platform | platform/… | not started | — | → platform/input + platform/render (window, mouse, keys) |
| vid_shared.c | 2100 | split | engine/vid_shared.luau | not started | — | CPU logic → engine/, GL/OS calls → platform/ |
| vid_wgl.c | 2286 | n/a | — | not started | — | other OS backend |
| view.c | 1197 | engine port | engine/view.luau | not started | — |  |
| wad.c | 312 | engine port | engine/wad.luau | not started | — |  |
| world.c | 3123 | engine port | engine/world.luau | not started | — |  |
| zone.c | 988 | engine port | engine/zone.luau | not started | — |  |
| **Platform backends** | | | | | | |
| platform/render | — | platform | platform/render/init.luau | not started | — | GL → Roblox 3D; docs/subsystems/platform.md |
| platform/sound | — | platform | platform/sound/init.luau | not started | — | mixer/output → Sound instances |
| platform/net | — | platform | platform/net/init.luau | not started | — | lhnet → RemoteEvent / UnreliableRemoteEvent |
| platform/input | — | platform | platform/input/init.luau | not started | — | SDL input → UserInputService |
| platform/storage | — | platform | platform/storage/init.luau | not started | — | fs writes → DataStores |
| platform/contentpolicy + assets/optional/gore | — | platform | platform/contentpolicy/init.luau | partial | tests/unit/contentpolicy.test.luau | gore isolation switch + separate gore asset group (D-016) |
| prvm_offsets.h + builtin tables | — | port support | engine/prvm_offsets.luau, engine/_port/builtin_names.luau | done (generated) | tests/integration/sv_vm_setup.test.luau | tools/engine/gen_tables.py from the pinned source |
| engine/_port/qcrt | — | port support | engine/_port/qcrt.luau | verified vs interpreter | tests/integration/qcaot_diff.test.luau, tests/unit/qcaot_synth.test.luau | AOT runtime (calls, returns, edict access, runaway counter) |
| engine/_port/f32 | — | port support | engine/_port/f32.luau | verified | tests/unit/f32.test.luau | docs/subsystems/float32.md |
<!-- /§MAP -->

<!-- §DIFFS -->
## §DIFFS

Every remaining difference from real Xonotic 0.8.6. Format: ID · what differs · what was tried · why
impossible on Roblox · allowed category · how close. Revisit every entry when Roblox ships new features.
If it isn't here, it isn't allowed.

| ID | What differs | Tried | Why impossible | Category | Closeness |
|---|---|---|---|---|---|
| DIFF-002 | **Planned, not built.** Console (gamepad) and mobile (touch) controls with slight gameplay assists, for those inputs only; keyboard-and-mouse stays exactly Xonotic | — (blocked: Q-009) | owner-approved design difference, not a platform limit | owner-approved planned difference (D-018) | to be measured once defined |
| DIFF-003 | **Planned, not built, much later.** Game passes | — (blocked: Q-009) | owner-approved | owner-approved planned difference (D-018) | — |
| DIFF-004 | Roblox asset of `sound/misc/null.wav` and `sound/menu/close.ogg` (4 samples each, all silent) is a 16-bit WAV of exactly those samples padded with silence to 0.05 s | uploading the original files: rejected ("Audio duration too long", really a minimum length, G-037) | Roblox audio minimum length | proven platform limit | audibly identical; engine timing uses the original files' lengths (M8) |
| DIFF-005 | 13 voice lines (Q-013 list) play with the profanity bleeped ("bitch", "retard", "pussy", "ass" → 1 kHz tone); timing/length identical | uploading the originals and one identical retry: rejected by Roblox moderation | Roblox Community Rules for audio | Roblox policy, owner decision D-022 | everything except the bleeped words is sample-identical |
| DIFF-006 | soldier/coms/meet: besides the DIFF-005 bleep (wider: mid "your".."to"), pitch +3% (≈ half a semitone), same length | bleep only (2 versions): rejected | Roblox moderation (likely matched to the rejected recording) | Roblox policy, owner decision D-023 | slight pitch change; timing identical |
| DIFF-007 | Textures with web addresses / phone-number text: those text areas blurred (list + boxes in assets/manifest, tool tools/upload/blur_text.py) | uploading as-is: account warnings + 2 one-day suspensions (off-platform links) | Roblox Community Standards (off-platform links) | Roblox policy, owner decision D-024 | only the text areas differ |
| DIFF-008 | 106 textures changed for Roblox (gore: splat icons → blobs, blood decals → soot, stains → grime, gibs/flesh → rock; text: URLs/IP/phone digits/"NO PORNOGRAPHIC..."/"PILLS"/crude lines/brands removed or blurred). Lists: assets/manifest/review/{gore_fixes,content_fixes}.tsv; tools/upload/{gore_fix,content_fix,blur_text}.py; set: tools/upload/build_ready.py → assets/manifest/upload-ready.tsv | originals uploaded: warnings + 2 suspensions | Roblox Community Standards | Roblox policy, owner decisions D-022/D-024/D-025 | only the listed areas differ |
| DIFF-009 | 124 more textures changed for Roblox after the strict review (G-051), on top of DIFF-008: blood-splatter tiles → clean sibling tile + faint dirt shadow (2 brain-like lumps gone); splatter decals → soft grey smudge (colour + alpha); point-down stars turned point-up (e7); cross-in-ring lamp lenses turned 45° to an X (28 files incl. normal/height/glow); hooked-arm glyph e6symbol_b → sibling rune; tags/handles/real names/brand-like marks erased ([HFX], [KFX] INDUSTRIES, NEXX CORP, VECTOR, '100% katoen', kuniuthefrogg, strahlemann, SMILECYTHE, Samual, 'by Justin', Cuinn Herrick, Justin Fisher, TRAK sticker); Nexuiz name/logo blanked (billboard frame, stained glass, lamp2); OBEY screen → XON; NO SMOKING rule + word LETHAL, pill bottle, skull drips, HELP drips, digit string '1688', 'S.S'-like door stencil, 'FK'/'KK' in screen noise removed; gib skins/gloss neutral grey; pyria skin patches smoothed. Lists: assets/manifest/review/content_fixes3.tsv (what changed per file) and content_kept3.tsv (153 kept, with reasons); tool tools/upload/content_fix3.py | originals / earlier fixed versions: flagged by the strict review after the child-safety moderation over 'CP' | Roblox Community Standards + moderation false positives | Roblox policy, owner decision D-025 + owner brief 2026-11-24 | only the listed areas differ; same size and mode |
| DIFF-010 | 43 more textures changed for Roblox (UPLOAD-FIX4): the flagged images that were uploaded before the ban. 'CP' control-point sign (5 maps): the P is the mirror image of the C → one symmetric ring emblem, no letters; gfx/blood (+alpha): splat and droplets blurred to a soft cloud; gfx/leave_em_behind_mini: the two empty yards hatched (corridors unchanged); desertfactory notes/graffiti: usernames (sev, Tenshihan, MEXL), program names and 'Nexuiz' erased; newspaper credit 'by sev' erased; race checkpoint ring: rune-style text column → plain stone (colour, bump, gloss); tablets: 'BS', the Nexuiz sentences erased; rockets: red paint → red-orange, 'FALCON PUNCH' and 'Fricka' erased; cockpit: photographer credit and LCD letters 'dPIC' erased; yellow domination icon (8 files) and e8circle_pur turned 45° (cross → X); hud/old/armor muscle relief smoothed; alphamod labels '14%', '69%', '88%' blanked; bloodyskull = cleanskull; 'FRUITIEX' erased; gfx/menu/luminos/background_ingame_alpha 1x1 → 4x4 of the same grey (Roblox rejected the 1x1 file). List: assets/manifest/review/content_fixes4.tsv; 70 kept with reasons: content_kept4.tsv (incl. 11 'medium' XONOTIC-logo findings kept on the owner's wordmark rule) | originals / earlier fixed versions: the live assets flagged by the 2026-11-23 live review (assets/manifest/review/live_findings_*.tsv) | Roblox Community Standards + moderation (G-051: ambiguous letters, look-alike symbols, real names/handles, other games' names) | Roblox policy, owner decision D-025 + owner's brief of 2026-11-24/25 ("fix everything") | only the listed areas differ; same size and mode (one 1x1 → 4x4, identical when stretched); tools/upload/content_fix4.py is deterministic |
(DIFF-001 withdrawn 2026-11-20, see D-015.)

Candidates already known (become entries when the subsystem lands, after real attempts):
- FOV above ~133.4° (4:3 horizontal) — Roblox `Camera.FieldOfView` is vertical, clamped 1–120 (G-006).
- Player keys (crypto.c / d0_blind_id) → Roblox accounts (allowed: accounts).
- HTTP autodownload (libcurl.c), server browser for external servers, IP connect (allowed: networking).
<!-- /§DIFFS -->

<!-- §DECISIONS -->
## §DECISIONS

One line each; **full text: `docs/decisions.md`** (add new decisions to both). Never contradict; supersede.

**D-001 (2026-11-20) Version pin: Xonotic 0.8.6.** Latest stable per gitlab.com/xonotic tags and
dl.xonotic.org (checked 2026-11-20; no newer tag). Tags `xonotic-v0.8.6`: xonotic `0100f2c8d794`,
xonotic-data.pk3dir `45df581bba67`, xonotic-maps.pk3dir `1db540e620c0`, darkplaces
`f244ef2525c9c018f1b077d49959df3c77ebc7b1`, gmqcc `2fe0af00e78d`. Release zips (sha512 from official
`xonotic-0.8.6.sha512`, pinned in `tools/release/fetch.sh`): `xonotic-0.8.6.zip` cb39879e…6c2a6,
`xonotic-0.8.6-high.zip` d2fc8cc2…64c90, `xonotic-0.8.6-source.zip` 88aa9cf3…e9498.
Data pk3 sha256 (full table + sizes: `assets/manifest/pk3-{standard,high}.tsv`):
- data `7602be0d44a4f1ce4f0918c54ceb215c9bc963a103623d6c7874f081330c8505`, data-high `2bf01537f502a5b1a0c316c408dd648b162497d292eedc6ab8b01e616328e424`
- maps `d10e5a8eac468a4a5b6d80f9603d95949971c6b10f86bec65a79e19f0d424f54`, maps-high `7569dc8354e61d8f74a5908816b66adf8835ce9de64a915c7d49a00f0d1df455`
- nexcompat `34021da1176e2b47383c94707b5922d9a5f3c4ff43f8ac4ac0e39da44648ccbe`, -high `c37e73cd8dbae1f27d06d91b9c2f1bff8ee1b758b061790aa76d9847a8775b16`
- xoncompat `e3aaff8e6dfb7a0031e2a04d62e5146fd7a9710264c7af1c3be752b62629b739`, -high `ed76e54fd340053da00e854d4b8a915cd82c21f498ebc7b3922fd2db084b1b62`
- music `133fbcfa5766cd6849c2918bb34ce4d749aeafcbf89de54df467a61296353f48`; fonts: see pk3-*.tsv
- QuakeC (identical in both builds): progs.dat `e6f5c70b8e0e5f329531ce53ac982eb698a12660a1b45622a900a7bc3bb87a62`,
  csprogs.dat `7d7807166d38521aadb8109830b69580596be4c05924d1b1fd8b71c31d4def13`, menu.dat `dc75076060bac00aacdcd58d6a216cfb33f7a4665a18a622ff970bc73869bbb8`

- **D-002** Two builds of 0.8.6 with identical code and non-texture data; textures from `-high` (Ultra loads uncompressed originals).
- **D-003** Engine source of truth: `source/darkplaces` in the release = darkplaces tag xonotic-v0.8.6 (byte-identical).
- **D-004** Float32: round after every C float op and on every float store (buffer f32 slots); doubles stay double; no FMA. `engine/_port/f32.luau`.
- **D-005** Tick: `sys_ticrate 0.0333333` (30 Hz); client `cl_netfps 60`, `cl_movement 1`, `cl_maxfps 250`.
- **D-006** Tooling: Lune 0.11.1, Rojo 7.7.1, StyLua 2.6.0, Selene 0.31.0; Python 3 converters; Selene std `xonotic_std.yml`.
- **D-007** Relative string requires only (same in Lune and Roblox).
- **D-008** Engine in Quake units; studs only in `platform/render` via one constant (M5).
- **D-009** Visual reference: `-high` build, Ultra preset (docs/subsystems/visual-reference.md).
- **D-010** Downloads/extracted data in `work/` (gitignored); manifests, tables, test vectors committed.
- **D-011** Session id = first 8 chars of the Claude session id; an assigned branch replaces `<task-id>-<name>`.
- **D-012** `main` is the integration branch; sessions PR into it.
- **D-013** Owner confirmed D-002.
- **D-014** (superseded by D-015) gentle mode on by default.
- **D-015** Blood/gore policy deferred by owner until before publishing (Q-007); `cl_gentle` exactly as Xonotic.
- **D-016** Gore ported fully but isolated: separate asset group + one `platform/contentpolicy` switch (3 modes); QuakeC never edited.
- **D-017** (refined by D-020) generated QuakeC not committed.
- **D-018** Owner-approved planned differences: console/mobile controls with slight assists (those inputs only), game passes later; not built until Q-009; keyboard-and-mouse exact.
- **D-019** Gore `removed` mode approved: same-name placeholder models/sounds; identical precache order and indices; no server missing-model error.
- **D-020** Generated QuakeC = reproducible build step (`tools/build.sh`); progs → ServerScriptService, csprogs/menu → ReplicatedStorage; modules ≤ 190k chars.
- **D-021** Session names + chat (owner, 2026-11-21): each session is `Claude-<Word>` (WELCOME.md list, unique per
  docs/chat/roster.md) and uses it in chat, logs, claims and commits (`T-014 [Claude-Zigzag] ...`); replaces
  D-011's session id. Chat = docs/chat/YYYY-MM-DD.md on `main`, append-only, posted by tools/chat.sh straight to
  `main` (chat-only commits; the only direct pushes to `main`), retried from the new main on rejection;
  `merge=union` for docs/chat/*.md. HANDOFF.md stays the record (docs/chat/README.md).
- **D-022** (owner, 2026-11-21) Voice lines rejected by Roblox moderation for profanity get the bad words bleeped
  (1 kHz tone over exactly the word, same length), everything else untouched; tools/sounds/censor_voice.py,
  DIFF-005. Applies to the 13 lines of Q-013; heavymetal.ogg (music, no profanity) stays original for an appeal.
- **D-023** (owner, 2026-11-21) "Tweak a bit" to pass moderation without appeals: soldier/coms/meet = censored v2
  + pitch +3% (rubberband, formants kept, same length) → approved; heavymetal.ogg pitch +3% → still rejected.
- **D-024** (owner, 2026-11-21) Textures with web addresses ("xonotic.org" etc.) or phone-number-like text get only
  those text areas blurred for the Roblox upload; everything else and the originals stay unchanged (DIFF-007).
- **D-025** (owner, 2026-11-21 night) Every asset must reach the game; anything against Roblox rules is changed as subtly
  as possible (owner's example: blood-splat kill-feed icons → irregular rounded blobs). Done by 6 review agents (all
  10,910 textures: content sheets + zoomed text sheets) and 2 fix agents; DIFF-008.
<!-- /§DECISIONS -->

<!-- §QUESTIONS -->
## §QUESTIONS

- **Q-002 (2026-11-20, owner: will test later; [needs Studio]) Max image size.** Roblox docs conflict: "up to 4096×4096" vs "up to 1024×1024 pixel
  spaces for texture maps" (G-004). Default taken: tile anything > 1024 (lossless either way). Please test
  in Studio: upload one 2048² and one 4096² image and check whether they display at full resolution.
- **Q-007 (2026-11-20) Blood/gore policy: deferred by owner until before publishing.** Covers the content-
  ratings questionnaire, any gentle-mode default and locking. Until decided: `cl_gentle` exactly as in
  Xonotic; gore isolated per D-016 so any choice is a one-line `platform/contentpolicy` change. Facts for
  the questionnaire (both states, and that players can untick gentle mode): docs/policy/gentle-mode.md.
- **Q-004 (2026-11-20, owner: will provide later) Open Cloud API key** for uploading assets (M1-UPLOAD): needs Assets read+write
  for your account or group. Provide it as a session network secret or local env var, never in the repo.
  Also: upload to your user or a group?
- **Q-005 (2026-11-20, owner: will test later; [needs Studio]) Studio measurements needed** (cannot be done headless): `Camera.NearPlaneZ` on your
  devices, and the maximum `PointLight.Range` Studio accepts (docs give none). These set the stud scale (D-008).
- **Q-009 (2026-11-20) Define the console/mobile assists and the game passes exactly** (D-018). Needed before
  any work: which inputs get assists (gamepad, touch), what each assist does (e.g. aim slowdown/magnetism,
  movement help), its strength and limits, whether it applies in every mode and against keyboard-and-mouse
  players, and how it is shown. For game passes: what each grants, and confirmation that none changes
  gameplay balance. Until defined: neither is built; all inputs play exactly like Xonotic.
- **Q-010 (2026-11-20) Client code size.** Every player would download ≈ 48 MB of bytecode and hold ≈ 53 MB
  heap for csprogs+menu (G-026; Studio numbers still needed). Options, none changing behaviour (qcaot_diff
  must stay at zero): (a) structured control flow (removes the ≈ 30% scaffolding; task M2-AOT-STRUCT);
  (b) compact code generation (shorter emitted forms, shared helpers); (c) hybrid: ship csprogs.dat/menu.dat
  (≈ 6 MB) and run cold functions on the reference interpreter, compile only hot ones (profile-guided);
  this departs from "all QC compiled to Luau" for cold code, so it is your call; (d) sound dead-code
  elimination via call-graph reachability incl. name lookups (risky, likely small); (e) send client code
  after join (shorter join, same total). Default meanwhile: (a)+(b) next, then measure in Studio.
- **Q-011 (2026-11-21, Claude-Anvil) Server settings on Roblox.** A real Xonotic dedicated server is started
  with a command line and usually `+exec server.cfg` (hostname, player limit, map list, game type). The port
  now loads exactly the stock chain (quake.rc → default.cfg → … → post-config.cfg) and nothing else; player
  limit = DP default 8 at startup, and quake.rc's `maxplayers $menu_maxplayers` makes it 16 from the next map.
  Which player limit and server.cfg should Roblox servers use? Default meanwhile: stock chain only.
- **Q-012 (2026-11-21, Claude-Anvil) Roblox Open Cloud API key + user/group id.** Scopes for the whole project
  in G-035: assets Read+Write (quota, all uploads), universe-places Write (publish), Luau execution sessions
  Read+Write (automated tests on real Roblox servers), optional asset-permissions Write. The key is entered through the
  session's secure credential form (never in chat or the repo) when M1-SOUNDS starts.
- **Q-013 (2026-11-21, Claude-Anvil) 13 sounds rejected by Roblox moderation** (no reason given; list in
  assets/manifest/roblox-audio-moderation.tsv): 12 voice-set taunts/team messages (carni-lycan needhelp2,
  taunt1, teamshoot3; pyria-skadi taunt1, taunt5, teamshoot2; robot needhelp2; soldier meet, taunt2; specop
  taunt1, taunt4, teamshoot2) and music track cdtracks/heavymetal.ogg. Not changed or re-uploaded (rules:
  never change content for policy on our own; re-uploading identical rejected audio risks account moderation).
  Your options: appeal in the Creator Dashboard / via Roblox support, or decide what the game should do
  with them (would be a §DIFFS entry). Until then those sounds have no usable asset (silent in game).
  Update 2026-11-21 (owner asked to retry): recheck → 785 approved, 14 rejected (+ marine/coms/teamshoot3),
  6 reviewing. One identical re-upload (robot needhelp2 → asset 120983016932971) was rejected instantly
  (file recognised), so the other 13 were NOT retried. **Owner decided (D-022): bleep the bad words**; the 13
  censored versions were uploaded: 12 approved. soldier/coms/meet ("get your ass to the waypoint") rejected
  again twice (word bleep, then mid "your"..mid "to" bleep): probably matched to the rejected recording;
  stopped retrying (account strikes). meet.ogg approved after pitch +3% (D-023, DIFF-006). Still open: heavymetal.ogg (instrumental, likely a false
  copyright match; original + pitch +3% both rejected) → appeal, or owner decides on a bigger change.
- **Q-014 (2026-11-22, Claude-Anvil; [needs Studio]) AOT load cost vs speed.** Headless (Lune, no native codegen):
  requiring all 215 server chunks (37 MB Luau) takes 17.7 s; the interpreter runs the same QC ~1.5× slower but
  loads progs.dat in 0.1 s. Lazy chunk loading (M2-AOT-SHIP) saves only ~20% on the server (Xonotic's first
  StartFrame touches 169/215 chunks). Please time in Studio: server Play → BOOT REPORT "SV_VM_Setup + AOT install"
  and the first frame. If Roblox is as slow, options: (a) interpreter at startup + AOT chunks preloaded in
  the background (preload(prog, n) per frame), (b) structured control flow (M2-AOT-STRUCT, ≈ −30% code).
<!-- /§QUESTIONS -->

<!-- §GOTCHAS -->
## §GOTCHAS

One line each; **details and sources: `docs/gotchas.md`** (add to both). Roblox facts read 2026-11-20.

- **G-001** EditableImage max 1024×1024; strict client memory budget.
- **G-002** EditableMesh ≤ 60,000 vertices / 20,000 triangles; mesh assets ≤ 20,000 triangles.
- **G-003** UnreliableRemoteEvent payload > 1000 bytes dropped; ~500 remote requests/s per client.
- **G-004** Image size docs conflict (4096² vs 1024²) → tile at 1024 (Q-002).
- **G-005** Lighting: Future is the best selectable technology.
- **G-006** Camera.FieldOfView is vertical, 1–120° → DP fov > ~133.4° not showable.
- **G-007** Camera.NearPlaneZ read-only, -0.1 to -0.5 studs by platform.
- **G-008** Part size 0.001–2048 studs per axis.
- **G-009** Light Range maximum undocumented (Q-005).
- **G-010** DataStore value ≤ 4,194,304 chars per key; request queues of 30.
- **G-011** require-by-string semantics (`./`, `../`, `@self/`, `@game/`), non-blocking.
- **G-012** Selene std generation and Rokit don't work in cloud sessions → `xonotic_std.yml`, `tools/bootstrap.sh`.
- **G-013** Cloud network needs the "Roblox-Xonotic" environment (personal env of the owner, created 2026-11-21 by Claude-Anvil: dl.xonotic.org, create.roblox.com, apis.roblox.com + package registries; setup script runs tools/bootstrap.sh). The Default environment gets proxy 403 on dl.xonotic.org.
- **G-014** Standard-build map textures are DDS-only; DP image loader has no DDS fallback.
- **G-015** DP VFS: alphabetically last pk3 wins; pk3 lookups case-sensitive.
- **G-016** JPEG alpha comes from `<name>_alpha.jpg` (2,326 such files in -high).
- **G-017** Content ratings: IARC questionnaire; realistic blood in assets may be moderated.
- **G-018** SurfaceAppearance maps only via `AssetService:CreateSurfaceAppearanceAsync` (client-side for EditableImages).
- **G-019** `Lighting.Technology` only settable in the place file (Rojo `$properties`).
- **G-020** ViewportFrame: no shadows, no post-processing.
- **G-021** Runtime mesh route: CreateEditableMesh → CreateMeshPartAsync; CreateEditableImage returns nil when out of budget.
- **G-022** Lune: relative requires only, no Roblox `Random`; loads all 65 MB of generated QC fine.
- **G-023** Place ≤ 100 MB; full place with generated QC = 14 MB .rbxl.
- **G-024** No documented script size limit; DevForum: 200,000 chars via plugin `Source` → modules ≤ 190k chars ([needs Studio] confirm).
- **G-025** ReplicatedStorage replicates to all clients (bytecode even if unused); server code in ServerScriptService.
- **G-027** progs.dat declares 3 builtins that are NULL in vm_sv_builtins (#352, #566, #608): keep NULL; real DP errors only if called.
- **G-028** Xonotic progs crc 5927 == PROGHEADER_CRC, so SV_VM_Setup's entvars_t field-offset branch applies.
- **G-026** Bytecode ≈ 1.65× source: client ≈ 48 MB download, ≈ 53 MB heap for csprogs+menu (Q-010).
- **G-029** Direct pushes of chat-only commits to `main` work (no branch protection, 2026-11-21); 8 concurrent posts from 2 clones all landed with tools/chat.sh.
- **G-031** pk3s contain **1,927 zip symlinks** (high; 1,908 standard: 1,399 textures, 405 gfx, 94 models, 25 sounds, 3 particles, 1 maps); DarkPlaces follows them (fs.c FS_OpenReadFile, 16 levels). tools/pk3 follows them since 2026-11-21 (manifest column `symlink_to`); re-run `manifest.py --extract` on older work/vfs-* (they held link text).
- **G-030** Audio (creator-docs 2026-11-21): ≤ 7 min, ≤ 20 MB, ≤ 48 kHz, mp3/ogg/wav/flac; not updatable via Open Cloud. Quota docs conflict (2,000 vs 100 per 30 days verified) → read live: `GET apis.roblox.com/cloud/v2/users/{id}/asset-quotas` (scope asset:read; usage/capacity/period/usageResetTime). Sound.PlaybackRegion needs PlaybackRegionsEnabled; AudioPlayer has PlaybackRegion/LoopRegion always on.
- **G-032** qsort is unstable: FS_Search results equal under strcasecmp (only case differs) have no defined order in DP; the port breaks ties by strcmp. No such pair exists in the 0.8.6 data.
- **G-033** `stylua --check ... game` also scans git-ignored game/generated (AOT output, not formatted): check `game/*` minus `generated`.
- **G-034** DP quirk kept: `exec dir/*.cfg` runs the matches in *reverse* sorted order (each Cmd_Exec inserts at the buffer front).
- **G-035** Open Cloud scopes (creator-docs openapi.json, 2026-11-21): assets upload/update/operations + quota read = `asset:write` / `asset:read`; place publish (`POST /universes/v1/{u}/places/{p}/versions`) = `universe-places:write`; run Luau on a Roblox server (`luau-execution-session-tasks`, headless [needs Studio]-style tests) = `universe.place.luau-execution-session:write` (+`:read` for results/logs); grant an asset to an experience = `asset-permissions:write`. Don't IP-restrict keys used from cloud sessions (changing IPs). Group-owned work: key on a dedicated alt account with minimal group role (docs' advice).
- **G-036** Live audio quota of the owner's account (2026-11-21, Open Cloud asset-quotas): capacity 2,000 per MONTH, 30 used → 1,970 left ≥ 805 unique sounds, so **every sound is uploaded as its own asset; no packing** (AUDIO-PLAN rule 4 not triggered). Key: environment network secret for apis.roblox.com (x-api-key), never in the repo; user id passed as an argument, not committed.
- **G-037** Open Cloud audio upload rejects very short files (4 samples at 11 kHz) with `InvalidArgument: Audio duration too long` (misleading: a minimum length); 0.05 s is accepted (2026-11-21). New audio goes to moderation: `moderationState` Reviewing → Approved / Rejected, no reason given via API (tools/sounds/check_moderation.py).
- **G-038** (owner's Violations & Appeals page, 2026-11-21) Each audio rejected for content becomes an account violation ("Audio removed"): all 13 profanity originals + both rejected censored meet versions (15). Not listed: heavymetal.ogg (both uploads → copyright-type block, appeal via roblox.com/support) and an identical re-upload rejected instantly. **Never upload uncertain audio without the owner's OK.**
- **G-039** 2026-11-21: after 671 textures (byte-for-byte jpg Image uploads, tools/upload/upload_images.py) Open Cloud returned `HTTP 403 User is moderated` for every upload: the owner's account was moderated (likely the 15 audio violations of G-038 + earlier account history). Uploads stopped; resumable once the owner's account is clear (or another owner account/group is chosen).
- **G-040** The 403 (G-039) was a **Warning** for gfx/hud/default/notify_headshot.jpg ("Violent Content and Gore"); after the owner acknowledged it, uploads work again. Gore filter: CLIP ViT-B/32 zero-shot score + visual review of 198 candidates → 59 textures in assets/optional/gore/textures.tsv, skipped by tools/upload/upload_images.py. Images cannot be archived via Open Cloud ("not an archivable asset type"): already-uploaded notify_death(+_alpha)/notify_fall must be removed by the owner in the Creator Dashboard.
- **G-041** 2026-11-21: second moderation after 1,752 textures (gore filter of G-040 active): 403 "User is moderated" again; watcher stopped the run. Unknown which image (owner to check roblox.com/report-appeals). **Do not upload more to the owner's personal account**; next uploads need a dedicated account/group (owner decision) and a stricter content review.
- **G-042** 2026-11-21: third and fourth strikes → **owner suspended for 1 day**: gfx/menu/wickedx/background_ingame.jpg ("Directing users off-platform": tiny engraved "XONOTIC.org"; Tesseract OCR cannot read it) and gfx/hud/default/notify_selfkill.jpg (blood-splat kill-feed icon, CLIP gore score only 0.06, uploaded before the filter). Gore list now 98 (all notify_* splat icons of every HUD skin). Lessons: CLIP misses small stylised blood; URLs hide in menu skins/logos; **no further uploads to the owner's personal account** — a dedicated account/group + human review of every image category first.
- **G-043** 2026-11-21 07:05 UTC: owner's appeal succeeded: account no longer moderated and asset 85776129881684 (notify_selfkill.jpg) is now `Approved`. Still: no uploads until the review step exists and the owner OKs each risky category (G-042).
- **G-044** Gated batches (2026-11-21): batches 1-2 (600 low-risk textures) all Approved; then 403 "User is moderated" from a new off-site-link warning on an *older* menu-skin upload. Any unacknowledged warning blocks every upload until the owner clicks through it in the Roblox app. Uploader now stops all workers at the first 403.
- **G-045** 2026-11-21: second 1-day suspension (off-site link text in textures: "xonotic.org", phone-number-like text on walls). Uploads stopped until the account is clear AND text areas are blurred (D-024).
- **G-046** (creator-docs 2026-11-21) Image upload: png/jpeg/bmp/tga, < 8000×8000, not updatable via Open Cloud (a changed image is a new asset). texture-specifications: "Roblox supports up to 4096×4096 pixel texture resolutions" (engine streams lower mips first); the same page still says 1024×1024 for texture *maps* (G-004 conflict) → [needs Studio] check that a 2048² image keeps full detail. Xonotic -high: 10,662 textures ≤ 1024, 242 ≤ 2048, 6 > 2048.
- **G-047** All 805 audio + 2,396 image uploads so far carry "xonotic.org" in their *description* and the file path (words like "blood") in their display name: likely extra off-platform/gore triggers. Uploaders now use neutral names ("Xonotic texture <sha12>") and descriptions without a domain. **First thing after the suspension ends:** PATCH every existing asset's displayName/description (Open Cloud `PATCH /assets/v1/assets/{id}`, asset:write) before any new upload.
- **G-048** (creator-docs os.yaml, read 2026-11-22) Roblox `os.date` accepts exactly "*t" (local) and "!*t" (UTC) as table formats; engine/_port/libc.luau builds strftime/gmtime/localtime on those. Luau `string.format` is C's (snprintf) but refuses widths/precisions > 99 (libc.format1 pads those).
- **G-049** Xonotic spawns map entities lazily: its engine-called SV_OnEntityPreSpawnFunction (qcsrc/lib/_all.inc) sets `__spawnfunc_expecting`, so PRVM_ED_LoadFromFile only queues them; the first StartFrame runs the world constructor (real worldspawn), which spawns the queue. Engine-called functions read `this` from leftover OFS_PARM0 or `self`, so builtins must leave parameter globals exactly as DP does.
- **G-050** qsort in buf_sort: comparators are inconsistent for NULL/empty strings, so the result depends on the algorithm. Ported as glibc's msort (top-down merge sort, glibc ≤ 2.37 as at the 0.8.6 release); newer glibc may order empty strings differently.
- **G-051** (2026-11-22) Roblox moderation flagged textures/cp_glow.jpg (big letters "CP" meaning Control Point) as child-safety and moderated the account (appeal granted). Review for *ambiguous* letters/numbers too (CP, SS, 88, 14, 69, 420), symbol look-alikes (map layouts, rotated crosses, sun crosses), real names/handles and other games' names — not only URLs/gore. A batch item stuck in "Reviewing" for hours preceded the ban: treat a long review as a warning.
- **G-056** (2026-11-25) Engine quirks the port keeps on purpose (found while matching the C build bit for bit): (a) collision.c L384-385 points brush->edgedirs and brush->elements at the same memory, so the triangle elements overwrite the first edge directions and traces read integers as floats there (engine/collision.luau reproduces the bytes); (b) Mod_Q3BSP_LoadFaces counts every patch's control points on top of its tesselated vertices when sizing surfmesh, so trailing mesh vertices are unused zeros.
- **G-055** (2026-11-25) PowerShell eats backticks inside double-quoted `python -c "..."` strings: Luau interpolated strings written that way lose their backticks. Put generated Luau in a file (Write/Edit), never in an inline command.
- **G-054** (2026-11-25) No C compiler on the owner's PC (installing one was refused). Reference vectors are built by .github/workflows/testgen.yml on every push that touches tools/testgen/ (non-main branches): it fetches the pinned source, compiles the generators (`gcc -std=gnu11 -O0 -ffp-contract=off`; DarkPlaces .c files that need the whole engine link with `-ffunction-sections -Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all` and a few stubs) and uploads tests/vectors as the artifact `tests-vectors`. gcc 15 defaults to C23 where `false` is a keyword: DarkPlaces needs -std=gnu11.
- **G-053** (2026-11-25) string.format calls the C runtime: Windows prints "i.nf" for "%#.0e" of infinity, glibc "inf". Roblox servers are Linux, clients mostly Windows, so printf-like code must not hand non-finite numbers to string.format (engine/_port/libc.luau format1 does them itself). Lune on Windows found it; CI (Linux) could not.
- **G-052** (read 2026-11-25) Open Cloud can archive assets: `POST /assets/v1/assets/{id}:archive` (no body, scope asset:write, beta) → `"state": "Archived"` (gone from the website, not usable in experiences); `...:restore` undoes it. `GET /assets/v1/assets/{id}?readMask=moderationResult,state` shows both states; GETs are rate-limited (429 with x-ratelimit-reset; ~4,100 reads ≈ 20 min). A 1x1 grey JPEG was Rejected while 1x1 colour swatches were Approved: moderation of tiny images is not predictable. **Tried: only Audio can be archived; Image answers 400 "not an archivable asset type" → dashboard only.** tools/upload/check_assets.py, archive_assets.py.
- **G-057** (2026-11-25) Trace port notes. (a) A C generator may `#include "model_brush.c"` itself to call its static functions (tools/testgen/trace_vectors.c); it must then define `loadmodel` and `developer_extra`, and set cvar `.integer` / `.value` by hand (they are 0 until Cvar_RegisterVariable). (b) The same holds in the port: collision.cv / model_brush.cv are 0 until Collision_Init / Mod_BrushInit run (host.luau calls them; tests call them after cvar.reset()). (c) Collision_BoundingBoxOfBrushTraceSegment uses min() for maxs too (engine bug, kept). (d) A degenerate triangle sets the triangle brush's numplanes to 0 and it is still traced (edge planes only), and numplanes stays 0 for the following triangles of a mesh until a good one sets it back to 5 (kept). (e) C's min(a,b)/max(a,b) macros return b on ties (-0 vs 0), math.min/max return the first: harmless where a +-1 follows, check it if a sign-of-zero mismatch ever shows up.
- **G-058** (2026-11-26) Luau's math.sin / math.cos call the host C library: on Windows they differ from glibc by one ulp for about 3 % of inputs (277 cos / 315 sin of 9,761 yaws in tests/vectors/svmove.tsv). No float result of walkmove / SV_StepDirection changed in the vectors, but it can, and Roblox servers and clients run different C libraries. Fixed 2026-11-26 by engine/_port/libm.luau (glibc 2.43, FMA build; task PORT-LIBM): engine code must call libm.sin / cos / tan / asin / acos / atan / atan2 / pow / log, never math.* or `^`. Also: string.format of non-finite numbers is host-specific ("-nan(ind)" on Windows) -- use libc.format1.
- **G-059** (2026-11-27) In Lune every `require()` call resolves its path again (0.5-0.8 ms): a `require` inside a hot function (needed where modules would form a load loop) made a server frame take 113 ms instead of 18. Keep the module in an upvalue after the first call (`local m; local function M() m = m or require(...) return m end`). Roblox caches ModuleScript requires, but keep the pattern anyway.
- **G-060** (2026-11-27, measured in Studio, edit mode) The server engine runs in Roblox: stormkeep + 4 bots boot in 95 s, a frame takes 4-15 ms. Studio stops a script after 10 s without a yield (`settings().Studio.ScriptTimeoutLength`): long engine calls must run in a coroutine with yield points (tools/studio/botmatch/BotMatch.luau). EditableMesh → CreateMeshPartAsync, Heartbeat and MCP screen capture work in edit mode. An 84 MB local .rbxl with 1,461 data modules opens; Luau heap 1.96 GB with all files as base64 modules (not shippable: M1-RTVFS). MCP `execute_luau` calls time out near 100 s.
<!-- /§GOTCHAS -->
