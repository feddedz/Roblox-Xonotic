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
## §STATUS (rewritten 2026-11-21, Claude-Anvil, finished)
- **Milestone:** M0 done; M1 partly (VFS incl. pk3 symlinks G-031, manifests, shaders, audio plan); M2: interpreter +
  AOT done; M2-RUNNER partial (unclaimed): a dedicated server's settings are complete — cvar.c/cmd.c ported,
  488 engine cvars + 132 commands registered like Host_Init, real quake.rc chain (36 files, 6,075 cvars, 2 s),
  all 3,308 autocvar globals equal their cvars, cvar builtins ported; worldspawn runs identically interp/AOT
  until the first string builtin stub (`Bad string`).
- **Coordination:** session chat + roster on `main` (docs/chat/, tools/chat.sh, WELCOME.md, D-021).
- **Build:** `tools/build.sh` → game/generated (never committed, D-020).
- **Tests:** 10 Lune files (4 need game data), 22 Python tests; StyLua/Selene clean; tools/engine/check_port_lines.py 0 wrong.
- **In progress elsewhere (do not take):** REF-DP (branch REF-DP-instrumented-build), M3-BSPLOAD (branch M3-BSPLOAD-collision).
- **PRs:** feddedz/Roblox-Xonotic#1 still open (not merged as of this session); this branch contains it.
- **Open owner points:** Q-007 gore (deferred), Q-009 assists/game passes, Q-010 client code size, Q-011 server
  settings, Q-012 Open Cloud key; P-AUDIOSLICE [needs Studio] before any packing.
- **FPS / server tick:** not measurable yet (PERF-SVBENCH [needs Studio]).
- **Next step:** M2-RUNNER string builtins + tempstrings/zone strings, then edicts (docs/subsystems/server-runner.md).
<!-- /§STATUS -->

<!-- §RULES -->
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
checked in Roblox Studio (nobody has it now): prefer headless tasks. Claim = edit + commit + push
before working. One claimed task per subsystem at a time. Details per task in the linked subsystem doc.

| ID | Title | Status | Files | Deps |
|---|---|---|---|---|
| M0-SETUP | Layout, CLAUDE.md, HANDOFF.md, Rojo, Lune runner, lint/format, CI, README | done | * | — |
| M0-F32 | float32 approach + verified helper | done | engine/_port/f32.luau, tests/unit/f32* | — |
| M0-PIN | Version pin + checksums + tick rate | done | §DECISIONS, tools/release/ | — |
| M1-VFS | pk3 VFS resolution (fs.c order) + manifests for both builds | done | tools/pk3/, assets/manifest/ | M0-PIN |
| M1-SHADERS | Parse every shader script → structured table + docs/shaders.md | done | tools/shaders/, assets/data/shaders.json | M1-VFS |
| M1-RTVFS | Runtime VFS on Roblox: ship engine-read files (bsp, cfg, txt, shader, progs data) as Rojo-syncable chunks; verify script/string size limits | open | tools/pk3/, platform/storage, engine/fs.luau | M1-VFS |
| M1-TEX | Texture converter: jpg/tga/png + `_alpha` merge exactly as image.c; tile > max size; never downscale | open | tools/textures/ | M1-VFS, Q-002 |
| M1-LMAP | Lightmap + deluxemap extraction from Q3 BSP at full res | open | tools/bsp/ | M1-VFS |
| M1-BSP | Q3 BSP → render meshes (split ≤20k tris/≤60k verts), per-surface material refs | open | tools/bsp/ | M1-VFS |
| M1-MODELS | MD3/IQM/DPM/ZYM/OBJ/ASE/SP2 → meshes, skins, animations (framegroups) | open | tools/models/ | M1-VFS |
| M1-SOUNDS | Sound pipeline: uploader for assets/manifest/audio-plan.tsv (rate, loop points, packs already planned: docs/subsystems/audio.md), fill asset_id, runtime vpath→asset lookup | open | tools/sounds/ | M1-VFS |
| M1-UPLOAD | Open Cloud uploader + `assets/manifest/roblox-ids.tsv`; key via env var, never committed | open | tools/upload/ | M1-TEX, Q-004 |
| M2-PROGS | progs.dat reader (all 3 .dat) + CFG/reducibility analysis | done | tools/qcaot/progs.py, cfg.py | M1-VFS |
| M2-INTERP | Straight port of prvm_exec.c + prvm_execprogram.h (reference interpreter for AOT diffing) | done (29 semantic tests) | engine/prvm_exec.luau | M2-PROGS |
| M2-AOT | QC bytecode → Luau AOT compiler (f32 globals/fields in buffers, one Luau fn per QC fn); docs/subsystems/qcvm.md | done v1 (all 25,509 functions == interpreter) |
| M2-AOT-STRUCT | Structured control flow for reducible CFGs (performance only; must pass qcaot_diff unchanged) | open | tools/qcaot/ | M2-AOT |
| CHAT-SETUP | Shared session chat (docs/chat/, one append-only file per UTC day, posted to `main` by tools/chat.sh; D-021) | done (Claude-Anvil 2026-11-21) | — | — |
| ROSTER | Session names Claude-<Word> (WELCOME.md list) + docs/chat/roster.md (name, start, task, status); D-021 | done (Claude-Anvil 2026-11-21) | — | — |
| AUDIO-PLAN | Audio upload plan: one asset per sound; if over the 30-day quota pack short sounds by group with 0.5 s gaps; dedupe by checksum; manifest slices; related: M8-SOUND, M1-SOUNDS; docs/subsystems/audio.md, tools/sounds/audio_plan.py | done (Claude-Anvil 2026-11-21); packing waits for P-AUDIOSLICE [needs Studio] | docs/subsystems/ | — |
| PERF-SVBENCH | **[needs Studio]** Benchmark compiled server QC in a Roblox server with native codegen: SV_Frame cost at 30 Hz, worst case per frame (early answer to "does the tick keep up") | open | tests/studio/, game/generated/ | M2-RUNNER |
| CONTROLS-ASSIST | Console/mobile controls + assists (DIFF-002) | blocked (Q-009) | platform/input | Q-009 |
| GAMEPASSES | Game passes (DIFF-003) | blocked (Q-009), much later | — | Q-009 |
| M2-AOT-SHIP | Ship generated code: build step + Rojo mapping + 190k-char modules done (D-020); **[needs Studio]** confirm rojo serve/publish with 380 modules, client load time + memory | partial | tools/qcaot/, game/generated/ | M2-AOT |
| M2-INTERP-DEBUG | Port tracing/profiling/coverage/watchpoints of prvm_exec.c (console commands use them) | open | engine/prvm_exec.luau | M2-INTERP | tools/qcaot/, game/generated/ | M2-PROGS |
| M2-RUNNER | Headless runner: rest of PRVM_Prog_Load (required fields/globals of svvm, field lookup), edict alloc, strings, all builtins stubbed + logged; done = server QC runs worldspawn on a stock map | partial, unclaimed (Claude-Anvil 2026-11-21: settings done — cvar.c/cmd.c, dedicated Host_Init registrations, quake.rc chain, autocvars, cvar builtins; next: string builtins, edicts, docs/subsystems/server-runner.md) | tests/, engine/prvm_*.luau, engine/sv_main.luau, engine/svvm_cmds.luau | M2-AOT, M2-INTERP |
| M2-DEBUG | Rebuild progs.dat from qcsrc with the pinned gmqcc; prove byte-identical; emit line-number debug info | open | tools/qcaot/ | M2-PROGS |
| REF-CVARLIST | From REF-DP's dedicated server after startup: `cvarlist` (name/value/default/flags) and `cmdlist` → tests/reference/cvars/; diff against engine/host.luau's result (validates tools/engine/gen_cvars.py and the config chain) | open | tests/reference/cvars/, tests/integration/ | REF-DP, M2-RUNNER |
| REF-DP | Instrumented DarkPlaces (from release source) that records traces, server frames, net messages, particles | open | tools/darkplaces-ref/ | M0-PIN |
| M3-BSPLOAD | Port model_brush.c (Q3 BSP), model_shared.c, bih.c, collision.c; headless reads work/vfs-high (Roblox runtime loading needs M1-RTVFS later) | open | engine/ | M1-VFS |
| M3-TRACEREF | Record ≥1000 traceline/tracebox per stock map from REF-DP | open | tests/reference/traces/ | REF-DP |
| M3-TRACE | Port world.c/sv traces; bit-identical vs M3-TRACEREF on all stock maps | open | engine/ | M3-BSPLOAD, M3-TRACEREF |
| M4-* | Server: sv_phys/sv_main/sv_user/sv_move, prvm_*, svvm_cmds builtins, host loop; bot match frame-diff | open (split when M3 done) | engine/ | M2-RUNNER, M3-TRACE |
| M5-* | Client: map render, models, input, CSQC + prediction, camera/viewmodel (CPU logic headless; visual check **[needs Studio]**) | open (split later) | engine/, platform/render, platform/input | M1-*, M4 |
| M6-NET | DarkPlaces message layer on RemoteEvents, fragmentation, byte-match | open | engine/netconn, platform/net | M4 |
| M7-* | 2D draw builtins, menu.dat, fonts, DataStore persistence, Credits & License entry | open | engine/, platform/ | M2, M5 |
| M8-SOUND | Channels, attenuation, spatialisation, timing | open | engine/snd_main, platform/sound | M1-SOUNDS |
| M9-* | Dlights, shader stages, particles/decals/beams, post-processing (sims headless; screenshot passes **[needs Studio]**) | open | platform/render | M5 |
| TOOL-SHOTDIFF | Screenshot diff tool + camera position list per map + effect scenes | open | tools/shotdiff/, tests/reference/screens/ | — |
| REF-SHOTS | Capture Ultra reference screenshots from real Xonotic 0.8.6-high | open | tests/reference/screens/ | TOOL-SHOTDIFF |
| POLICY-1 | Content-ratings questionnaire (owner, from docs/policy/gentle-mode.md) | deferred by owner (Q-007) | docs/policy/ | — |
| CONTENT-POLICY | Switch module (done) + wiring: locked cvars after config load, VFS placeholders, gore-group loader | partial (module done) | platform/contentpolicy, engine/fs, engine/cvar | M1-RTVFS, M7-* |
| GORE-ASSETS | Classify gore-only assets (gib models+skins, gore sounds, gore-only particle-atlas tiles, stains, damage flash) → `assets/optional/gore/manifest.tsv`; same-name placeholder models/sounds for `removed` (D-019): identical load/precache order and index numbers, no server missing-model error | open | tools/, assets/optional/gore/ | M1-VFS |
| GORE-MODE-TESTS | Server frame-diff + net byte tests identical in all 3 modes; `removed` runs with zero missing-asset errors | open | tests/ | M4, CONTENT-POLICY, GORE-ASSETS |
| GENTLE-TESTS | Differential tests for both paths: gib/blood messages and effects with cl_gentle 0 and 1 match real DP | open | tests/ | M4, M9 |
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
- **Q-012 (2026-11-21, Claude-Anvil) Roblox Open Cloud API key + user/group id for audio.** Needed to read the
  30-day audio quota (scope asset:read) and later upload (asset:write). The key is entered through the
  session's secure credential form (never in chat or the repo) when M1-SOUNDS starts.
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
<!-- /§GOTCHAS -->
