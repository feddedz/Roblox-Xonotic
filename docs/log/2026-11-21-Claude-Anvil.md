# Session 2026-11-21 Claude-Anvil

## Goal
CHAT-SETUP, ROSTER, AUDIO-PLAN (owner specs of 2026-11-21), then M2-RUNNER (cvar.c, config exec, rest of PRVM_Prog_Load).

## Done
- PR #1 found still open (main = fbc549c); work continues on claude/sweet-mccarthy-t05j7g (contains PR #1).
- Cloud env: Default had no dl.xonotic.org (proxy 403) → created personal env "Roblox-Xonotic" (dl.xonotic.org,
  create.roblox.com, apis.roblox.com; setup script tools/bootstrap.sh, unproven until a fresh session).
- CHAT-SETUP/ROSTER: tools/chat.sh (read/post/register/status/roster/names), chat on main in docs/chat/, posted
  via private worktree, chat-only commits, retry from new main; flock per clone; merge=union. WELCOME.md
  §Sessions + word list; CLAUDE.md steps 1/2/4/5; D-021; G-029. Tested: 8 concurrent posts from 2 clones.
- M1-VFS bug: 1,927 pk3 entries are zip symlinks, extracted as link text. vfs.py now follows them like
  FS_OpenReadFile (G-031); manifests regenerated (column symlink_to).
- AUDIO-PLAN: tools/sounds/audio_plan.py → assets/manifest/audio-plan.tsv; docs/subsystems/audio.md;
  805 unique sounds; all-packable packing → 410 uploads; lossless FLAC packs verified sample-identical;
  quota endpoint found (Open Cloud v2 asset-quotas, G-030); P-AUDIOSLICE Studio probe (key 5) + test pack.
- M2-RUNNER: engine/cvar.luau (full cvar.c), engine/cmd.luau (cmd.c except client forwarding/csqc/
  completion), engine/fs.luau, filematch.luau, common.luau, console.luau (partial), engine/_port/libc.luau
  (atof/strtol/atoi/(int) cast checked against real glibc vectors).
- M2-RUNNER (settings complete): tools/engine/gen_cvars.py → engine/_port/sv_init_defs.luau (488 cvars,
  132 commands of the dedicated Host_Init path); engine/host.luau Host_Init_Dedicated runs the real quake.rc
  chain (36 files, 6,075 cvars); host_cmd MaxPlayers_f; PRVM_Prog_Load autocvars (3,308, 0 mismatches);
  prvm_cmds cvar builtins; PRVM_SetTempString. Worldspawn with real cvars: interpreter == AOT, stops at the
  first string-builtin stub ("Bad string").

- Later (owner request): Open Cloud key as env network secret (pasted key: owner told to revoke); live quota
  1,970 → no packing (G-036); M1-SOUNDS uploader; 805/805 uploaded; 2 silent 4-sample files padded (DIFF-004,
  G-037); moderation: 756 approved, 36 reviewing, 13 rejected (Q-013).

- Late: texture uploader (byte-for-byte jpg, resumable, unattended runner); owner account warnings → gore list via
  CLIP + visual review (98 incl. all splat kill-feed icons); account suspended 1 day (G-042), uploads stopped, appeal
  texts given. Server boot for Studio: configs + progs.dat packed (tools/pk3/pack_runtime.py), XonoticServer report.

## Files changed
tools/chat.sh, docs/chat/README.md, WELCOME.md, CLAUDE.md, HANDOFF.md, .gitattributes, tools/pk3/*,
assets/manifest/*, tools/sounds/*, docs/subsystems/audio.md, tests/studio/*, engine/*.luau,
engine/_port/libc.luau, tests/unit/{libc,cvar_cmd}.test.luau, tests/vectors/libc.tsv, tools/testgen/libc_vectors.*,
tools/engine/check_port_lines.py, tools/engine/gen_cvars.py, engine/_port/sv_init_defs.luau,
engine/{host,host_cmd,prvm_cmds}.luau, tests/_lib/vfs_provider.luau, tests/integration/{config_load,sv_config_worldspawn}.test.luau,
docs/subsystems/server-runner.md

## Tests run and results
lune run tests/run.luau: 10 files, 0 failed (qcaot_diff 25,509 functions 0 mismatches; config_load;
sv_config_worldspawn; sv_vm_setup). Python: 22 OK.
StyLua/Selene clean. check_port_lines.py: 0 wrong.

## Diffs added or closed
None.

## Decisions
D-021 (chat/names). Q-011 (server settings), Q-012 (Open Cloud key) opened; REF-CVARLIST task added.
G-030..G-034. DarkPlaces quirks kept: `exec dir/*.cfg` runs files in reverse sorted order (each
Cmd_Exec inserts at the buffer front); unquoted `$var` keeps `\"` escapes.

## Problems / dead ends
creator-docs site pages are JS-rendered; the OpenAPI JSON in Roblox/creator-docs (cloud.docs.json) has the
quota endpoint.

## Next step
Owner: Studio Play → BOOT REPORT. Uploads only after the review step and owner OK. M2-RUNNER: string builtins (strcat, ftos, stof, strzone/strunzone with PRVM_AllocString, substring, ...),
then PRVM_FindOffsets/PROGHEADER_CRC branch and edicts (docs/subsystems/server-runner.md).
