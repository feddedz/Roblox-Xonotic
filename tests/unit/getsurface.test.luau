--!strict
-- The surface builtins of engine/prvm_cmds.luau (prvm_cmds.c L6830-7260: getsurfacenumpoints #434,
-- getsurfacepoint #435, getsurfacenormal #436, getsurfacetexture #437, getsurfacenearpoint #438,
-- getsurfaceclippedpoint #439, getsurfacepointattribute #486, getsurfacenumtriangles #628,
-- getsurfacetriangle #629) on a stock map: the world (edict 0) and a brush entity (a *N submodel), first
-- unmoved, then rotated + translated (+ scaled) so the matrix paths run. Every expected value is computed here
-- from the model arrays with the C formulas (float rounding per operation, D-004); out-of-range surface and
-- point indexes; nearpoint / clippedpoint for points inside a triangle, on an edge, on a vertex and far away.
-- Needs game data (work/vfs-high); skips without it. No QuakeC runs: the prog comes from SV_VM_Setup.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local cvar = require("../../engine/cvar")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local svvm_cmds = require("../../engine/svvm_cmds")
local prvm_cmds = require("../../engine/prvm_cmds")
local prvm_edict = require("../../engine/prvm_edict")
local model_shared = require("../../engine/model_shared")
local matrixlib = require("../../engine/matrixlib")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

local R = f32.round
local readf32, readi32 = buffer.readf32, buffer.readi32
local OFS_RETURN, OFS_PARM0 = 1, 4

type V3 = { number }

-- C formulas (mathlib.h macros on float vectors)
local function dot(a: V3, b: V3): number
	return R(R(R(a[1] * b[1]) + R(a[2] * b[2])) + R(a[3] * b[3]))
end
local function normalize(v: V3): V3
	local il = R(math.sqrt(dot(v, v)))
	if il ~= 0 then
		il = R(1 / il)
	end
	return { R(v[1] * il), R(v[2] * il), R(v[3] * il) }
end
local function sub(a: V3, b: V3): V3
	return { R(a[1] - b[1]), R(a[2] - b[2]), R(a[3] - b[3]) }
end
local function cross(a: V3, b: V3): V3
	return {
		R(R(a[2] * b[3]) - R(a[3] * b[2])),
		R(R(a[3] * b[1]) - R(a[1] * b[3])),
		R(R(a[1] * b[2]) - R(a[2] * b[1])),
	}
end
local function ma(a: V3, s: number, b: V3): V3
	return { R(a[1] + R(s * b[1])), R(a[2] + R(s * b[2])), R(a[3] + R(s * b[3])) }
end
local function trinormal(a: V3, b: V3, c: V3): V3
	return {
		R(R(R(a[2] - b[2]) * R(c[3] - b[3])) - R(R(a[3] - b[3]) * R(c[2] - b[2]))),
		R(R(R(a[3] - b[3]) * R(c[1] - b[1])) - R(R(a[1] - b[1]) * R(c[3] - b[3]))),
		R(R(R(a[1] - b[1]) * R(c[2] - b[2])) - R(R(a[2] - b[2]) * R(c[1] - b[1]))),
	}
end
local function vat(b: buffer, i: number): V3
	return { readf32(b, 12 * i), readf32(b, 12 * i + 4), readf32(b, 12 * i + 8) }
end

-- matrixlib.c (row-major #else branches)
local function transform(m: any, v: V3): V3
	local a = m.m
	return {
		R(R(R(R(v[1] * a[1][1]) + R(v[2] * a[1][2])) + R(v[3] * a[1][3])) + a[1][4]),
		R(R(R(R(v[1] * a[2][1]) + R(v[2] * a[2][2])) + R(v[3] * a[2][3])) + a[2][4]),
		R(R(R(R(v[1] * a[3][1]) + R(v[2] * a[3][2])) + R(v[3] * a[3][3])) + a[3][4]),
	}
end
local function transform3x3(m: any, v: V3): V3
	local a = m.m
	return {
		R(R(R(v[1] * a[1][1]) + R(v[2] * a[1][2])) + R(v[3] * a[1][3])),
		R(R(R(v[1] * a[2][1]) + R(v[2] * a[2][2])) + R(v[3] * a[2][3])),
		R(R(R(v[1] * a[3][1]) + R(v[2] * a[3][2])) + R(v[3] * a[3][3])),
	}
end
local function positiveplane(m: any, n: V3): V3
	local a = m.m
	local scale = R(math.sqrt(R(R(R(a[1][1] * a[1][1]) + R(a[1][2] * a[1][2])) + R(a[1][3] * a[1][3]))))
	local iscale = R(1 / scale)
	return {
		R(R(R(R(n[1] * a[1][1]) + R(n[2] * a[1][2])) + R(n[3] * a[1][3])) * iscale),
		R(R(R(R(n[1] * a[2][1]) + R(n[2] * a[2][2])) + R(n[3] * a[2][3])) * iscale),
		R(R(R(R(n[1] * a[3][1]) + R(n[2] * a[3][2])) + R(n[3] * a[3][3])) * iscale),
	}
end
-- Matrix4x4_Invert_Full (matrixlib.c L147-197): adjoint with float ops, det, 1/det, scale
local function invertfull(m: any): any
	local a = m.m
	local function g(r: number, c: number): number
		return a[r + 1][c + 1]
	end
	local function d2(p: number, q: number, r: number, s: number): number
		return R(R(p * q) - R(r * s))
	end
	local m00, m01, m02, m03 = g(0, 0), g(0, 1), g(0, 2), g(0, 3)
	local m10, m11, m12, m13 = g(1, 0), g(1, 1), g(1, 2), g(1, 3)
	local m20, m21, m22, m23 = g(2, 0), g(2, 1), g(2, 2), g(2, 3)
	local m30, m31, m32, m33 = g(3, 0), g(3, 1), g(3, 2), g(3, 3)
	local function c3(x: number, xx: number, y: number, yy: number, z: number, zz: number): number
		return R(R(R(x * xx) - R(y * yy)) + R(z * zz))
	end
	local o = {
		{
			c3(m11, d2(m22, m33, m23, m32), m21, d2(m12, m33, m13, m32), m31, d2(m12, m23, m13, m22)),
			-c3(m01, d2(m22, m33, m23, m32), m21, d2(m02, m33, m03, m32), m31, d2(m02, m23, m03, m22)),
			c3(m01, d2(m12, m33, m13, m32), m11, d2(m02, m33, m03, m32), m31, d2(m02, m13, m03, m12)),
			-c3(m01, d2(m12, m23, m13, m22), m11, d2(m02, m23, m03, m22), m21, d2(m02, m13, m03, m12)),
		},
		{
			-c3(m10, d2(m22, m33, m23, m32), m20, d2(m12, m33, m13, m32), m30, d2(m12, m23, m13, m22)),
			c3(m00, d2(m22, m33, m23, m32), m20, d2(m02, m33, m03, m32), m30, d2(m02, m23, m03, m22)),
			-c3(m00, d2(m12, m33, m13, m32), m10, d2(m02, m33, m03, m32), m30, d2(m02, m13, m03, m12)),
			c3(m00, d2(m12, m23, m13, m22), m10, d2(m02, m23, m03, m22), m20, d2(m02, m13, m03, m12)),
		},
		{
			c3(m10, d2(m21, m33, m23, m31), m20, d2(m11, m33, m13, m31), m30, d2(m11, m23, m13, m21)),
			-c3(m00, d2(m21, m33, m23, m31), m20, d2(m01, m33, m03, m31), m30, d2(m01, m23, m03, m21)),
			c3(m00, d2(m11, m33, m13, m31), m10, d2(m01, m33, m03, m31), m30, d2(m01, m13, m03, m11)),
			-c3(m00, d2(m11, m23, m13, m21), m10, d2(m01, m23, m03, m21), m20, d2(m01, m13, m03, m11)),
		},
		{
			-c3(m10, d2(m21, m32, m22, m31), m20, d2(m11, m32, m12, m31), m30, d2(m11, m22, m12, m21)),
			c3(m00, d2(m21, m32, m22, m31), m20, d2(m01, m32, m02, m31), m30, d2(m01, m22, m02, m21)),
			-c3(m00, d2(m11, m32, m12, m31), m10, d2(m01, m32, m02, m31), m30, d2(m01, m12, m02, m11)),
			c3(m00, d2(m11, m22, m12, m21), m10, d2(m01, m22, m02, m21), m20, d2(m01, m12, m02, m11)),
		},
	}
	local det = R(R(R(R(m00 * o[1][1]) + R(m10 * o[1][2])) + R(m20 * o[1][3])) + R(m30 * o[1][4]))
	if det ~= 0 then
		det = R(1 / det)
		for r = 1, 4 do
			for c = 1, 4 do
				o[r][c] = R(o[r][c] * det)
			end
		end
	end
	return { m = o }
end

-- clippointtosurface (prvm_cmds.c L6968-7003)
local function clip(model: any, s: any, p: V3): V3
	local el, vb = model.surfmesh.data_element3i, model.surfmesh.data_vertex3f
	local best = 1000000000
	local out = { p[1], p[2], p[3] }
	for i = 0, s.num_triangles - 1 do
		local e = 3 * (s.num_firsttriangle + i)
		local v = { vat(vb, readi32(el, 4 * e)), vat(vb, readi32(el, 4 * e + 4)), vat(vb, readi32(el, 4 * e + 8)) }
		local fn = normalize(trinormal(v[1], v[2], v[3]))
		local temp = ma(p, R(dot(v[1], fn) - dot(p, fn)), fn)
		local k = 3
		for j = 1, 3 do
			local side = normalize(cross(sub(v[k], v[j]), fn))
			local od = R(dot(v[k], side) - dot(temp, side))
			if od < 0 then
				temp = ma(temp, od, side)
			end
			k = j
		end
		local dd = sub(temp, p)
		local dist = dot(dd, dd)
		if best > dist then
			best = dist
			out = temp
		end
	end
	return out
end

return function(ctx: t.Ctx)
	local dat, mapname = "work/vfs-high/progs.dat", "maps/stormkeep.bsp"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile("work/vfs-high/" .. mapname)) then
		t.skip(ctx, "needs work/vfs-high (game data)")
		return
	end
	console.sink = function(_l: string) end
	fs.SetProvider(p)
	host.Host_Init_Dedicated()
	server.Clear()
	svvm_cmds.VM_CustomStats_Clear()
	local prog: any = sv_main.SV_VM_Setup(buffer.fromstring(lfs.readFile(dat)), nil)
	prog.warning = function(_m: string) end
	t.ok(ctx, cvar.prvm_prog_list[0] == prog, "SV_VM_Setup made the SVVM_prog")
	local wm = model_shared.Mod_ForName(mapname, false, false, nil)
	fs.SetProvider(nil)
	console.sink = function(l: string)
		print(l)
	end
	local sv = server.sv
	sv.worldmodel = wm
	sv.models[1] = wm
	-- a submodel with triangles (the first *N whose surfaces have some)
	local sub_: any, subn = nil, 0
	for i = 1, wm.brush.numsubmodels - 1 do
		local m = wm.brush.submodels[i + 1]
		local tris = 0
		for s = 0, m.nummodelsurfaces - 1 do
			tris += m.data_surfaces[m.firstmodelsurface + s + 1].num_triangles
		end
		if tris >= 4 and m.nummodelsurfaces >= 2 then
			sub_, subn = m, i
			break
		end
	end
	t.ok(ctx, sub_ ~= nil, "a *N submodel with triangles")
	if not sub_ then
		return
	end
	sv.models[2] = sub_

	local function FO(f: string): number
		return prvm_edict.FieldOfs(prog, f)
	end
	local function setf(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + FO(f)) * 4, v)
	end
	local function setv(e: number, f: string, v: V3)
		for k = 1, 3 do
			buffer.writef32(prog.edictsfields, (e * prog.entityfields + FO(f) + k - 1) * 4, v[k])
		end
	end
	setf(0, "modelindex", 1)
	local ent = prvm_edict.PRVM_ED_Alloc(prog)
	setf(ent, "modelindex", 2)
	local nomodel = prvm_edict.PRVM_ED_Alloc(prog) -- modelindex 0: no model

	-- call a builtin: args are { "e", n } / { "f", x } / { "v", {x, y, z} }
	local function call(fn: (any) -> (), args: { { any } })
		prog.argc = #args
		for i, a in args do
			local o = (OFS_PARM0 + 3 * (i - 1)) * 4
			if a[1] == "e" then
				buffer.writei32(prog.globals, o, a[2])
			elseif a[1] == "f" then
				buffer.writef32(prog.globals, o, a[2])
			else
				buffer.writef32(prog.globals, o, a[2][1])
				buffer.writef32(prog.globals, o + 4, a[2][2])
				buffer.writef32(prog.globals, o + 8, a[2][3])
			end
		end
		-- poison the return slots so a builtin that does not write them is noticed
		buffer.writef32(prog.globals, OFS_RETURN * 4, 12345)
		buffer.writef32(prog.globals, OFS_RETURN * 4 + 4, 12345)
		buffer.writef32(prog.globals, OFS_RETURN * 4 + 8, 12345)
		fn(prog)
	end
	local function retf(): number
		return readf32(prog.globals, OFS_RETURN * 4)
	end
	local function retv(): V3
		return { readf32(prog.globals, 4), readf32(prog.globals, 8), readf32(prog.globals, 12) }
	end
	local function veq(got: V3, want: V3, msg: string)
		t.ok(
			ctx,
			got[1] == want[1] and got[2] == want[2] and got[3] == want[3],
			string.format(
				"%s: got %.9g %.9g %.9g, want %.9g %.9g %.9g",
				msg,
				got[1],
				got[2],
				got[3],
				want[1],
				want[2],
				want[3]
			)
		)
	end
	local B = prvm_cmds

	-- the entity matrix the C builds (SV_GetEntityMatrix: scale 0 -> 1, pitch sign 1 for brush models)
	local function entmatrix(e: number): any
		local function g(f: string, k: number): number
			return readf32(prog.edictsfields, (e * prog.entityfields + FO(f) + k) * 4)
		end
		local scale = g("scale", 0)
		if scale == 0 then
			scale = 1
		end
		local m = matrixlib.new()
		matrixlib.Matrix4x4_CreateFromQuakeEntity(
			m,
			g("origin", 0),
			g("origin", 1),
			g("origin", 2),
			R(1 * g("angles", 0)),
			g("angles", 1),
			g("angles", 2),
			scale
		)
		return m
	end

	local checked = { surfaces = 0, points = 0, near = 0 }
	-- every per-surface builtin on surface number s (0-based within the model) of edict e
	local function checksurface(e: number, model: any, s: number, label: string)
		local surf = model.data_surfaces[model.firstmodelsurface + s + 1]
		local m = entmatrix(e)
		local vb = model.surfmesh.data_vertex3f
		checked.surfaces += 1
		call(B.VM_getsurfacenumpoints, { { "e", e }, { "f", s } })
		t.eq(ctx, retf(), surf.num_vertices, label .. ": getsurfacenumpoints")
		call(B.VM_getsurfacenumtriangles, { { "e", e }, { "f", s } })
		t.eq(ctx, retf(), surf.num_triangles, label .. ": getsurfacenumtriangles")
		call(B.VM_getsurfacetexture, { { "e", e }, { "f", s } })
		t.eq(
			ctx,
			prvm_edict.PRVM_GetString(prog, readi32(prog.globals, 4)),
			surf.texture.name,
			label .. ": getsurfacetexture"
		)
		-- getsurfacenormal: first three vertices, TransformPositivePlane, normalize
		call(B.VM_getsurfacenormal, { { "e", e }, { "f", s } })
		local fv = surf.num_firstvertex
		veq(
			retv(),
			normalize(positiveplane(m, trinormal(vat(vb, fv), vat(vb, fv + 1), vat(vb, fv + 2)))),
			label .. ": getsurfacenormal"
		)
		-- points (every vertex of small surfaces, the first and last 4 of big ones)
		for pn = 0, surf.num_vertices - 1 do
			if pn < 4 or pn >= surf.num_vertices - 4 then
				checked.points += 1
				local k = fv + pn
				local pl = string.format("%s point %d", label, pn)
				call(B.VM_getsurfacepoint, { { "e", e }, { "f", s }, { "f", pn } })
				veq(retv(), transform(m, vat(vb, k)), pl .. ": getsurfacepoint")
				local attr = {
					transform(m, vat(vb, k)),
					transform3x3(m, vat(model.surfmesh.data_svector3f, k)),
					transform3x3(m, vat(model.surfmesh.data_tvector3f, k)),
					transform3x3(m, vat(model.surfmesh.data_normal3f, k)),
					{
						readf32(model.surfmesh.data_texcoordtexture2f, 8 * k),
						readf32(model.surfmesh.data_texcoordtexture2f, 8 * k + 4),
						0,
					},
					{
						readf32(model.surfmesh.data_texcoordlightmap2f, 8 * k),
						readf32(model.surfmesh.data_texcoordlightmap2f, 8 * k + 4),
						0,
					},
					{
						readf32(model.surfmesh.data_lightmapcolor4f, 16 * k),
						readf32(model.surfmesh.data_lightmapcolor4f, 16 * k + 4),
						readf32(model.surfmesh.data_lightmapcolor4f, 16 * k + 8),
					},
					{ 0, 0, 0 }, -- attribute 7: default branch
				}
				for a = 0, 7 do
					call(B.VM_getsurfacepointattribute, { { "e", e }, { "f", s }, { "f", pn }, { "f", a } })
					veq(retv(), attr[a + 1], pl .. " attribute " .. a)
				end
			end
		end
		-- point index out of range (and a fractional index: (int) truncates)
		for _, pn in { -1, surf.num_vertices, surf.num_vertices + 0.5 } do
			call(B.VM_getsurfacepoint, { { "e", e }, { "f", s }, { "f", pn } })
			veq(retv(), { 0, 0, 0 }, label .. " point " .. pn .. " out of range")
			call(B.VM_getsurfacepointattribute, { { "e", e }, { "f", s }, { "f", pn }, { "f", 0 } })
			veq(retv(), { 0, 0, 0 }, label .. " attribute of point " .. pn .. " out of range")
		end
		call(B.VM_getsurfacepoint, { { "e", e }, { "f", s }, { "f", 0.75 } })
		veq(retv(), transform(m, vat(vb, fv)), label .. ": point index 0.75 truncates to 0")
		-- triangles: element numbers relative to the surface's first vertex, as floats
		local el = model.surfmesh.data_element3i
		for _, tn in { 0, surf.num_triangles - 1 } do
			local o = 12 * (surf.num_firsttriangle + tn)
			call(B.VM_getsurfacetriangle, { { "e", e }, { "f", s }, { "f", tn } })
			veq(retv(), {
				R(readi32(el, o) - fv),
				R(readi32(el, o + 4) - fv),
				R(readi32(el, o + 8) - fv),
			}, label .. " triangle " .. tn)
		end
		for _, tn in { -1, surf.num_triangles } do
			call(B.VM_getsurfacetriangle, { { "e", e }, { "f", s }, { "f", tn } })
			veq(retv(), { 0, 0, 0 }, label .. " triangle " .. tn .. " out of range")
		end
		-- clippedpoint: inside the first triangle (centroid), on an edge (midpoint), on a vertex, far away,
		-- each given in world space; the C clips Transform3x3(inverse matrix, point) (no -origin) and adds the
		-- entity origin back
		local o = 12 * surf.num_firsttriangle
		local v0, v1, v2 = vat(vb, readi32(el, o)), vat(vb, readi32(el, o + 4)), vat(vb, readi32(el, o + 8))
		local centroid = {
			R((v0[1] + v1[1] + v2[1]) / 3),
			R((v0[2] + v1[2] + v2[2]) / 3),
			R((v0[3] + v1[3] + v2[3]) / 3),
		}
		local edge = { R((v0[1] + v1[1]) / 2), R((v0[2] + v1[2]) / 2), R((v0[3] + v1[3]) / 2) }
		local inv = invertfull(m)
		local origin = {
			readf32(prog.edictsfields, (e * prog.entityfields + FO("origin")) * 4),
			readf32(prog.edictsfields, (e * prog.entityfields + FO("origin") + 1) * 4),
			readf32(prog.edictsfields, (e * prog.entityfields + FO("origin") + 2) * 4),
		}
		for pi, local_ in { centroid, edge, v2, { 100000, -100000, 50000 } } do
			local world = transform(m, local_) -- the model-space point placed in the world
			local q = transform3x3(inv, world)
			local c = clip(model, surf, q)
			call(B.VM_getsurfaceclippedpoint, { { "e", e }, { "f", s }, { "v", world } })
			veq(
				retv(),
				{ R(c[1] + origin[1]), R(c[2] + origin[2]), R(c[3] + origin[3]) },
				label .. " clippedpoint " .. pi
			)
		end
	end

	local function nonempty(model: any, want: number): { number }
		local list = {}
		for s = 0, model.nummodelsurfaces - 1 do
			local surf = model.data_surfaces[model.firstmodelsurface + s + 1]
			if surf.num_triangles >= 1 and surf.num_vertices >= 3 and #list < want then
				table.insert(list, s)
			end
		end
		-- and the surface with the most triangles (a patch or mesh on most maps)
		local most, mostn = -1, 0
		for s = 0, model.nummodelsurfaces - 1 do
			local n = model.data_surfaces[model.firstmodelsurface + s + 1].num_triangles
			if n > mostn then
				most, mostn = s, n
			end
		end
		if most >= 0 and not table.find(list, most) then
			table.insert(list, most)
		end
		return list
	end

	-- nearpoint (prvm_cmds.c L7159-7207): box distance first, then the clipped distance
	local function nearest(e: number, model: any, point: V3): number
		local inv = invertfull(entmatrix(e))
		local pp = transform3x3(inv, point)
		local best, bestdist = -1, 1000000000
		for s = 0, model.nummodelsurfaces - 1 do
			local surf = model.data_surfaces[model.firstmodelsurface + s + 1]
			local c = {}
			for k = 1, 3 do
				local mn, mx = surf.mins[k], surf.maxs[k]
				local b = if pp[k] >= mn then (if pp[k] < mx then pp[k] else mx) else mn
				c[k] = R(b - pp[k])
			end
			local dist = dot(c, c)
			if dist < bestdist then
				local d = sub(clip(model, surf, pp), pp)
				dist = R(dist + dot(d, d))
				if dist < bestdist then
					best, bestdist = s, dist
				end
			end
		end
		return best
	end
	local function checknear(e: number, model: any, label: string)
		local list = nonempty(model, 2)
		local m = entmatrix(e)
		local vb, el = model.surfmesh.data_vertex3f, model.surfmesh.data_element3i
		local pts: { V3 } = { { 100000, -100000, 50000 }, transform(m, { 0, 0, 0 }) }
		for _, s in list do
			local surf = model.data_surfaces[model.firstmodelsurface + s + 1]
			local o = 12 * surf.num_firsttriangle
			local v0, v1, v2 = vat(vb, readi32(el, o)), vat(vb, readi32(el, o + 4)), vat(vb, readi32(el, o + 8))
			table.insert(
				pts,
				transform(
					m,
					{ R((v0[1] + v1[1] + v2[1]) / 3), R((v0[2] + v1[2] + v2[2]) / 3), R((v0[3] + v1[3] + v2[3]) / 3) }
				)
			)
			table.insert(pts, transform(m, v1))
		end
		for i, pt in pts do
			checked.near += 1
			call(B.VM_getsurfacenearpoint, { { "e", e }, { "v", pt } })
			t.eq(ctx, retf(), nearest(e, model, pt), label .. " nearpoint " .. i)
		end
	end

	local function checkall(phase: string)
		for _, s in nonempty(wm, 3) do
			checksurface(0, wm, s, phase .. " world surface " .. s)
		end
		for _, s in nonempty(sub_, 3) do
			checksurface(ent, sub_, s, phase .. " *" .. subn .. " surface " .. s)
		end
		checknear(ent, sub_, phase .. " *" .. subn)
	end

	-- unmoved (identity matrices)
	checkall("unmoved")
	checknear(0, wm, "unmoved world")
	-- sanity, independent of the formulas: a point inside a world triangle clips onto itself (within 1/64)
	do
		local s = nonempty(wm, 1)[1]
		local surf = wm.data_surfaces[wm.firstmodelsurface + s + 1]
		local vb, el = wm.surfmesh.data_vertex3f, wm.surfmesh.data_element3i
		local o = 12 * surf.num_firsttriangle
		local v0, v1, v2 = vat(vb, readi32(el, o)), vat(vb, readi32(el, o + 4)), vat(vb, readi32(el, o + 8))
		local c = { (v0[1] + v1[1] + v2[1]) / 3, (v0[2] + v1[2] + v2[2]) / 3, (v0[3] + v1[3] + v2[3]) / 3 }
		call(B.VM_getsurfaceclippedpoint, { { "e", 0 }, { "f", s }, { "v", c } })
		local r = retv()
		t.ok(
			ctx,
			math.abs(r[1] - c[1]) < 1 / 64 and math.abs(r[2] - c[2]) < 1 / 64 and math.abs(r[3] - c[3]) < 1 / 64,
			"a point inside a world triangle clips onto itself"
		)
	end
	-- rotated + translated, then also scaled (pitch, yaw and roll all set: the full matrix branch)
	setv(ent, "origin", { 100.5, -37.25, 12 })
	setv(ent, "angles", { 10, 30, 5 })
	checkall("rotated")
	setf(ent, "scale", 1.25)
	checkall("scaled")
	-- sanity of the inverse: rotation+scale inverse times the matrix is the identity (3x3 part, within 1e-5)
	do
		local m = entmatrix(ent)
		local inv = invertfull(m)
		local okid = true
		for r = 1, 3 do
			for c = 1, 3 do
				local sum = 0
				for k = 1, 3 do
					sum += inv.m[r][k] * m.m[k][c]
				end
				if math.abs(sum - (if r == c then 1 else 0)) > 1e-5 then
					okid = false
				end
			end
		end
		t.ok(ctx, okid, "Matrix4x4_Invert_Full formula inverts the entity matrix")
	end

	-- out-of-range surfaces and entities without a model
	local nsurf = sub_.nummodelsurfaces
	for _, s in { -1, nsurf, nsurf + 1000, -0.5 } do
		local label = "surface " .. s
		if s == -0.5 then
			-- (int)-0.5 = 0: a valid surface
			call(B.VM_getsurfacenumpoints, { { "e", ent }, { "f", s } })
			t.eq(ctx, retf(), sub_.data_surfaces[sub_.firstmodelsurface + 1].num_vertices, "surface -0.5 is surface 0")
			continue
		end
		call(B.VM_getsurfacenumpoints, { { "e", ent }, { "f", s } })
		t.eq(ctx, retf(), 0, label .. ": getsurfacenumpoints 0")
		call(B.VM_getsurfacenumtriangles, { { "e", ent }, { "f", s } })
		t.eq(ctx, retf(), 0, label .. ": getsurfacenumtriangles 0")
		call(B.VM_getsurfacepoint, { { "e", ent }, { "f", s }, { "f", 0 } })
		veq(retv(), { 0, 0, 0 }, label .. ": getsurfacepoint")
		call(B.VM_getsurfacepointattribute, { { "e", ent }, { "f", s }, { "f", 0 }, { "f", 0 } })
		veq(retv(), { 0, 0, 0 }, label .. ": getsurfacepointattribute")
		call(B.VM_getsurfacenormal, { { "e", ent }, { "f", s } })
		veq(retv(), { 0, 0, 0 }, label .. ": getsurfacenormal")
		call(B.VM_getsurfacetexture, { { "e", ent }, { "f", s } })
		t.eq(ctx, readi32(prog.globals, 4), 0, label .. ": getsurfacetexture is OFS_NULL")
		call(B.VM_getsurfaceclippedpoint, { { "e", ent }, { "f", s }, { "v", { 1, 2, 3 } } })
		veq(retv(), { 0, 0, 0 }, label .. ": getsurfaceclippedpoint")
		call(B.VM_getsurfacetriangle, { { "e", ent }, { "f", s }, { "f", 0 } })
		veq(retv(), { 0, 0, 0 }, label .. ": getsurfacetriangle")
	end
	-- the world's surface count is its own nummodelsurfaces (submodel surfaces are not world surfaces)
	call(B.VM_getsurfacenumpoints, { { "e", 0 }, { "f", wm.nummodelsurfaces } })
	t.eq(ctx, retf(), 0, "world surface nummodelsurfaces is out of range")
	call(B.VM_getsurfacenumpoints, { { "e", nomodel }, { "f", 0 } })
	t.eq(ctx, retf(), 0, "entity without a model: getsurfacenumpoints 0")
	call(B.VM_getsurfacenearpoint, { { "e", nomodel }, { "v", { 0, 0, 0 } } })
	t.eq(ctx, retf(), -1, "entity without a model: getsurfacenearpoint -1")
	prvm_edict.PRVM_ED_Free(prog, nomodel)
	setf(nomodel, "modelindex", 2) -- a free entity is not looked at even with a model index
	call(B.VM_getsurfacenearpoint, { { "e", nomodel }, { "v", { 0, 0, 0 } } })
	t.eq(ctx, retf(), -1, "free entity: getsurfacenearpoint -1")
	call(B.VM_getsurfacenumpoints, { { "e", nomodel }, { "f", 0 } })
	t.eq(ctx, retf(), 0, "free entity: getsurfacenumpoints 0")
	print(
		string.format(
			"  getsurface: %s, world %d surfaces, *%d %d surfaces; %d surface checks, %d points, %d nearpoint queries",
			mapname,
			wm.nummodelsurfaces,
			subn,
			sub_.nummodelsurfaces,
			checked.surfaces,
			checked.points,
			checked.near
		)
	)
	server.Clear()
end
