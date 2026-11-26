--!strict
-- The line testing and linking part of engine/sv_phys.luau (SV_GetPitchSign .. SV_LinkEdict, SV_NudgeOutOfSolid)
-- and SV_GetModelByIndex / SV_GetModelFromEdict of engine/sv_main.luau against the release's sv_phys.c,
-- sv_main.c, world.c and collision.c compiled unchanged (tests/vectors/svphys.tsv,
-- tools/testgen/svphys_vectors.sh). The vector file carries the synthetic map of trace_vectors.c (world model
-- and submodel), the QuakeC field / global offsets, the server models and every edict's field memory; the test
-- rebuilds that server, makes every call the C program made and compares each result bit for bit (touch
-- function calls: the call order and every global the caller set).
local t = require("../_lib/t")
local bih = require("../../engine/bih")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local model_brush = require("../../engine/model_brush")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local sv_phys = require("../../engine/sv_phys")
local world = require("../../engine/world")

return function(ctx: t.Ctx)
	local scratch = buffer.create(8)
	local function fb(hex: string): number
		return f32.frombits(tonumber(hex, 16) :: number)
	end
	local function db(hex: string): number
		buffer.writeu32(scratch, 4, tonumber(string.sub(hex, 1, 8), 16) :: number)
		buffer.writeu32(scratch, 0, tonumber(string.sub(hex, 9, 16), 16) :: number)
		return buffer.readf64(scratch, 0)
	end
	local function dh(v: number): string
		buffer.writef64(scratch, 0, v)
		return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
	end
	local function fh(v: number): string
		return string.format("%08x", f32.tobits(v))
	end
	local function num(s: string): number
		return tonumber(s) :: number
	end
	local function v3(c: { string }, i: number): { number }
		return { fb(c[i]), fb(c[i + 1]), fb(c[i + 2]) }
	end
	local function floats(c: { string }, first: number): buffer
		local b = buffer.create((#c - first + 1) * 4)
		for i = first, #c do
			buffer.writeu32(b, (i - first) * 4, tonumber(c[i], 16) :: number)
		end
		return b
	end
	local function bstr(b: boolean): string
		return if b then "1" else "0"
	end

	cvar.reset()
	collision.Collision_Init()
	model_brush.Mod_BrushInit()

	local oldsink = console.sink
	console.sink = function(_line: string) end -- Collision_ValidateBrush, SV_LinkEdict (invalid modelindex)

	-- the synthetic map of trace_vectors.c (rebuilt as in tests/unit/trace.test.luau)
	local textures: { any } = {}
	local function tex(s: string): any
		return textures[num(s) + 1]
	end
	local function texidx(x: any): string
		return if x then tostring(x.index) else "-1"
	end
	local brushes: { any } = {}
	local surfaces: { any } = {}
	local header: { string } = {}
	local planes: { collision.colplanef_t } = {}
	local cvert: { buffer }, rvert: { buffer }, lelem: { buffer } = {}, {}, {}
	local nodelines: { { string } }, leaflines: { { string } } = {}, {}
	local leafbrushes, leafsurfaces = buffer.create(0), buffer.create(0)
	local models: { any } = {}
	local shared: any = nil

	local function buildshared()
		local nsurf = #surfaces
		local sv, st = surfaces[1].num_vertices, surfaces[1].num_triangles
		local gcvert, grvert = buffer.create(nsurf * sv * 12), buffer.create(nsurf * sv * 12)
		local gcelem, grelem = buffer.create(nsurf * st * 12), buffer.create(nsurf * st * 12)
		for s = 0, nsurf - 1 do
			buffer.copy(gcvert, s * sv * 12, cvert[s + 1])
			buffer.copy(grvert, s * sv * 12, rvert[s + 1])
			for i = 0, st * 3 - 1 do
				local e = buffer.readi32(lelem[s + 1], i * 4) + s * sv
				buffer.writei32(gcelem, (s * st * 3 + i) * 4, e)
				buffer.writei32(grelem, (s * st * 3 + i) * 4, e)
			end
		end
		local nodes: { any }, leafs: { any } = {}, {}
		for i, c in nodelines do
			local plane = { normal = v3(c, 3), dist = fb(c[6]), type = num(c[7]), signbits = num(c[8]) }
			nodes[i] = {
				index = i - 1,
				plane = plane,
				mins = v3(c, 11),
				maxs = v3(c, 14),
				combinedsupercontents = 0,
				children = {},
			}
		end
		for i, c in leaflines do
			leafs[i] = {
				index = i - 1,
				plane = nil,
				clusterindex = num(c[3]),
				areaindex = 0,
				containscollisionsurfaces = c[4] ~= "0",
				numleafsurfaces = num(c[5]),
				firstleafsurface = num(c[6]),
				numleafbrushes = num(c[7]),
				firstleafbrush = num(c[8]),
				mins = v3(c, 9),
				maxs = v3(c, 12),
				combinedsupercontents = 0,
				children = {},
			}
		end
		for i, c in nodelines do
			for k = 1, 2 do
				local child = num(c[8 + k])
				nodes[i].children[k] = if child >= 0 then nodes[child + 1] else leafs[-child]
				nodes[i].children[k].parent = nodes[i]
			end
		end
		shared = { gcvert = gcvert, grvert = grvert, gcelem = gcelem, grelem = grelem, nodes = nodes, leafs = leafs }
	end
	local function buildmodel(c: { string })
		if not shared then
			buildshared()
		end
		local m = model_brush.newmodel("svphys" .. c[2])
		m.data_textures = textures
		m.data_surfaces = surfaces
		m.num_surfaces = #surfaces
		m.brush.data_brushes = brushes
		m.brush.data_nodes = shared.nodes
		m.brush.data_leafs = shared.leafs
		m.brush.data_leafbrushes = leafbrushes
		m.brush.data_leafsurfaces = leafsurfaces
		m.brush.data_collisionvertex3f = shared.gcvert
		m.brush.data_collisionelement3i = shared.gcelem
		m.surfmesh = { data_vertex3f = shared.grvert, data_element3i = shared.grelem }
		-- the function pointers Mod_Q3BSP_Load sets
		m.TraceBox = model_brush.Mod_Q3BSP_TraceBox
		m.TraceBrush = model_brush.Mod_Q3BSP_TraceBrush
		m.TraceLine = model_brush.Mod_Q3BSP_TraceLine
		m.TracePoint = model_brush.Mod_Q3BSP_TracePoint
		m.PointSuperContents = model_brush.Mod_Q3BSP_PointSuperContents
		m.TraceLineAgainstSurfaces = model_brush.Mod_CollisionBIH_TraceLine
		m.brush.submodel = num(c[2])
		m.firstmodelbrush = num(c[3])
		m.nummodelbrushes = num(c[4])
		m.firstmodelsurface = num(c[5])
		m.nummodelsurfaces = num(c[6])
		m.collision_bih = bih.new()
		m.render_bih = bih.new()
		model_brush.Mod_MakeCollisionBIH(m, false, m.collision_bih)
		model_brush.Mod_MakeCollisionBIH(m, true, m.render_bih)
		t.eq(
			ctx,
			`{m.collision_bih.numnodes}\t{m.render_bih.numnodes}`,
			c[7] .. "\t" .. c[8],
			"model " .. c[2] .. ": BIH nodes"
		)
		models[num(c[2]) + 1] = m
	end

	-- the server
	local sv = server.sv
	local oldsv = { world = sv.world, models = sv.models, worldmodel = sv.worldmodel, time = sv.time }
	local oldprog = cvar.prvm_prog_list[0]
	sv.models = {}
	local fieldofs: { [string]: number }, globalofs: { [string]: number } = {}, {}
	local nfields, nglobals = 0, 0
	local prog: any = nil
	local aliasmodel: any = nil
	local touches: { string } = {}
	local touchidx = 0

	local function modeltag(m: any): string
		if m == nil then
			return "-"
		elseif m == models[1] then
			return "w"
		elseif m == models[2] then
			return "s"
		elseif m == aliasmodel then
			return "a"
		end
		return "?"
	end
	local function word(b: buffer, slot: number): string
		return string.format("%08x", buffer.readu32(b, slot * 4))
	end
	local function fieldwords(n: number, f: string, count: number): string
		local parts = {}
		for i = 0, count - 1 do
			table.insert(parts, word(prog.edictsfields, n * nfields + fieldofs[f] + i))
		end
		return table.concat(parts, "\t")
	end
	local function edarg(s: string): number?
		local n = num(s)
		return if n < 0 then nil else n
	end
	local function resultstr(tr: collision.trace_t): string
		return table.concat({
			bstr(tr.allsolid),
			bstr(tr.startsolid),
			bstr(tr.worldstartsolid),
			bstr(tr.bmodelstartsolid),
			bstr(tr.inopen),
			bstr(tr.inwater),
			dh(tr.fraction),
			dh(tr.endpos[1]),
			dh(tr.endpos[2]),
			dh(tr.endpos[3]),
			fh(tr.plane.normal[1]),
			fh(tr.plane.normal[2]),
			fh(tr.plane.normal[3]),
			fh(tr.plane.dist),
			tostring(if tr.ent == nil then -1 else tr.ent),
			tostring(tr.hitsupercontentsmask),
			tostring(tr.skipsupercontentsmask),
			tostring(tr.skipmaterialflagsmask),
			tostring(tr.startsupercontents),
			tostring(tr.hitsupercontents),
			tostring(tr.hitq3surfaceflags),
			texidx(tr.hittexture),
			bstr(tr.startfound),
			dh(tr.startdepth),
			dh(tr.startdepthnormal[1]),
			dh(tr.startdepthnormal[2]),
			dh(tr.startdepthnormal[3]),
			texidx(tr.starttexture),
		}, "\t")
	end

	local result = "" -- what the next R line must be
	local label = ""
	local lineno = 0
	for line in string.gmatch(t.read("tests/vectors/svphys.tsv"), "[^\r\n]+") do
		lineno += 1
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "TEX" then
			textures[num(c[2]) + 1] = {
				index = num(c[2]),
				name = "tex" .. c[2],
				supercontents = num(c[3]),
				surfaceflags = num(c[4]),
				currentmaterialflags = num(c[5]),
				basematerialflags = num(c[6]),
			}
		elseif kind == "B" then
			header = c
			planes = {}
		elseif kind == "P" then
			local texture = tex(c[6])
			table.insert(
				planes,
				{ normal = v3(c, 2), dist = fb(c[5]), q3surfaceflags = texture.surfaceflags, texture = texture }
			)
		elseif kind == "BR" then
			local texture = tex(header[4])
			local b = collision.Collision_NewBrushFromPlanes(
				num(header[3]),
				planes,
				texture.supercontents,
				texture.surfaceflags,
				texture,
				header[5] ~= "0"
			)
			t.eq(ctx, if b then "1" else "0", c[2], "brush " .. header[2] .. " exists")
			brushes[num(header[2]) + 1] = { colbrushf = b, texture = texture, numbrushsides = 0, firstbrushside = 0 }
		elseif kind == "SF" then
			local s = num(c[2])
			surfaces[s + 1] = {
				index = s,
				texture = tex(c[3]),
				mins = v3(c, 7),
				maxs = v3(c, 10),
				num_vertices = num(c[5]),
				num_triangles = num(c[6]),
				num_firstvertex = s * num(c[5]),
				num_firsttriangle = s * num(c[6]),
				num_collisionvertices = num(c[5]),
				num_collisiontriangles = num(c[6]),
				num_firstcollisiontriangle = s * num(c[6]),
				deprecatedq3num_collisionbboxstride = num(c[4]),
				deprecatedq3collisionmarkframe = 0,
			}
		elseif kind == "SV" then
			cvert[#surfaces] = floats(c, 2)
			surfaces[#surfaces].deprecatedq3data_collisionvertex3f = cvert[#surfaces]
		elseif kind == "SE" then
			local b = buffer.create((#c - 1) * 4)
			for i = 2, #c do
				buffer.writei32(b, (i - 2) * 4, num(c[i]))
			end
			lelem[#surfaces] = b
			surfaces[#surfaces].deprecatedq3data_collisionelement3i = b
		elseif kind == "SR" then
			rvert[#surfaces] = floats(c, 2)
		elseif kind == "SB" then
			surfaces[#surfaces].deprecatedq3data_collisionbbox6f = if #c > 1 then floats(c, 2) else nil
		elseif kind == "ND" then
			table.insert(nodelines, c)
		elseif kind == "LF" then
			table.insert(leaflines, c)
		elseif kind == "LB" or kind == "LS" then
			local b = buffer.create((#c - 1) * 4)
			for i = 2, #c do
				buffer.writei32(b, (i - 2) * 4, num(c[i]))
			end
			if kind == "LB" then
				leafbrushes = b
			else
				leafsurfaces = b
			end
		elseif kind == "MODEL" then
			buildmodel(c)
		elseif kind == "CVAR" then
			-- the sv_main.c cvars are registered with the value the C program gives them (their defaults first)
			if not cvar.Cvar_FindVar(c[2]) then
				cvar.Cvar_RegisterVariable(cvar.static(0, c[2], c[3], ""))
			end
			cvar.Cvar_SetValue(c[2], num(c[3]))
		elseif kind == "FIELD" then
			fieldofs[c[2]] = num(c[3])
		elseif kind == "NFIELDS" then
			nfields = num(c[2])
		elseif kind == "GLOBAL" then
			globalofs[c[2]] = num(c[3])
		elseif kind == "NGLOBALS" then
			nglobals = num(c[2])
		elseif kind == "NED" then
			local ned = num(c[2])
			prog = prvm_edict.NewProg("server")
			prog.fieldofs_cache = fieldofs
			prog.globalofs_cache = globalofs
			prog.entityfields = nfields
			prog.numglobals = nglobals
			prog.globals = buffer.create(nglobals * 4)
			prog.max_edicts = ned
			prog.limit_edicts = ned
			prog.reserved_edicts = 0
			prog.num_edicts = ned
			prvm_edict.PRVM_MEM_Alloc(prog)
			t.eq(ctx, prog.num_edicts, ned, "num_edicts")
			-- prog->ExecuteProgram: the touch call with every global, as the C stub prints it
			prog.ExecuteProgram = function(p: any, fnum: number, _msg: string)
				local parts = { tostring(fnum) }
				for i = 0, nglobals - 1 do
					table.insert(parts, word(p.globals, i))
				end
				table.insert(touches, table.concat(parts, "\t"))
			end
			cvar.prvm_prog_list[0] = prog
		elseif kind == "SMODEL" then
			local idx, src = num(c[2]), num(c[3])
			local m = models[src + 1]
			if c[4] == "alias" then
				m = table.clone(m)
				m.brush = table.clone(m.brush)
				aliasmodel = m
			end
			m.type = if c[4] == "alias" then "mod_alias" else "mod_brushq3"
			m.numframes = num(c[5])
			m.normalmins, m.normalmaxs = v3(c, 6), v3(c, 9)
			m.yawmins, m.yawmaxs = v3(c, 12), v3(c, 15)
			m.rotatedmins, m.rotatedmaxs = v3(c, 18), v3(c, 21)
			sv.models[idx] = m
			if idx == 1 then
				sv.worldmodel = m
			end
		elseif kind == "TIME" then
			sv.time = db(c[2])
		elseif kind == "WORLD" then
			sv.world = world.new()
			prog.ed_area = nil
			world.World_SetSize(sv.world, "maps/svphys.bsp", v3(c, 2), v3(c, 5), prog)
		elseif kind == "G" then
			local w = sv.world
			local parts = {}
			for _, v in { w.areagrid_mins, w.areagrid_maxs, w.areagrid_size, w.areagrid_bias, w.areagrid_scale } do
				table.insert(parts, fh(v[1]))
				table.insert(parts, fh(v[2]))
				table.insert(parts, fh(v[3]))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), `line {lineno}: World_SetSize grid`)
		elseif kind == "ED" then
			local n = num(c[2])
			prog.ed_free[n] = c[3] ~= "0"
			for i = 0, nfields - 1 do
				buffer.writeu32(prog.edictsfields, (n * nfields + i) * 4, tonumber(c[4 + i], 16) :: number)
			end
		elseif kind == "F" then
			prog.ed_free[num(c[2])] = c[3] ~= "0"
		elseif kind == "LINK" then
			sv_phys.SV_LinkEdict(num(c[2]))
		elseif kind == "LK" then
			local n = num(c[2])
			t.eq(
				ctx,
				fieldwords(n, "absmin", 3) .. "\t" .. fieldwords(n, "absmax", 3),
				table.concat(c, "\t", 3),
				`line {lineno}: SV_LinkEdict({n}) absmin / absmax`
			)
		elseif kind == "TG" or kind == "TC" then
			touches, touchidx = {}, 0
			label = `line {lineno}: {if kind == "TG"
				then "SV_LinkEdict_TouchAreaGrid"
				else "SV_LinkEdict_TouchAreaGrid_Call"}`
			if kind == "TG" then
				buffer.writei32(prog.globals, globalofs.self * 4, num(c[3]))
				buffer.writei32(prog.globals, globalofs.other * 4, num(c[4]))
				sv_phys.SV_LinkEdict_TouchAreaGrid(num(c[2]))
			else
				sv_phys.SV_LinkEdict_TouchAreaGrid_Call(num(c[2]), num(c[3]))
			end
		elseif kind == "TOUCH" then
			touchidx += 1
			t.eq(ctx, touches[touchidx], table.concat(c, "\t", 2), `{label}: touch call {touchidx}`)
		elseif kind == "TGEND" then
			t.eq(
				ctx,
				`{#touches}\t{buffer.readi32(prog.globals, globalofs.self * 4)}\t{buffer.readi32(
					prog.globals,
					globalofs.other * 4
				)}`,
				table.concat(c, "\t", 2),
				`{label}: number of touch calls, self, other`
			)
		elseif kind == "EQ" then
			local n = edarg(c[2])
			local got
			if n == nil then
				got = `-1\t{sv_phys.SV_GenericHitSuperContentsMask(nil)}\t0\t{modeltag(
					sv_main.SV_GetModelFromEdict(nil)
				)}`
			else
				got = `{n}\t{sv_phys.SV_GenericHitSuperContentsMask(n)}\t{sv_phys.SV_GetPitchSign(prog, n)}\t{modeltag(
					sv_main.SV_GetModelFromEdict(n)
				)}`
			end
			t.eq(
				ctx,
				got,
				table.concat(c, "\t", 2),
				`line {lineno}: SV_GenericHitSuperContentsMask / SV_GetPitchSign / SV_GetModelFromEdict`
			)
		elseif kind == "GM" then
			t.eq(
				ctx,
				modeltag(sv_main.SV_GetModelByIndex(num(c[2]))),
				c[3],
				`line {lineno}: SV_GetModelByIndex({c[2]})`
			)
		elseif kind == "TB" then
			label = `line {lineno}: SV_TraceBox`
			result = resultstr(
				sv_phys.SV_TraceBox(
					v3(c, 7),
					v3(c, 10),
					v3(c, 13),
					v3(c, 16),
					num(c[2]),
					edarg(c[3]),
					num(c[4]),
					num(c[5]),
					num(c[6]),
					fb(c[19])
				)
			)
		elseif kind == "TL" then
			label = `line {lineno}: SV_TraceLine`
			result = resultstr(
				sv_phys.SV_TraceLine(
					v3(c, 7),
					v3(c, 10),
					num(c[2]),
					edarg(c[3]),
					num(c[4]),
					num(c[5]),
					num(c[6]),
					fb(c[13])
				)
			)
		elseif kind == "TP" then
			label = `line {lineno}: SV_TracePoint`
			result = resultstr(sv_phys.SV_TracePoint(v3(c, 7), num(c[2]), edarg(c[3]), num(c[4]), num(c[5]), num(c[6])))
		elseif kind == "R" then
			t.eq(ctx, result, table.concat(c, "\t", 2), label)
		elseif kind == "PC" then
			t.eq(ctx, tostring(sv_phys.SV_PointSuperContents(v3(c, 2))), c[5], `line {lineno}: SV_PointSuperContents`)
		elseif kind == "EB" then
			local maxedicts, isnull = num(c[8]), c[9] ~= "0"
			local list: { number } = {}
			local n = sv_phys.SV_EntitiesInBox(v3(c, 2), v3(c, 5), maxedicts, if isnull then nil else list)
			local parts = { c[8], c[9], tostring(n) }
			if not isnull then
				for i = 1, math.min(n, maxedicts) do
					table.insert(parts, tostring(list[i]))
				end
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 8), `line {lineno}: SV_EntitiesInBox`)
		elseif kind == "NU" then
			local n = num(c[2])
			local ok = sv_phys.SV_NudgeOutOfSolid(n)
			t.eq(
				ctx,
				bstr(ok) .. "\t" .. fieldwords(n, "origin", 3),
				table.concat(c, "\t", 3),
				`line {lineno}: SV_NudgeOutOfSolid({n}) result, origin`
			)
		elseif kind == "END" then
			t.ok(ctx, true, "reached the end of the vector file")
		end
	end
	console.sink = oldsink
	sv.world, sv.models, sv.worldmodel, sv.time = oldsv.world, oldsv.models, oldsv.worldmodel, oldsv.time
	cvar.prvm_prog_list[0] = oldprog
	cvar.reset()
end
