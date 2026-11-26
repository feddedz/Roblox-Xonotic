--!strict
-- The trace code of engine/collision.luau and engine/model_brush.luau against the release's collision.c and
-- model_brush.c compiled unchanged (tests/vectors/trace.tsv, tools/testgen/trace_vectors.sh). The vector file
-- carries a small synthetic map (brushes, patch-like surfaces, a BSP tree, a submodel); the test rebuilds it,
-- runs every trace the C program ran and compares each trace_t field bit for bit.
local t = require("../_lib/t")
local bih = require("../../engine/bih")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local matrixlib = require("../../engine/matrixlib")
local model_brush = require("../../engine/model_brush")

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

	cvar.reset()
	collision.Collision_Init()
	model_brush.Mod_BrushInit()

	local oldsink = console.sink
	console.sink = function(_line: string) end -- Collision_ValidateBrush prints for the degenerate brush

	local textures: { any } = {}
	local function tex(s: string): any
		return textures[num(s) + 1]
	end
	local function texidx(x: any): string
		return if x then tostring(x.index) else "-1"
	end
	local function statestr(tr: collision.trace_t): string
		return table.concat({
			if tr.allsolid then "1" else "0",
			if tr.startsolid then "1" else "0",
			dh(tr.fraction),
			fh(tr.plane.normal[1]),
			fh(tr.plane.normal[2]),
			fh(tr.plane.normal[3]),
			fh(tr.plane.dist),
			tostring(tr.hitsupercontents),
			tostring(tr.hitq3surfaceflags),
			texidx(tr.hittexture),
			tostring(tr.startsupercontents),
			dh(tr.startdepth),
			dh(tr.startdepthnormal[1]),
			dh(tr.startdepthnormal[2]),
			dh(tr.startdepthnormal[3]),
			texidx(tr.starttexture),
		}, "\t")
	end
	local function tinit(hit: string, skip: string, mat: string): collision.trace_t
		local tr = collision.newtrace()
		tr.fraction = 1
		tr.hitsupercontentsmask = num(hit)
		tr.skipsupercontentsmask = num(skip)
		tr.skipmaterialflagsmask = num(mat)
		return tr
	end

	-- the synthetic map
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
		shared = {
			gcvert = gcvert,
			grvert = grvert,
			gcelem = gcelem,
			grelem = grelem,
			nodes = nodes,
			leafs = leafs,
		}
	end
	local function buildmodel(c: { string })
		if not shared then
			buildshared()
		end
		local m = model_brush.newmodel("trace" .. c[2])
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

	-- the result lines that follow a trace line: S (state after list entry k, printed when it changed) and E
	local after: { string } = {}
	local changed: { boolean } = {}
	local seen: { boolean } = {}
	local label = ""
	local lineno = 0
	-- Collision_ClipTo* / Collision_CombineTraces: the entity matrix pair, the last trace and the combined one
	local mat, imat = matrixlib.new(), matrixlib.new()
	local last: collision.trace_t = collision.newtrace()
	local clip: collision.trace_t = collision.newtrace()
	local function copytrace(tr: collision.trace_t): collision.trace_t
		local c2 = table.clone(tr)
		c2.endpos = table.clone(tr.endpos)
		c2.plane = { normal = table.clone(tr.plane.normal), dist = tr.plane.dist }
		c2.startdepthnormal = table.clone(tr.startdepthnormal)
		return c2
	end
	local function modelat(s: string): any
		return if s == "-1" then nil else models[num(s) + 1]
	end
	local function begin(states: { string }, initial: string?)
		after = states
		changed, seen = {}, {}
		local prev = initial
		for i, s in states do
			changed[i] = prev ~= nil and s ~= prev
			prev = s
		end
		label = `line {lineno}`
	end
	local function boxbrushes(c: { string }, i: number, sc: number, q3: number, texture: any): (any, any)
		local s = collision.Collision_BrushForBox(v3(c, i), v3(c, i + 3), sc, q3, texture)
		local e = collision.Collision_BrushForBox(v3(c, i + 6), v3(c, i + 9), sc, q3, texture)
		return s, e
	end

	for line in string.gmatch(t.read("tests/vectors/trace.tsv"), "[^\r\n]+") do
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
			cvar.Cvar_SetValue(c[2], num(c[3]))
		elseif kind == "TRI" then
			local points = floats({ table.unpack(c, 2, 10) }, 1)
			local tplanes: { collision.colplanef_t } = {}
			for i = 1, 5 do
				tplanes[i] = { normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil }
			end
			local brush: collision.colbrushf_t = {
				mins = { 0, 0, 0 },
				maxs = { 0, 0, 0 },
				markframe = 0,
				supercontents = 0,
				numplanes = 5,
				planes = tplanes,
				numedgedirs = 3,
				edgedirs = buffer.create(36),
				numpoints = 3,
				points = points,
				numtriangles = 0,
				elements = buffer.create(0),
				texture = nil,
				q3surfaceflags = 0,
				isaabb = false,
				hasaabbplanes = false,
			}
			collision.Collision_CalcPlanesForTriangleBrushFloat(brush)
			local parts = { tostring(brush.numplanes), tostring(brush.numedgedirs) }
			for i = 1, 5 do
				local p = tplanes[i]
				table.insert(parts, fh(p.normal[1]))
				table.insert(parts, fh(p.normal[2]))
				table.insert(parts, fh(p.normal[3]))
				table.insert(parts, fh(p.dist))
			end
			for i = 0, 8 do
				table.insert(parts, string.format("%08x", buffer.readu32(brush.edgedirs, i * 4)))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 11), `line {lineno}: triangle brush planes`)
		elseif kind == "SEG" then
			local s, e = boxbrushes(c, 2, 0, 0, nil)
			local mins, maxs = { 0, 0, 0 }, { 0, 0, 0 }
			collision.Collision_BoundingBoxOfBrushTraceSegment(s, e, mins, maxs, fb(c[14]), fb(c[15]))
			t.eq(
				ctx,
				table.concat({ fh(mins[1]), fh(mins[2]), fh(mins[3]), fh(maxs[1]), fh(maxs[2]), fh(maxs[3]) }, "\t"),
				table.concat(c, "\t", 16),
				`line {lineno}: Collision_BoundingBoxOfBrushTraceSegment`
			)
		elseif kind == "BOXT" then
			local s, e = boxbrushes(c, 9, num(c[6]), num(c[7]), tex(c[8]))
			if c[2] == "1" then
				s.isaabb = false
				e.isaabb = false
			end
			local tr = tinit(c[3], c[4], c[5])
			local initial = statestr(tr)
			local states = {}
			for i = 1, 8 do
				local other = brushes[num(c[20 + i]) + 1].colbrushf
				collision.Collision_TraceBrushBrushFloat(tr, s, e, other, other)
				states[i] = statestr(tr)
			end
			begin(states, initial)
		elseif kind == "MOVET" then
			local s, e = boxbrushes(c, 6, 0, 0, nil)
			local texture = tex(c[5])
			local os = collision.Collision_BrushForBox(
				v3(c, 18),
				v3(c, 21),
				texture.supercontents,
				texture.surfaceflags,
				texture
			)
			local oe = collision.Collision_BrushForBox(
				v3(c, 24),
				v3(c, 27),
				texture.supercontents,
				texture.surfaceflags,
				texture
			)
			s.isaabb = false
			e.isaabb = false
			local tr = tinit(c[2], c[3], c[4])
			collision.Collision_TraceBrushBrushFloat(tr, s, e, os, oe)
			begin({ statestr(tr) }, nil)
		elseif kind == "LINET" then
			local tr = tinit(c[2], c[3], c[4])
			local initial = statestr(tr)
			local states = {}
			local s, e = v3(c, 5), v3(c, 8)
			for i = 1, 8 do
				local other = brushes[num(c[10 + i]) + 1].colbrushf
				collision.Collision_TraceLineBrushFloat(tr, s, e, other, other)
				states[i] = statestr(tr)
			end
			begin(states, initial)
		elseif kind == "PNTT" then
			local tr = tinit(c[2], c[3], c[4])
			local initial = statestr(tr)
			local states = {}
			local p = v3(c, 5)
			local inside = {}
			for i = 1, 8 do
				local other = brushes[num(c[7 + i]) + 1].colbrushf
				inside[i] = if collision.Collision_PointInsideBrushFloat(p, other) then "1" else "0"
				collision.Collision_TracePointBrushFloat(tr, p, other)
				states[i] = statestr(tr)
			end
			begin(states, initial)
			label = table.concat(inside, "\t") -- compared by the I line
		elseif kind == "I" then
			t.eq(ctx, label, table.concat(c, "\t", 2), `line {lineno}: Collision_PointInsideBrushFloat`)
			label = `line {lineno}`
		elseif kind == "MESHT" then
			local surface = surfaces[num(c[3]) + 1]
			local stride = num(c[4])
			local texture = tex(c[5])
			local tr = tinit(c[6], c[7], c[8])
			local segmins, segmaxs = v3(c, 21), v3(c, 24)
			if c[2] == "1" then
				collision.Collision_TraceLineTriangleMeshFloat(
					tr,
					v3(c, 9),
					v3(c, 15),
					surface.num_collisiontriangles,
					surface.deprecatedq3data_collisionelement3i,
					0,
					surface.deprecatedq3data_collisionvertex3f,
					stride,
					surface.deprecatedq3data_collisionbbox6f,
					texture.supercontents,
					texture.surfaceflags,
					texture,
					segmins,
					segmaxs
				)
			else
				local s, e = boxbrushes(c, 9, 0, 0, nil)
				collision.Collision_TraceBrushTriangleMeshFloat(
					tr,
					s,
					e,
					surface.num_collisiontriangles,
					surface.deprecatedq3data_collisionelement3i,
					0,
					surface.deprecatedq3data_collisionvertex3f,
					stride,
					surface.deprecatedq3data_collisionbbox6f,
					texture.supercontents,
					texture.surfaceflags,
					texture,
					segmins,
					segmaxs
				)
			end
			begin({ statestr(tr) }, nil)
		elseif kind == "XBOX" then
			local tr = collision.newtrace()
			model_brush.Mod_Q3BSP_TraceBox(
				models[num(c[2]) + 1],
				nil,
				nil,
				tr,
				v3(c, 6),
				v3(c, 9),
				v3(c, 12),
				v3(c, 15),
				num(c[3]),
				num(c[4]),
				num(c[5])
			)
			begin({ statestr(tr) }, nil)
		elseif kind == "XNBOX" then
			local s, e = boxbrushes(c, 6, 0, 0, nil)
			s.isaabb = false
			e.isaabb = false
			local tr = collision.newtrace()
			model_brush.Mod_Q3BSP_TraceBrush(models[num(c[2]) + 1], nil, nil, tr, s, e, num(c[3]), num(c[4]), num(c[5]))
			begin({ statestr(tr) }, nil)
		elseif kind == "XLINE" or kind == "XSURF" then
			local tr = collision.newtrace()
			local f = if kind == "XLINE"
				then model_brush.Mod_Q3BSP_TraceLine
				else model_brush.Mod_CollisionBIH_TraceLineAgainstSurfaces
			f(models[num(c[2]) + 1], nil, nil, tr, v3(c, 6), v3(c, 9), num(c[3]), num(c[4]), num(c[5]))
			begin({ statestr(tr) }, nil)
		elseif kind == "XPOINT" then
			local tr = collision.newtrace()
			model_brush.Mod_Q3BSP_TracePoint(
				models[num(c[2]) + 1],
				nil,
				nil,
				tr,
				v3(c, 6),
				num(c[3]),
				num(c[4]),
				num(c[5])
			)
			begin({ statestr(tr) }, nil)
		elseif kind == "XPSC" then
			t.eq(
				ctx,
				tostring(model_brush.Mod_Q3BSP_PointSuperContents(models[num(c[2]) + 1], 0, v3(c, 3))),
				c[6],
				`line {lineno}: Mod_Q3BSP_PointSuperContents`
			)
		elseif kind == "XLOS" then
			local r =
				model_brush.Mod_Q3BSP_TraceLineOfSight(models[num(c[2]) + 1], v3(c, 3), v3(c, 6), v3(c, 9), v3(c, 12))
			t.eq(ctx, if r then "1" else "0", c[15], `line {lineno}: Mod_Q3BSP_TraceLineOfSight`)
		elseif kind == "MATIN" then
			matrixlib.Matrix4x4_CreateFromQuakeEntity(
				mat,
				db(c[2]),
				db(c[3]),
				db(c[4]),
				db(c[5]),
				db(c[6]),
				db(c[7]),
				db(c[8])
			)
			matrixlib.Matrix4x4_Invert_Simple(imat, mat)
		elseif kind == "MAT" then
			local got, gotinv = {}, {}
			for r = 1, 4 do
				for col = 1, 4 do
					table.insert(got, fh(mat.m[r][col]))
					table.insert(gotinv, fh(imat.m[r][col]))
				end
			end
			t.eq(
				ctx,
				table.concat(got, "\t"),
				table.concat(c, "\t", 2, 17),
				`line {lineno}: Matrix4x4_CreateFromQuakeEntity`
			)
			-- the traces use the C matrix either way; the inverse is checked from it
			for r = 1, 4 do
				for col = 1, 4 do
					mat.m[r][col] = fb(c[1 + (r - 1) * 4 + col])
				end
			end
			matrixlib.Matrix4x4_Invert_Simple(imat, mat)
			gotinv = {}
			for r = 1, 4 do
				for col = 1, 4 do
					table.insert(gotinv, fh(imat.m[r][col]))
				end
			end
			t.eq(
				ctx,
				table.concat(gotinv, "\t"),
				table.concat(c, "\t", 18, 33),
				`line {lineno}: Matrix4x4_Invert_Simple`
			)
		elseif kind == "XCW" then
			last = collision.newtrace()
			collision.Collision_ClipToWorld(
				last,
				modelat(c[2]),
				v3(c, 6),
				v3(c, 9),
				v3(c, 12),
				v3(c, 15),
				num(c[3]),
				num(c[4]),
				num(c[5]),
				fb(c[18])
			)
			begin({ statestr(last) }, nil)
		elseif kind == "XCLW" then
			last = collision.newtrace()
			collision.Collision_ClipLineToWorld(
				last,
				modelat(c[2]),
				v3(c, 6),
				v3(c, 9),
				num(c[3]),
				num(c[4]),
				num(c[5]),
				fb(c[12]),
				c[13] ~= "0"
			)
			begin({ statestr(last) }, nil)
		elseif kind == "XCPW" then
			last = collision.newtrace()
			collision.Collision_ClipPointToWorld(last, modelat(c[2]), v3(c, 6), num(c[3]), num(c[4]), num(c[5]))
			begin({ statestr(last) }, nil)
		elseif kind == "XCG" then
			last = collision.newtrace()
			collision.Collision_ClipToGenericEntity(
				last,
				modelat(c[2]),
				nil,
				nil,
				v3(c, 7),
				v3(c, 10),
				num(c[6]),
				mat,
				imat,
				v3(c, 13),
				v3(c, 16),
				v3(c, 19),
				v3(c, 22),
				num(c[3]),
				num(c[4]),
				num(c[5]),
				fb(c[25])
			)
			begin({ statestr(last) }, nil)
		elseif kind == "XCLG" then
			last = collision.newtrace()
			collision.Collision_ClipLineToGenericEntity(
				last,
				modelat(c[2]),
				nil,
				nil,
				v3(c, 7),
				v3(c, 10),
				num(c[6]),
				mat,
				imat,
				v3(c, 13),
				v3(c, 16),
				num(c[3]),
				num(c[4]),
				num(c[5]),
				fb(c[19]),
				c[20] ~= "0"
			)
			begin({ statestr(last) }, nil)
		elseif kind == "XCPG" then
			last = collision.newtrace()
			collision.Collision_ClipPointToGenericEntity(
				last,
				modelat(c[2]),
				nil,
				nil,
				v3(c, 7),
				v3(c, 10),
				num(c[6]),
				mat,
				imat,
				v3(c, 13),
				num(c[3]),
				num(c[4]),
				num(c[5])
			)
			begin({ statestr(last) }, nil)
		elseif kind == "EP" then
			t.eq(
				ctx,
				dh(last.endpos[1]) .. "\t" .. dh(last.endpos[2]) .. "\t" .. dh(last.endpos[3]),
				table.concat(c, "\t", 2),
				`{label}: endpos`
			)
		elseif kind == "SETCLIP" then
			clip = copytrace(last)
		elseif kind == "COMB" then
			collision.Collision_CombineTraces(clip, last, num(c[3]), c[2] ~= "0")
		elseif kind == "CS" then
			local got = table.concat({
				if clip.allsolid then "1" else "0",
				if clip.startsolid then "1" else "0",
				if clip.bmodelstartsolid then "1" else "0",
				if clip.inwater then "1" else "0",
				dh(clip.fraction),
				dh(clip.endpos[1]),
				dh(clip.endpos[2]),
				dh(clip.endpos[3]),
				fh(clip.plane.normal[1]),
				fh(clip.plane.normal[2]),
				fh(clip.plane.normal[3]),
				fh(clip.plane.dist),
				tostring(clip.ent or 0),
				tostring(clip.hitsupercontents),
				tostring(clip.hitq3surfaceflags),
				texidx(clip.hittexture),
				tostring(clip.startsupercontents),
				dh(clip.startdepth),
				dh(clip.startdepthnormal[1]),
				dh(clip.startdepthnormal[2]),
				dh(clip.startdepthnormal[3]),
			}, "\t")
			t.eq(ctx, got, table.concat(c, "\t", 2), `line {lineno}: Collision_CombineTraces`)
		elseif kind == "S" then
			local k = num(c[2]) + 1
			seen[k] = true
			t.eq(ctx, after[k], table.concat(c, "\t", 3), `{label}: state after list entry {k - 1}`)
		elseif kind == "E" then
			t.eq(ctx, after[#after], table.concat(c, "\t", 3), `{label}: final trace`)
			local same = true
			for i = 1, #after do
				if #after > 1 and changed[i] ~= (seen[i] == true) then
					same = false
				end
			end
			t.ok(ctx, same, `{label}: the trace changed at the same list entries as in C`)
		elseif kind == "END" then
			t.ok(ctx, true, "reached the end of the vector file")
		end
	end
	console.sink = oldsink
	cvar.reset()
end
