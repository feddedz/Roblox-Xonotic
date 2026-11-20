# platform/: Roblox backends

The engine port calls the same entry points the C code calls; `platform/` implements the OS-facing ones.

| Backend | Replaces | Roblox mechanism (to verify in docs before use) |
|---|---|---|
| render | gl_backend.c, gl_textures.c, GL parts of gl_rmain/gl_rsurf/gl_draw/r_shadow, vid_* | MeshPart/EditableMesh, SurfaceAppearance, Beams, lights, post effects, GUI for 2D |
| sound | snd_mix.c output, snd_sdl.c | Sound / AudioPlayer instances driven by ported snd_main.c channel logic |
| net | lhnet.c sockets | RemoteEvent (reliable), UnreliableRemoteEvent (unreliable, ≤1000 B payload, G-003) |
| input | vid_sdl.c events, mouse | UserInputService / ContextActionService, raw mouse delta |
| storage | fs.c write paths (config.cfg, binds, stats) | DataStoreService per player (G-010) |
| boot | sys_sdl.c main loop, Sys_DirtyTime | Script / LocalScript entry points, RunService stepping, os.clock |

Rules: no gameplay or simulation logic here; anything that could change behaviour lives in `engine/`
and is differential-tested. Each backend logs `NOT YET PORTED: <name>` for anything missing.
