--!strict
-- M3-BSPLOAD: the trace functions of engine/model_brush.luau on stock maps (the functions themselves are
-- checked bit for bit against the C build in tests/unit/trace.test.luau). Here, through the function pointers
-- the loader sets (mod.TraceBox / TraceLine / TracePoint):
--   * every BIH trace gives the same fraction / startsolid / allsolid / startsupercontents / startdepth as a
--     trace against every leaf of the tree in a plain loop (the tree walk may not drop anything);
--   * a player box dropped from every spawn point lands on a floor;
--   * the BSP-tree path (mod_collision_bih 0) runs and agrees with the BIH on nearly every trace.
-- Needs game data.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local bih = require("../../engine/bih")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local model_brush = require("../../engine/model_brush")

local R = f32.round
local MAPS = { "stormkeep", "dance", "afterslime", "xoylent" }
local SOLID = model_brush.SUPERCONTENTS_SOLID
local PLAYERMASK = SOLID + model_brush.SUPERCONTENTS_BODY + model_brush.SUPERCONTENTS_PLAYERCLIP

return function(ctx: t.Ctx)
	local dir = "work/vfs-high/maps"
	if not lfs.isDir(dir) or not lfs.isFile(dir .. "/stormkeep.bsp") then
		t.skip(ctx, "needs work/vfs-high")
		return
	end
	local oldsink = console.sink
	console.sink = function(_line: string) end
	cvar.reset()
	collision.Collision_Init()
	model_brush.Mod_BrushInit()

	local seed = 20261126
	local function rnd(): number
		seed = (seed * 1664525 + 1013904223) % 4294967296
		return seed // 256
	end
	local function frand(lo: number, hi: number): number
		return lo + (hi - lo) * (rnd() % 4096) / 4096
	end

	-- the same trace against every leaf of the collision BIH, no tree
	local function sweepbox(tr: collision.trace_t, model: any, bs: any, be: any)
		local smin, smax = { 0, 0, 0 }, { 0, 0, 0 }
		for k = 1, 3 do
			smin[k] = math.min(bs.mins[k], be.mins[k])
			smax[k] = math.max(bs.maxs[k], be.maxs[k])
		end
		local ce: buffer, cv: buffer = model.brush.data_collisionelement3i, model.brush.data_collisionvertex3f
		local re: buffer, rv: buffer = model.surfmesh.data_element3i, model.surfmesh.data_vertex3f
		for _, leaf in model.collision_bih.leafs do
			local a, b = leaf.mins, leaf.maxs
			if
				smin[1] <= b[1]
				and smax[1] >= a[1]
				and smin[2] <= b[2]
				and smax[2] >= a[2]
				and smin[3] <= b[3]
				and smax[3] >= a[3]
			then
				if leaf.type == bih.BIH_BRUSH then
					local cb = model.brush.data_brushes[leaf.itemindex + 1].colbrushf
					collision.Collision_TraceBrushBrushFloat(tr, bs, be, cb, cb)
				else
					local e, v = ce, cv
					if leaf.type == bih.BIH_RENDERTRIANGLE then
						e, v = re, rv
					end
					local o = leaf.itemindex * 12
					local tex = model.data_textures[leaf.textureindex + 1]
					collision.Collision_TraceBrushTriangleFloat(
						tr,
						bs,
						be,
						v,
						buffer.readi32(e, o) * 12,
						buffer.readi32(e, o + 4) * 12,
						buffer.readi32(e, o + 8) * 12,
						tex.supercontents,
						tex.surfaceflags,
						tex
					)
				end
			end
		end
	end
	local function sweepline(tr: collision.trace_t, model: any, s: { number }, e_: { number })
		local ce: buffer, cv: buffer = model.brush.data_collisionelement3i, model.brush.data_collisionvertex3f
		local re: buffer, rv: buffer = model.surfmesh.data_element3i, model.surfmesh.data_vertex3f
		local same = s[1] == e_[1] and s[2] == e_[2] and s[3] == e_[3]
		for _, leaf in model.collision_bih.leafs do
			if leaf.type == bih.BIH_BRUSH then
				local cb = model.brush.data_brushes[leaf.itemindex + 1].colbrushf
				if same then
					collision.Collision_TracePointBrushFloat(tr, s, cb)
				else
					collision.Collision_TraceLineBrushFloat(tr, s, e_, cb, cb)
				end
			elseif not same then
				local e, v = ce, cv
				if leaf.type == bih.BIH_RENDERTRIANGLE then
					e, v = re, rv
				end
				local o = leaf.itemindex * 12
				local tex = model.data_textures[leaf.textureindex + 1]
				collision.Collision_TraceLineTriangleFloat(
					tr,
					s,
					e_,
					v,
					buffer.readi32(e, o) * 12,
					buffer.readi32(e, o + 4) * 12,
					buffer.readi32(e, o + 8) * 12,
					tex.supercontents,
					tex.surfaceflags,
					tex
				)
			end
		end
	end
	local function key(tr: collision.trace_t): string
		return `{tr.fraction} {tr.startsolid} {tr.allsolid} {tr.startsupercontents} {tr.startdepth}`
	end
	local function newtrace(hit: number): collision.trace_t
		local tr = collision.newtrace()
		tr.fraction = 1
		tr.hitsupercontentsmask = hit
		return tr
	end

	local totals = { traces = 0, hits = 0, startsolid = 0, bspsame = 0, bsptotal = 0, spawns = 0, landed = 0 }
	for _, name in MAPS do
		if not lfs.isFile(`{dir}/{name}.bsp`) then
			continue
		end
		local world = model_brush.newmodel("maps/" .. name .. ".bsp")
		model_brush.Mod_IBSP_Load(world, lfs.readFile(`{dir}/{name}.bsp`))
		local models = { world }
		for i = 2, math.min(#(world.brush.submodels or {}), 4) do
			models[i] = world.brush.submodels[i]
		end
		local mismatches, firstbad = 0, ""
		local bspdiff = 0
		for mi, model in models do
			local leafs = model.collision_bih.leafs
			if #leafs == 0 then
				continue
			end
			local function nearleaf(): { number }
				local leaf = leafs[rnd() % #leafs + 1]
				return {
					R((leaf.mins[1] + leaf.maxs[1]) / 2 + frand(-48, 48)),
					R((leaf.mins[2] + leaf.maxs[2]) / 2 + frand(-48, 48)),
					R((leaf.mins[3] + leaf.maxs[3]) / 2 + frand(-48, 48)),
				}
			end
			local count = if mi == 1 then 90 else 24
			for i = 1, count do
				local s = nearleaf()
				local e: { number }
				if i % 7 == 0 then
					e = { s[1], s[2], s[3] }
				elseif i % 2 == 0 then
					e = nearleaf()
				else
					e = { R(s[1] + frand(-300, 300)), R(s[2] + frand(-300, 300)), R(s[3] + frand(-300, 300)) }
				end
				local hit = if i % 5 == 0 then PLAYERMASK else SOLID
				local mins, maxs = { -16, -16, -24 }, { 16, 16, 45 }
				if i % 3 == 0 then
					mins = { R(-frand(1, 30)), R(-frand(1, 30)), R(-frand(1, 30)) }
					maxs = { R(frand(1, 30)), R(frand(1, 30)), R(frand(1, 30)) }
				end

				-- box
				cvar.Cvar_SetValue("mod_collision_bih", 1)
				local tr = collision.newtrace()
				model.TraceBox(model, nil, nil, tr, s, mins, maxs, e, hit, 0, 0)
				local bs = collision.Collision_BrushForBox(
					{ R(s[1] + mins[1]), R(s[2] + mins[2]), R(s[3] + mins[3]) },
					{ R(s[1] + maxs[1]), R(s[2] + maxs[2]), R(s[3] + maxs[3]) },
					0,
					0,
					nil
				)
				local be = collision.Collision_BrushForBox(
					{ R(e[1] + mins[1]), R(e[2] + mins[2]), R(e[3] + mins[3]) },
					{ R(e[1] + maxs[1]), R(e[2] + maxs[2]), R(e[3] + maxs[3]) },
					0,
					0,
					nil
				)
				local ref = newtrace(hit)
				sweepbox(ref, model, bs, be)
				totals.traces += 1
				if tr.fraction < 1 then
					totals.hits += 1
				end
				if tr.startsolid then
					totals.startsolid += 1
				end
				if key(tr) ~= key(ref) then
					mismatches += 1
					if firstbad == "" then
						firstbad = `box model {mi - 1} #{i}: bih {key(tr)} / loop {key(ref)}`
					end
				end
				cvar.Cvar_SetValue("mod_collision_bih", 0)
				local tb = collision.newtrace()
				model.TraceBox(model, nil, nil, tb, s, mins, maxs, e, hit, 0, 0)
				totals.bsptotal += 1
				if key(tb) ~= key(tr) then
					bspdiff += 1
				end

				-- line (a point trace when start == end)
				cvar.Cvar_SetValue("mod_collision_bih", 1)
				local tl = collision.newtrace()
				model.TraceLine(model, nil, nil, tl, s, e, hit, 0, 0)
				local refl = newtrace(hit)
				sweepline(refl, model, s, e)
				totals.traces += 1
				if tl.fraction < 1 then
					totals.hits += 1
				end
				if key(tl) ~= key(refl) then
					mismatches += 1
					if firstbad == "" then
						firstbad = `line model {mi - 1} #{i}: bih {key(tl)} / loop {key(refl)}`
					end
				end
				t.eq(
					ctx,
					model.PointSuperContents(model, 0, s),
					(function()
						local tp = collision.newtrace()
						model.TracePoint(model, nil, nil, tp, s, 0, 0, 0)
						return tp.startsupercontents
					end)(),
					`{name} model {mi - 1} #{i}: PointSuperContents is the point trace's startsupercontents`
				)
				cvar.Cvar_SetValue("mod_collision_bih", 0)
				local tlb = collision.newtrace()
				model.TraceLine(model, nil, nil, tlb, s, e, hit, 0, 0)
				totals.bsptotal += 1
				if key(tlb) ~= key(tl) then
					bspdiff += 1
				end
			end
		end
		cvar.Cvar_SetValue("mod_collision_bih", 1)
		t.eq(ctx, mismatches, 0, `{name}: BIH traces equal the plain loop over all leafs {firstbad}`)
		totals.bspsame += 0
		totals.bspsame -= bspdiff

		-- spawn points: the player box falls onto a floor
		local spawns, landed = 0, 0
		for block in string.gmatch(world.brush.entities or "", "%b{}") do
			if string.find(block, '"classname"%s+"info_player_[%w_]+"') then
				local x, y, z = string.match(block, '"origin"%s+"([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)"')
				if x then
					local s = { R(tonumber(x) :: number), R(tonumber(y) :: number), R((tonumber(z) :: number) + 1) }
					local e = { s[1], s[2], R(s[3] - 4096) }
					local tr = collision.newtrace()
					world.TraceBox(world, nil, nil, tr, s, { -16, -16, -24 }, { 16, 16, 45 }, e, PLAYERMASK, 0, 0)
					spawns += 1
					if tr.fraction < 1 and not tr.allsolid and tr.plane.normal[3] > 0.7 then
						landed += 1
					end
				end
			end
		end
		totals.spawns += spawns
		totals.landed += landed
		t.ok(ctx, spawns > 0, `{name}: has spawn points`)
		t.ok(ctx, landed >= spawns * 0.9, `{name}: {landed} of {spawns} spawn points have a floor under them`)
	end
	local bspsame = totals.bsptotal + totals.bspsame
	t.ok(ctx, totals.hits > totals.traces * 0.1, `some traces hit ({totals.hits} of {totals.traces})`)
	t.ok(
		ctx,
		bspsame >= totals.bsptotal * 0.95,
		`the BSP-tree path agrees with the BIH on {bspsame} of {totals.bsptotal} traces`
	)
	print(
		`    q3bsp_trace: {totals.traces} BIH traces ({totals.hits} hit, {totals.startsolid} start solid), BSP path equal on {bspsame}/{totals.bsptotal}, {totals.landed}/{totals.spawns} spawn points land`
	)
	console.sink = oldsink
	cvar.reset()
end
