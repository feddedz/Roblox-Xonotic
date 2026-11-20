# Decisions: full text

HANDOFF.md §DECISIONS keeps one line per decision; this file holds the full wording. Same rules: never
contradict a decision; add a new one that supersedes it, in both places.

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

**D-002 (2026-11-20) Two builds, one version; textures come from `-high`.** Verified: all 3 `.dat` files
and every non-texture file are byte-identical between `xonotic-0.8.6.zip` and `-high.zip`; only texture
encoding differs (standard: S3TC DDS; high: original JPEGs + `_alpha` JPEGs). The Ultra preset
(`effects-ultra.cfg`) sets `r_texture_dds_load 0`, `gl_texturecompression_2d 0`, `gl_picmip -1`, i.e. it
loads uncompressed originals at full resolution, which exist only in `-high`. So textures come from
`work/vfs-high/`, everything else may come from either. Reference screenshots: `-high` at Ultra. (Q-001)

**D-003 (2026-11-20) Engine source of truth** = `Xonotic/source/darkplaces/` in the release zip, verified
byte-identical to darkplaces tag `xonotic-v0.8.6`; `source/qcsrc` identical to xonotic-data tag. Line
numbers in `-- port:` comments refer to these files.

**D-004 (2026-11-20) Float32 approach.** Luau numbers are doubles. Rules: (a) round to f32 after every C
float operation (+,−,×,÷,sqrt): one IEEE op in double then one rounding equals the float op exactly
(binary64 has ≥2·24+2 bits); multi-op expressions round after each op in C evaluation order; (b) every
store into a float variable/field/global rounds — QC globals and entity fields live in `buffer` f32 slots,
which round on write; (c) C `double` values (realtime, sv.time, cl.time…) are not rounded; (d) the
reference build is x86-64 SSE without FMA contraction, so never fuse multiply-add. Helper
`engine/_port/f32.luau` (`f32.round` = `buffer.writef32/readf32`); `vector.create(x,0,0).x` is equivalent
(Luau vector components are float32 and vector `+ - *` are computed in float). Both verified bit-exact
against numpy float32 on 12,025 vectors. Details: `docs/subsystems/float32.md`.

**D-005 (2026-11-20) Tick rate.** `sys_ticrate 0.0333333` (30 Hz; `xonotic-common.cfg` L81 overrides the
engine default). Client: `cl_netfps 60`, `cl_movement 1` (prediction, server runs player physics per input
packet), `cl_maxfps 250` (`xonotic-client.cfg`). The Roblox server must sustain 30 Hz SV_Frame plus
per-move player physics.

**D-006 (2026-11-20) Tooling.** Lune 0.11.1, Rojo 7.7.1, StyLua 2.6.0, Selene 0.31.0 (`rokit.toml`,
`tools/bootstrap.sh`); offline converters in Python 3 (`tools/requirements.txt`); Selene std `xonotic_std.yml`.

**D-007 (2026-11-20) Requires** use relative string paths only (`./`, `../`, `@self/`), no aliases — same
resolution in Lune and in Roblox's require-by-string (verified: Roblox docs + Lune test).

**D-008 (2026-11-20) Units.** Engine in Quake units; studs only in `platform/render` via one constant (M5; G-007, G-009, Q-005).

**D-009 (2026-11-20) Visual reference** = `-high` build, Ultra preset (`effects-ultra.cfg`; docs/subsystems/visual-reference.md).

**D-010 (2026-11-20) Data locations.** Downloads/extracted data in `work/` (gitignored; regenerate with
`tools/release/fetch.sh`, `tools/pk3/manifest.py`). Manifests, generated tables, test vectors are committed.

**D-011 (2026-11-20) Session id** = first 8 chars of the Claude session id; an environment-assigned branch replaces `<task-id>-<name>`.
**D-012 (2026-11-20) `main` is the integration branch** (owner). Sessions work on a branch, PR into `main`.
**D-013 (2026-11-20)** Owner confirmed D-002 (textures and reference screenshots from `-high`); closes Q-001.

**D-014 (2026-11-20, superseded by D-015)** Gentle mode on by default; withdrawn by the owner the same day.
**D-015 (2026-11-20) Supersedes D-014: blood/gore policy deferred by the owner until before publishing.**
No gentle-mode default: `cl_gentle` behaves exactly as in Xonotic (default 0, menu checkbox). DIFF-001
withdrawn. Q-007 (questionnaire, default, locking) stays open until the owner decides.

**D-016 (2026-11-20) Gore is ported in full but isolated** (owner). QuakeC is never edited. Every gore-only
asset goes in a separate group `assets/optional/gore/` with its own manifest, built and uploaded
separately. One switch, `platform/contentpolicy` (`MODE`), selects `player-choice` (Xonotic default),
`forced-gentle` (cl_gentle locked 1) or `removed` (locked 1, gore group never uploaded/loaded, VFS serves
placeholders so precache indices, effect numbers and server model loading stay identical). Changing the
mode touches only that switch. Proof: server frame-diff and net byte tests identical in all modes;
`removed` runs with no missing-asset errors. Server-side gore paths: docs/policy/gentle-mode.md.
**D-017 (2026-11-20) Generated QuakeC is not committed yet.** `game/generated/*/` is gitignored and
regenerated with `tools/qcaot/compile.py work/vfs-high/<prog>.dat game/generated/<prog>` (~65 MB of Luau,
seconds to build). How it reaches Studio (commit, build step, size limits) is task M2-AOT-SHIP.
**D-018 (2026-11-20) Planned differences approved by the owner** (closes Q-008; the HANDOFF intro edit
405c971 was the owner's): console/mobile controls with slight gameplay assists for those inputs only, and
game passes much later. Recorded in §RULES and §DIFFS (DIFF-002, DIFF-003); not built until defined (Q-009).
Keyboard-and-mouse gameplay stays exactly Xonotic. The intro text moved to `WELCOME.md`.

**D-019 (2026-11-20) Gore `removed` mode approved as designed** (D-016): same-name placeholder models and
sounds keep loading, precache order and network index numbers identical; the server never hits a
missing-model error (it loads precached models with crash=true).
**D-020 (2026-11-20) Generated QuakeC is a reproducible build step, never committed** (owner; refines
D-017). `tools/build.sh` fetches the pinned release, extracts and checksums the three .dat files and
compiles them into `game/generated/{progs,csprogs,menu}/` (gitignored except `.gitkeep`). Rojo maps `progs`
to ServerScriptService (server-only, never replicated) and `csprogs`/`menu` to ReplicatedStorage. Generated
modules take their runtime as a parameter (no requires) and stay under 190,000 characters each.
