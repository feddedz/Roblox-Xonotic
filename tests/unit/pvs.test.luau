--!strict
-- Mod_Q1BSP_FatPVS / Mod_Q1BSP_FindBoxClusters (engine/model_brush.luau, model_brush.c L180-244, L3779-3820) on
-- a hand-made BSP tree:
--   root: plane x = 0      front -> nodeX100, back -> leaf A (cluster 0)
--   nodeX100: plane x = 100 front -> leaf D (solid, cluster -1), back -> nodeY
--   nodeY: plane y = 0     front -> leaf B (cluster 1), back -> leaf C (cluster 2)
-- PVS rows (1 byte per cluster): cluster 0 sees {0, 1}, cluster 1 sees {0, 1, 2}, cluster 2 sees {1, 2}.
-- Expectations derived from the C (no C reference vectors yet).
local t = require("../_lib/t")
local model_brush = require("../../engine/model_brush")

local FatPVS = model_brush.Mod_Q1BSP_FatPVS
local FindBoxClusters = model_brush.Mod_Q1BSP_FindBoxClusters

local function plane(axis: number, dist: number): any
	local n = { 0, 0, 0 }
	n[axis + 1] = 1
	return { normal = n, dist = dist, type = axis, signbits = 0 }
end

return function(ctx: t.Ctx)
	local leafA = { clusterindex = 0 }
	local leafB = { clusterindex = 1 }
	local leafC = { clusterindex = 2 }
	local leafD = { clusterindex = -1 }
	local nodeY = { plane = plane(1, 0), children = { leafB, leafC } }
	local nodeX100 = { plane = plane(0, 100), children = { leafD, nodeY } }
	local root = { plane = plane(0, 0), children = { nodeX100, leafA } }
	local pvs = buffer.create(3)
	buffer.writeu8(pvs, 0, 0x03)
	buffer.writeu8(pvs, 1, 0x07)
	buffer.writeu8(pvs, 2, 0x06)
	local model: any = {
		name = "test.bsp",
		brush = {
			data_nodes = { root, nodeX100, nodeY },
			num_pvsclusters = 3,
			num_pvsclusterbytes = 1,
			data_pvsclusters = pvs,
		},
	}

	-- FindBoxClusters
	local list: { number } = {}
	t.eq(ctx, FindBoxClusters(model, { -10, -10, 0 }, { -5, -5, 0 }, 64, list), 1, "box in leaf A: one cluster")
	t.eq(ctx, list[1], 0, "... cluster 0")
	table.clear(list)
	t.eq(ctx, FindBoxClusters(model, { -5, 5, 0 }, { 5, 10, 0 }, 64, list), 2, "box across x = 0: two clusters")
	t.eq(ctx, list[1], 0, "back side first (cluster 0)")
	t.eq(ctx, list[2], 1, "then the remembered front path (cluster 1)")
	table.clear(list)
	t.eq(ctx, FindBoxClusters(model, { 50, -5, 0 }, { 150, 5, 0 }, 64, list), 3, "box across x = 100 and y = 0")
	t.eq(ctx, list[1], 2, "leaf C first")
	t.eq(ctx, list[2], 1, "then leaf B")
	t.eq(ctx, list[3], -1, "then the solid leaf (cluster -1 is listed too)")
	table.clear(list)
	t.eq(ctx, FindBoxClusters(model, { 50, -5, 0 }, { 150, 5, 0 }, 1, list), 3, "count beyond maxclusters")
	t.eq(ctx, #list, 1, "only maxclusters entries written")
	t.eq(ctx, FindBoxClusters(model, { 0 / 0, 0, 0 }, { 1, 1, 1 }, 64, list), -1, "NaN box: -1")
	model.brush.num_pvsclusters = 0
	t.eq(ctx, FindBoxClusters(model, { 0, 0, 0 }, { 1, 1, 1 }, 64, list), -1, "no PVS clusters: -1")
	model.brush.num_pvsclusters = 3

	-- FatPVS
	local out = buffer.create(16)
	t.eq(ctx, FatPVS(model, { -50, 0, 0 }, 8, out, 16, false), 1, "FatPVS returns num_pvsclusterbytes")
	t.eq(ctx, buffer.readu8(out, 0), 0x03, "point in leaf A: cluster 0's row")
	t.ok(ctx, bit32.btest(buffer.readu8(out, 0), 1), "the FatPVS of a point contains its own cluster")
	FatPVS(model, { -4, 10, 0 }, 8, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0x07, "4 units from x = 0 with radius 8: rows of A and B or'd")
	FatPVS(model, { -4, 10, 0 }, 2, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0x03, "radius 2: only leaf A")
	FatPVS(model, { 50, -3, 0 }, 2, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0x06, "leaf C alone")
	FatPVS(model, { 50, -3, 0 }, 8, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0x07, "leaf C with radius 8 reaches leaf B")
	buffer.writeu8(out, 0, 0x80)
	FatPVS(model, { -50, 0, 0 }, 8, out, 16, true)
	t.eq(ctx, buffer.readu8(out, 0), 0x83, "merge keeps the bits already there")
	FatPVS(model, { -50, 0, 0 }, 8, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0x03, "no merge clears first")
	buffer.writeu8(out, 1, 0x55)
	t.eq(ctx, FatPVS(model, { 150, 0, 0 }, 8, out, 16, false), 1, "point in the solid leaf: bytes")
	t.eq(ctx, buffer.readu8(out, 0), 0xFF, "point outside any cluster: everything visible")
	t.eq(ctx, buffer.readu8(out, 1), 0x55, "only `bytes` bytes are written")
	t.eq(ctx, FatPVS(model, { -50, 0, 0 }, 8, out, 0, false), 0, "pvsbufferlength 0: bytes = min(bytes, 0)")
	model.brush.num_pvsclusters = 0
	FatPVS(model, { -50, 0, 0 }, 8, out, 16, false)
	t.eq(ctx, buffer.readu8(out, 0), 0xFF, "no PVS: everything visible")
end
