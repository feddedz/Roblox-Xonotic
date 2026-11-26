# 2026-11-25 Claude-Quartz — M3-BSPLOAD (part 1 and 2)

## Goal
Owner: "just make the game", work in the background on his PC with Studio. First task on the critical path:
M3-BSPLOAD (Q3 BSP loading + collision data), ported line by line and checked against the C code.

## Done
- Release source fetched on the owner's PC (work/source, sha512 = pin).
- engine/bih.luau: bih.c complete.
- engine/polygon.luau: PolygonD_QuadForPlane, PolygonD_Divide.
- engine/collision.luau: Collision_NewBrushFromPlanes (+ ValidateBrush, PrintBrushAsQHull,
  furthestplanedist_float). Keeps the engine's edgedirs/elements memory overlap (G-056).
- engine/curves.luau: curves.c complete.
- engine/model_shared.luau: Mod_BuildTextureVectorsFromNormals, Mod_AllocSurfMesh, Mod_SnapVertices,
  Mod_RemoveDegenerateTriangles.
- engine/matrixlib.luau: Matrix4x4_Concat, CreateTranslate, CreateScale3, ConcatTranslate.
- engine/model_brush.luau: Mod_IBSP_Load / Mod_Q3BSP_Load up to the submodel loop; lump loaders entities,
  textures (lump fields only), planes, brush sides (+IG), brushes (colbrushf built), effects, vertices,
  triangles, faces (flat / mesh / patch with collision geometry and bboxes), models, leaf brushes, leaf faces,
  leafs, nodes (+ RecursiveSetParent), light grid, PVS; contents mapping; RecursiveFindNumLeafs.
- Reference vectors from the real C source through GitHub Actions (.github/workflows/testgen.yml, G-054).

## Files changed
engine/{bih,polygon,collision,curves,model_shared,matrixlib,model_brush}.luau, tests/unit/{bih,collision,
curves}.test.luau, tests/integration/q3bsp_load.test.luau, tests/vectors/{bih,collision,curves,q3bsp}.tsv,
tools/testgen/{bih,collision,curves}_vectors.{c,sh}, tools/testgen/q3bsp_vectors.py,
.github/workflows/testgen.yml, tools/upload/__init__.py, HANDOFF.md, docs/gotchas.md, this log.

## Tests run and results
- Lune (Windows, owner's PC): 18 test files, 0 failed. bih 456 checks, collision 3,522 (210 brushes), curves
  1,279: all bit-identical to the C build. q3bsp_load: 30 maps, 81,874 checks, 31 s; 216,797 brushes built,
  3 rejected exactly like C would (too few planes left).
- StyLua, Selene clean; check_port_lines 0 wrong; Python unit tests 26 run (3 Windows-only errors in
  tools/pk3/test_vfs.py, unrelated).

## Diffs added or closed
None.

## Decisions
None new.

## Problems / dead ends
- Installing a C compiler on the owner's PC was refused by the app; solved with the Testgen workflow.
- gcc on the runner defaults to C23 (`false` keyword): -std=gnu11.
- PowerShell ate the backticks of Luau strings written through `python -c` (G-055).
- First q3bsp reference in plain Python was quadratic (re-sliced lumps in loops) and never finished; fixed.
- math.ceil gives -0 in Luau where C's (int)ceil gives 0: `+ 0` after the conversion (light grid imins).

## Part 3 (same day)
- Mod_MakeCollisionBIH + the submodel loop of Mod_Q3BSP_Load (bounds, radii, sorted surfaces, collision and
  render BIH per submodel) + model_shared.c Mod_MakeSortedSurfaces. q3bsp_load: 84,795 checks, 42 s for 30
  maps; 2.0 M BIH leafs. MATERIALFLAG_MESHCOLLISIONS surfaces are not in the collision BIH yet (needs
  Mod_LoadTextureFromQ3Shader: basematerialflags are 0). Memory note: a BIH leaf is 3 Luau tables; the render
  BIH of a big map is ~1 M leafs. model_brush.build_render_bih = false skips it; a buffer layout for bih leafs
  would be a pure representation change if Roblox memory needs it.
- Debug viewers: tools/studio/export_surfaces.luau + render_map.py (headless picture; stormkeep correct, sent
  to the owner) and tools/studio/mapview (Studio MeshParts; ran: 49 parts, load 0.7 s). The Studio window
  opened from the built .rbxl had no 3D viewport on the owner's PC (ViewportSize 1x1, panels doubled), also
  after Window > Reset Layout; closed it. The owner's cloud Xonotic Studio window was not touched.
- PR 5 (part 1-2) merged into main.

## Part 4 (same day): traces
- collision.c: Collision_Init (cvars), nearestplanedist_float, Collision_CalcEdgeDirsForPolygonBrushFloat,
  Collision_CalcPlanesForTriangleBrushFloat (three side-plane modes), Collision_TraceBrushBrushFloat,
  Collision_TraceLineBrushFloat, Collision_PointInsideBrushFloat, Collision_TracePointBrushFloat,
  Collision_SnapCopyPoints, Collision_TraceBrushTriangleMeshFloat, Collision_TraceLineTriangleMeshFloat,
  Collision_TraceBrushTriangleFloat, Collision_BrushForBox, Collision_TraceLineTriangleFloat,
  Collision_BoundingBoxOfBrushTraceSegment; trace_t (collision.newtrace / cleartrace).
- model_brush.c: Mod_BrushInit (the 4 trace cvars), Mod_CollisionBIH_TracePoint / TraceLineShared / TraceLine /
  TraceBrush / TraceBox / PointSuperContents / TraceLineOfSight / TraceLineAgainstSurfaces / *_Mesh,
  Mod_Q3BSP_TracePoint / TraceLine / TraceBrush / TraceBox / PointSuperContents (BIH, submodel brush list and
  BSP-tree recursion paths), Mod_Q3BSP_TraceLineOfSight(+RecursiveNodeCheck); mathlib.c BoxOnPlaneSide. The
  loader now sets the model's trace function pointers. host.luau calls Collision_Init and Mod_BrushInit.
- Reference: tools/testgen/trace_vectors.c includes model_brush.c (statics reachable), builds a synthetic map
  (70 brushes, 4 patch-like surfaces with strides 16 / 0 / -1 / 4, a 120-node BSP tree, a submodel) and runs
  the real C functions: 5.8k lines in tests/vectors/trace.tsv. tests/unit/trace.test.luau: 4,905 checks, every
  trace_t field bit-identical, on the first run. Cvar variations covered: mod_collision_bih 0/1,
  mod_q3bsp_curves_collisions 0, collision_bih_fullrecursion 1, collision_debug_tracelineasbox 1, both other
  triangle side-plane modes, mod_q3bsp_optimizedtraceline 0, mod_q3bsp_tracelineofsight_brushes 1.
- Stock maps: tests/integration/q3bsp_trace.test.luau (stormkeep, dance, afterslime, xoylent + submodels):
  1,296 BIH traces equal a plain loop over all leafs; the BSP-tree path equals the BIH on 1,294 of 1,296; a
  player box dropped from 77 of 77 spawn points lands on a floor.
- Tests: 20 Lune files, 0 failed (trace 4,905, q3bsp_trace 662, q3bsp_load 84,795); StyLua / Selene clean;
  check_port_lines 0 wrong; Python 26 run (same 3 Windows-only errors).

## Part 5 (same day): Q3 shader scripts
- PR 7 (traces) merged into main. Branch M3-BSPLOAD-shaders.
- common.c COM_ParseToken_QuakeC (its C body is identical to COM_ParseToken_VM_Tokenize). model_shared.c:
  Mod_LoadQ3Shaders_EnumerateWaveFunc, Mod_FreeQ3Shaders, Q3Shader_AddToHash, Mod_LoadQ3Shaders (custinfoparms,
  layers, every general keyword), Mod_LookupQ3Shader; q3shaderinfo_t as tables (see the comment above newlayer).
  Kept quirks: the parameter array is never cleared (keywords that read past their line see older values);
  in the first shader file only, a `}` that ends a parameter line also ends the shader; names are cut to 63
  characters; an empty hash bucket head matches the name "".
- tests/integration/q3shaders.test.luau: all 2,447 shaders of the release agree with the independent parser
  (assets/data/shaders.json): names, layer counts, surfaceparm bits, layer texture names. 3.7 s to parse 706 KB
  (the tokenizer is slow: one table.insert per character; a pure speed rewrite is possible later).
- Mod_CreateShaderPass, Mod_CreateShaderPassFromQ3ShaderLayer, Mod_LoadTextureFromQ3Shader ported;
  Mod_Q3BSP_LoadTextures calls it (then restores the lump's surfaceflags / supercontents, as C does, so
  collision contents do not change). Textures now have basematerialflags (sky / nodraw / wall / blend /
  MESHCOLLISIONS ...), shader passes, deforms, water / offset / gloss values; loadmodel.brush.skybox is set.
  Renderer calls (R_SkinFrame_LoadExternal / LoadMissing, R_GetCubemap) are hooks on model_shared: dedicated
  behaviour (NULL skin frames) is exact, a client backend replaces them. No release shader uses
  dpmeshcollisions, so the collision BIH of the stock maps is unchanged.
  q3shaders test: stormkeep 58 textures, 52 with a shader, sky / nodraw / wall flags follow the shader,
  skybox env/extragalactic/asteroids_. **A map must be loaded with the VFS provider set** (shader scripts
  come through engine/fs.luau), otherwise every texture takes the no-shader path.
- NOT yet checked against the C build (parser and texture setup): needs a generator with fixture shader
  files and stubbed FS_Search / FS_LoadFile, because the runner has no game data.

## Part 6 (same day): clipping against the world and entities
- PR 8 (shaders) merged into main. Branch M3-BSPLOAD-clip.
- collision.c: Collision_TranslateBrush, Collision_TransformBrush, Collision_ClipExtendPrepare / Finish,
  Collision_ClipToGenericEntity, ClipToWorld, ClipLineToGenericEntity, ClipLineToWorld,
  ClipPointToGenericEntity, ClipPointToWorld, Collision_CombineTraces. model_brush.c: Collision_ClipTrace_Box /
  _Point (stored into the collision module at load: collision cannot require model_brush). matrixlib.c:
  Matrix4x4_Invert_Simple, CreateIdentity, CreateFromQuakeEntity, Transform, TransformPositivePlane.
- trace_vectors.c now also runs 180 scenes: a world trace (box / line / point, with `extend`), then three
  entities (the submodel under an entity matrix with yaw / pitch / roll / scale, or a plain box body) and
  Collision_CombineTraces after each. tests/unit/trace.test.luau: 8,685 checks, all bit-identical, including
  the 540 entity matrices built with the platform's sin / cos (CreateFromQuakeEntity) and trace endpos.
- This is everything SV_TraceBox / SV_TraceLine / SV_TracePoint call below the area grid.

## Next step
1. M3-TRACE: world.c area grid (World_SetSize, World_LinkEdict, World_EntitiesInBox, ...), sv_phys.c
   SV_GenericHitSuperContentsMask / SV_TracePoint / SV_TraceLine / SV_TraceBox / SV_PointSuperContents /
   SV_EntitiesInBox / SV_LinkEdict, then the world builtins (traceline, tracebox, pointcontents, droptofloor,
   setorigin, setsize, findradius ...) that M2-RUNNER waits for. Needs the model registry for brush entities
   (`*N` submodels: brush.submodels) -- port Mod_FindName / Mod_ForName or wire SV_GetModelByIndex first.
2. C reference for Mod_LoadQ3Shaders + Mod_LoadTextureFromQ3Shader: tools/testgen/shader_vectors.c with fixture
   .shader files (tests/fixtures) and stubbed FS_Search / FS_LoadFile; print every q3shaderinfo_t field and
   the texture fields. Plan: the generator `#include "model_shared.c"` (q3shader_data is static), links
   common.c + com_crc16.c, stubs FS_Search / FS_LoadFile / FS_FreeSearch (read tests/fixtures/shaders/ in a
   fixed sorted order), Mem_* incl. Mem_ExpandableArray_*, Cvar_VariableValue (a small table the test also
   registers), R_SkinFrame_LoadMissing / R_GetCubemap (NULL), and defines cls (ca_dedicated), developer_* and
   the mod_q3shader_* cvars. Fixtures to write: a_first.shader (the fileindex 0 `}` quirk), b_layers.shader
   (every layer keyword, > 8 layers, > 8 tcmods, stale parameters after short lines, user wave funcs, quotes,
   comments, CRLF / lone CR), c_general.shader (every general keyword and surfaceparm, dp_ remap, all
   dpshaderkill forms, 63-character names, empty name), d_redeclare.shader (redeclarations, killed / replaced,
   missing `{`, end of file inside a body), custinfoparms.txt. Luau side: a fixture provider for fs.SetProvider
   ({ files, load, pack }, see tests/_lib/vfs_provider.luau).
3. Mod_Q3BSP_LoadLightmaps, the model registry (Mod_FindName / Mod_ForName).
4. Speed: the tokenizer (3.7 s for the 706 KB of shader scripts); memory layout of BIH leafs for Roblox.
