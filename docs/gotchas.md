# Gotchas: full text

HANDOFF.md §GOTCHAS keeps one line per entry; this file holds the details and sources.

Roblox facts are from create.roblox.com / github.com/Roblox/creator-docs, read 2026-11-20, unless noted.
- **G-001** EditableImage max size 1024×1024; strict client memory budget (server/Studio unlimited).
- **G-002** EditableMesh: max 60,000 vertices and 20,000 triangles (quad = 2). Imported mesh assets: max
  20,000 triangles each (art/modeling/specifications).
- **G-003** UnreliableRemoteEvent payload > 1000 bytes is dropped. RemoteEvent + UnreliableRemoteEvent
  share ~500 requests/s per client (client→server). Non-string table keys are converted to strings.
- **G-004** Image size docs conflict: texture-specifications says "up to 4096×4096", same page's UV
  section says "up to 1024×1024 pixel spaces". Formats: png, jpg, bmp, tga. (Q-002)
- **G-005** `Lighting.Technology`: Future is the most advanced selectable; `Unified`, `Compatibility`,
  `Legacy` are deprecated and cannot be selected.
- **G-006** `Camera.FieldOfView` is vertical, clamped 1–120°. `FieldOfViewMode` (Vertical/Diagonal/…)
  decides what stays fixed on resize. DarkPlaces horizontal FOV f on a 4:3 basis gives vertical
  2·atan(tan(f/2)·3/4), so fov > ~133.4 cannot be shown.
- **G-007** `Camera.NearPlaneZ` is read-only and "currently always between -0.1 and -0.5" studs, varying by
  platform. DarkPlaces `r_nearclip` default is 1 qu.
- **G-008** BasePart Size per axis: 0.001–2048 studs.
- **G-009** PointLight/SpotLight `Range` has no documented maximum in the API reference (Q-005).
- **G-010** DataStore: 4,194,304 characters per key value; per-server request limits and queues of 30.
- **G-011** require-by-string: `./` = script.Parent, `../` = script.Parent.Parent, `@self/` = script,
  `@game/` = game; non-blocking (no WaitForChild). Lune 0.11 resolves identically (init.luau = folder).
- **G-012** Selene `generate-roblox-std` fails in cloud sessions (GitHub raw over its own TLS roots), so we use
  `xonotic_std.yml`. Rokit needs the GitHub API, which is scoped in cloud sessions, so use `tools/bootstrap.sh`.
- **G-013** Cloud network: dl.xonotic.org, create.roblox.com and github.com release downloads need the
  "Roblox-Xonotic" environment allowlist; gitlab.com, PyPI, npm and crates are reachable by default.
  `github.com/<repo>/releases/latest` pages are blocked; only `/releases/download/` works.
- **G-014** Standard-build map textures exist only as `dds/…dds`, sometimes twice (`dds/x.dds` and
  `dds/textures/x.dds`). DarkPlaces' image loader has no DDS fallback; DDS loads only via `r_texture_dds_load`.
- **G-015** DarkPlaces VFS: pk3s sorted with strcasecmp, each prepended → alphabetically last pk3 wins;
  lookups inside pk3 are case-sensitive. 8 paths are shadowed in 0.8.6 (see manifests' last column).
- **G-016** JPEG has no alpha: DarkPlaces loads `<name>_alpha.jpg` as the alpha channel (image.c
  loadimagepixelsbgra). The `-high` build has 2,326 such files; converters must merge them.
- **G-017** Roblox content ratings: an IARC-based questionnaire; uploaded assets with realistic or excessive
  blood can be moderated regardless of rating (Q-003).
- **G-018** SurfaceAppearance map properties (`ColorMapContent`, `NormalMapContent`, …) are write
  `PluginSecurity`: game scripts must use `AssetService:CreateSurfaceAppearanceAsync({ColorMap, NormalMap,
  RoughnessMap, MetalnessMap, EmissiveMask})` (maps fixed at creation; `EmissiveMask` exists for glow maps).
  EditableImages don't replicate: build EditableImage-based appearances on the client.
- **G-019** `Lighting.Technology` is write `RobloxScriptSecurity`: set it in the Rojo project file
  (`$properties`), open the built place; scripts and probably the Rojo plugin can't set it.
- **G-020** ViewportFrame: no shadows, no post-processing, Neon/Glass at lowest quality, environment
  lighting off by default. Limits scripted reflections and FOV stitching (Studio test V2/V3 measures it).
- **G-021** Runtime geometry route: `AssetService:CreateEditableMesh()` → AddVertex/AddUV/AddNormal/
  AddTriangle/SetFaceUVs/SetFaceNormals → `AssetService:CreateMeshPartAsync(Content.fromObject(mesh))`.
  `CreateEditableImage` returns nil when the per-device budget is exhausted. Pixels: `WritePixelsBuffer`, RGBA8.
- **G-022** Lune: `require` needs a relative (`./`, `../`) or `@` path (no absolute paths); dynamic
  string requires work; no Roblox `Random` (use the PRNG in tests/integration/qcaot_diff.test.luau). Lune
  loads all 65 MB of generated QC Luau without hitting compiler limits (largest function 3,921 statements).
- **G-023** Place size: max 100 MB (104,857,600 bytes) for Save/Publish (create.roblox.com/docs/projects/
  place-files, read 2026-11-20). Measured: full place with all generated QC builds to a 14 MB .rbxl.
- **G-024** Script size: Roblox docs state **no** limit. DevForum (unofficial) reports a 200,000-character
  limit when `Script.Source` is set by plugins (Rojo serve syncs through its plugin); ScriptEditorService
  `UpdateSourceAsync` may lift it; very large sources reportedly time out Team Create. So generated modules
  are capped at 190,000 characters (`--chunk-chars`; one function, havocbot_movetogoal, is 193k alone).
  **[needs Studio]** confirm with `rojo serve` and with a built .rbxl.
- **G-025** ReplicatedStorage replicates to every client (scripting/locations docs); DevForum: ModuleScript
  bytecode is sent even if never required. Server-only code (progs) lives in ServerScriptService.
- **G-026** Measured (Lune, optimisation level 1): Luau bytecode ≈ 1.65× source for generated QC: menu
  13.6 MB, csprogs 33.9 MB, progs 61.4 MB; Lua heap after loading ≈ menu 15 MB, csprogs 38 MB, progs 69 MB.
  So each client would download ≈ 48 MB of bytecode and hold ≈ 53 MB for csprogs+menu (Q-010). Control-flow
  scaffolding is ≈ 30% of generated source. Every QC function is referenced by a function-typed global
  constant, so naive dead-code elimination removes 0 functions.
- **G-027** progs.dat (0.8.6) declares builtins #352 registercommand, #566 findbox/findbox_tofield and #608
  parseentitydata, which are NULL in vm_sv_builtins[] (svvm_cmds.c). Real DarkPlaces raises "No such builtin"
  only if one is called; the QC guards them with extension checks. Keep them NULL
  (tests/integration/sv_vm_setup.test.luau pins the list).
- **G-028** Xonotic's progs.dat header crc is 5927 = PROGHEADER_CRC (progdefs.h L166), so SV_VM_Setup's branch
  that takes engine field offsets from the entvars_t struct (PRVM_ED_FindFieldOffset_FromStruct) applies.
- **G-052** (2026-11-25, creator-docs reference/cloud/assets/v1.json + create.roblox.com/docs/cloud/reference/features/assets) Archive Asset: `POST https://apis.roblox.com/assets/v1/assets/{assetId}:archive`, no request body, API key scope asset:read + asset:write, beta. Returns the Asset with `"state": "Archived"`; the docs say archived assets disappear from the website and are no longer usable or visible in experiences, and `...:restore` brings them back. State enum: Unspecified / Active / Archived. No rate limit is documented; in practice GET asset answers 429 with x-ratelimit-reset after a burst (about 4,100 reads took 20 minutes with 3 workers). A 1x1 grey JPEG (gfx/menu/luminos/background_ingame_alpha.jpg) was Rejected while the 1x1 colour swatches in gfx/colors were Approved. Tools: tools/upload/check_assets.py (read-only state of every asset), tools/upload/archive_assets.py (dry run by default). Tried 2026-11-25: archive works for Audio; for Image assets it answers HTTP 400 "Asset <id> is not an archivable asset type", so unused images can only be archived in the Creator Dashboard (assets/manifest/archive-now.tsv).
- **G-053** (2026-11-25, found by running tests/unit/libc.test.luau with Lune 0.11.1 on Windows) Luau string.format forwards to the C runtime snprintf, and runtimes differ for non-finite doubles with flags: Windows (UCRT) prints "i.nf" for "%#.0e" of infinity, glibc prints "inf". Roblox servers run Linux and most clients Windows, so server and client QC could print different text. libc.format1 now formats inf/nan itself (glibc rules: sign from the sign bit or the + / space flag, upper case for E F G, space padding only; #, 0 and the precision are ignored). Linux CI cannot catch this class of bug: run the Lune tests on Windows too.
- **G-058** (2026-11-26) Luau's math.sin / math.cos call the host C library: on Windows they differ from glibc by one ulp for about 3 % of inputs (277 cos / 315 sin of 9,761 yaws in tests/vectors/svmove.tsv). No float result of walkmove / SV_StepDirection changed in the vectors, but it can, and Roblox servers and clients run different C libraries. Needs a pure-Luau, glibc-exact sin / cos (task PORT-LIBM); until then tests/unit/sv_move_libm_ref.test.luau prints the count and fails only when a float move changes. Also: string.format of non-finite numbers is host-specific ("-nan(ind)" on Windows) -- use libc.format1.
- **G-057** (2026-11-25) Trace port notes. (a) A C generator may `#include "model_brush.c"` itself to call its static functions (tools/testgen/trace_vectors.c); it must then define `loadmodel` and `developer_extra`, and set cvar `.integer` / `.value` by hand (they are 0 until Cvar_RegisterVariable). (b) The same holds in the port: collision.cv / model_brush.cv are 0 until Collision_Init / Mod_BrushInit run (host.luau calls them; tests call them after cvar.reset()). (c) Collision_BoundingBoxOfBrushTraceSegment uses min() for maxs too (engine bug, kept). (d) A degenerate triangle sets the triangle brush's numplanes to 0 and it is still traced (edge planes only), and numplanes stays 0 for the following triangles of a mesh until a good one sets it back to 5 (kept). (e) C's min(a,b)/max(a,b) macros return b on ties (-0 vs 0), math.min/max return the first: harmless where a +-1 follows, check it if a sign-of-zero mismatch ever shows up.
- **G-056** (2026-11-25) Engine quirks the port keeps on purpose (found while matching the C build bit for bit): (a) collision.c L384-385 points brush->edgedirs and brush->elements at the same memory, so the triangle elements overwrite the first edge directions and traces read integers as floats there (engine/collision.luau reproduces the bytes); (b) Mod_Q3BSP_LoadFaces counts every patch's control points on top of its tesselated vertices when sizing surfmesh, so trailing mesh vertices are unused zeros.
- **G-055** (2026-11-25) PowerShell eats backticks inside double-quoted `python -c "..."` strings: Luau interpolated strings written that way lose their backticks. Put generated Luau in a file (Write/Edit), never in an inline command.
- **G-054** (2026-11-25) No C compiler on the owner's PC (installing one was refused). Reference vectors are built by .github/workflows/testgen.yml on every push that touches tools/testgen/ (non-main branches): it fetches the pinned source, compiles the generators (`gcc -std=gnu11 -O0 -ffp-contract=off`; DarkPlaces .c files that need the whole engine link with `-ffunction-sections -Wl,--gc-sections -Wl,--unresolved-symbols=ignore-all` and a few stubs) and uploads tests/vectors as the artifact `tests-vectors`. gcc 15 defaults to C23 where `false` is a keyword: DarkPlaces needs -std=gnu11.
