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

## Next step
1. Mod_LoadTextureFromQ3Shader (model_shared.c; basematerialflags / currentmaterialflags decide what collides
   and what the skip masks see), then Mod_Q3BSP_LoadLightmaps, the model registry (Mod_FindName).
2. M3-TRACE: world.c, Collision_ClipToWorld / ClipToGenericEntity / CombineTraces, SV_TraceBox and the world
   builtins (traceline, tracebox, pointcontents, droptofloor) that M2-RUNNER waits for.
3. Memory layout of BIH leafs for Roblox if needed (see part 3).
