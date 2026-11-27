--!strict
-- M4-ALIAS: engine/model_alias.luau and engine/model_sprite.luau against the release's C build
-- (tools/testgen/alias_vectors.c -> tests/vectors/alias.tsv): the fixture models of tests/fixtures/models/ load
-- through model_shared.Mod_ForName, and every line the C program prints (every field the loaders set, the
-- arrays as hex bytes, tag matrices, animated vertices, traces) is rebuilt here from the Luau data and must be
-- identical. The "SSE" lines say whether the release's SSE skeletal code (not ported) gives other bits than the
-- generic code; they are counted and printed, not compared.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local defs = require("../../engine/_port/sv_init_defs")
local f32 = require("../../engine/_port/f32")
local fs = require("../../engine/fs")
local matrixlib = require("../../engine/matrixlib")
local model_brush = require("../../engine/model_brush")
local model_shared = require("../../engine/model_shared")
local model_alias = require("../../engine/model_alias")

local ROOT = "tests/fixtures/models/"
local R = f32.round

local function hexf(x: number?): string
	return string.format("\t%08x", f32.tobits(x or 0))
end
local function hexv(v: { number }?): string
	local w = v or { 0, 0, 0 }
	return hexf(w[1]) .. hexf(w[2]) .. hexf(w[3])
end
local function dbits(x: number): string
	local lo, hi = string.unpack("<I4I4", string.pack("<d", x))
	return string.format("\t%08x%08x", hi, lo)
end
local function I(v: any): string
	if v == nil or v == false then
		return "\t0"
	elseif v == true then
		return "\t1"
	end
	return string.format("\t%d", v)
end
local function S(s: string?): string
	if s == nil then
		return "\t(null)"
	end
	local out = { "\t" }
	for i = 1, #s do
		local c = string.byte(s, i)
		if c == 92 then
			table.insert(out, "\\\\")
		elseif c == 9 then
			table.insert(out, "\\t")
		elseif c == 10 then
			table.insert(out, "\\n")
		elseif c == 13 then
			table.insert(out, "\\r")
		elseif c < 0x20 or c >= 0x7f then
			table.insert(out, string.format("\\x%02x", c))
		else
			table.insert(out, string.char(c))
		end
	end
	return table.concat(out)
end
local function A(name: string, b: buffer?, n: number): string
	if not b then
		return "A\t" .. name .. "\t-"
	end
	local hex = table.create(n)
	for i = 0, n - 1 do
		hex[i + 1] = string.format("%02x", buffer.readu8(b, i))
	end
	return string.format("A\t%s\t%d\t%s", name, n, table.concat(hex))
end
local function M(m: matrixlib.matrix4x4_t): string
	local s = ""
	for r = 1, 3 do
		for c = 1, 4 do
			s ..= hexf(m.m[r][c])
		end
	end
	return s
end

local MODTYPE = { mod_invalid = 0, mod_brushq1 = 1, mod_sprite = 2, mod_alias = 3, mod_brushq3 = 5, mod_null = 7 }

-- av_makefb (alias_vectors.c): subframes modulo num_poses
local FBSUB = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 2, 0 }, { 1, 2, 3 }, { 3, 0, 0 }, { 2, 1, 0 } }
local FBLERP = { { 1, 0, 0 }, { 1, 0, 0 }, { 0.25, 0.75, 0 }, { 0.5, 0.3, 0.2 }, { 0.7, 0, 0 }, { 0.6, 0.6, 0 } }
local function makefb(m: any, c: number): any
	local n = if (m.num_poses or 0) > 0 then m.num_poses else 1
	local fb = model_alias.newframeblend()
	for k = 1, 3 do
		fb[k].subframe = FBSUB[c + 1][k] % n
		fb[k].lerp = R(FBLERP[c + 1][k])
	end
	return fb
end

local function scene(tag: string, i: number, s: any): string
	return tag .. I(i) .. S(s.name) .. I(s.firstframe) .. I(s.framecount) .. I(s.loop) .. hexf(s.framerate)
end

local function modellines(m: any): { string }
	local out: { string } = {}
	local function add(s: string)
		table.insert(out, s)
	end
	local sm = m.surfmesh or {}
	add("F\tmodeldatatypestring" .. S(m.modeldatatypestring))
	add(
		"F\tints"
			.. I(MODTYPE[m.type] or 0)
			.. I(m.numframes)
			.. I(m.numskins)
			.. I(m.num_poses)
			.. I(m.num_bones)
			.. I(m.num_tags)
			.. I(m.num_tagframes)
			.. I(m.num_surfaces)
			.. I(m.nummodelsurfaces)
			.. I(m.num_textures)
			.. I(m.num_texturesperskin)
			.. I(m.synctype)
			.. I(m.effects)
			.. I(sm.num_vertices)
			.. I(sm.num_triangles)
			.. I(sm.num_blends)
			.. I(sm.num_morphframes)
			.. I(sm.isanimated)
	)
	local function kind(f: any, a: any, b: any): number
		return if f == nil then 0 elseif f == a then 1 elseif f == b then 2 else 9
	end
	local anim = if m.AnimateVertices == nil
		then 0
		elseif m.AnimateVertices == model_alias.Mod_Skeletal_AnimateVertices then 1
		elseif m.AnimateVertices == model_alias.Mod_MD3_AnimateVertices then 2
		elseif m.AnimateVertices == model_alias.Mod_MDL_AnimateVertices then 3
		else 9
	add(
		"F\tfuncs"
			.. I(m.DrawSky ~= nil)
			.. I(m.DrawAddWaterPlanes ~= nil)
			.. I(kind(m.TraceBox, model_brush.Mod_CollisionBIH_TraceBox, model_alias.Mod_MDLMD2MD3_TraceBox))
			.. I(kind(m.TraceLine, model_brush.Mod_CollisionBIH_TraceLine, model_alias.Mod_MDLMD2MD3_TraceLine))
			.. I(m.TraceBrush ~= nil)
			.. I(m.TracePoint ~= nil)
			.. I(m.PointSuperContents ~= nil)
			.. I(anim)
	)
	add(
		"F\tfloats"
			.. hexf(m.num_posescale)
			.. hexf(m.num_poseinvscale)
			.. hexv(m.normalmins)
			.. hexv(m.normalmaxs)
			.. hexv(m.yawmins)
			.. hexv(m.yawmaxs)
			.. hexv(m.rotatedmins)
			.. hexv(m.rotatedmaxs)
			.. hexf(m.radius)
			.. hexf(m.radius2)
	)
	local b = m.collision_bih
	local bl = "F\tbih" .. I(b and b.numleafs) .. I(b and b.numnodes)
	if b and b.numleafs ~= 0 then
		bl ..= I(b.rootnode) .. hexv(b.mins) .. hexv(b.maxs)
	end
	add(bl)
	if m.type == "mod_sprite" then
		add("F\tsprite" .. I(m.sprite.sprnum_type))
		for i = 0, m.num_textures - 1 do
			local fr = m.sprite.sprdata_frames[i + 1]
			add("SPRF" .. I(i) .. hexf(fr.left) .. hexf(fr.right) .. hexf(fr.up) .. hexf(fr.down))
		end
	end
	for i = 0, (m.numframes or 0) - 1 do
		add(scene("SC", i, m.animscenes[i + 1]))
	end
	if m.skinscenes then
		for i = 0, (m.numskins or 0) - 1 do
			add(scene("SK", i, m.skinscenes[i + 1]))
		end
	end
	for i = 0, (m.num_bones or 0) - 1 do
		local bo = m.data_bones[i + 1]
		add("BONE" .. I(i) .. S(bo.name) .. I(bo.flags) .. I(bo.parent))
	end
	for i = 0, (m.num_tags or 0) * (m.num_tagframes or 0) - 1 do
		local tg = m.data_tags[i + 1]
		local s = "TAG" .. I(i) .. S(tg.name)
		for k = 1, 12 do
			s ..= hexf(tg.matrixgl[k])
		end
		add(s)
	end
	for i = 0, (m.num_surfaces or 0) - 1 do
		local s = m.data_surfaces[i + 1]
		add(
			"SURF"
				.. I(i)
				.. I(if s.texture then s.texture.index else -1)
				.. I(s.num_firsttriangle)
				.. I(s.num_triangles)
				.. I(s.num_firstvertex)
				.. I(s.num_vertices)
				.. I(m.sortedmodelsurfaces[i + 1])
		)
	end
	for i = 0, (m.num_textures or 0) - 1 do
		local tx = m.data_textures[i + 1]
		add(
			"TEX"
				.. I(i)
				.. S(tx.name or "")
				.. I(tx.basematerialflags)
				.. I(tx.currentmaterialflags)
				.. I(tx.supercontents)
				.. I(tx.surfaceflags)
				.. I(tx.offsetmapping)
				.. hexf(tx.offsetscale)
				.. hexf(tx.specularscalemod)
				.. hexf(tx.basealpha)
				.. I(tx.transparentsort)
				.. I(tx.materialshaderpass ~= nil)
				.. I(tx.currentframe == tx)
		)
	end
	local nv, nt = sm.num_vertices or 0, sm.num_triangles or 0
	local nmf = sm.num_morphframes or 0
	add(A("element3i", sm.data_element3i, nt * 12))
	add(A("element3s", sm.data_element3s, nt * 6))
	add(A("neighbor3i", sm.data_neighbor3i, nt * 12))
	add(A("vertex3f", sm.data_vertex3f, nv * 12))
	add(A("svector3f", sm.data_svector3f, nv * 12))
	add(A("tvector3f", sm.data_tvector3f, nv * 12))
	add(A("normal3f", sm.data_normal3f, nv * 12))
	add(A("texcoordtexture2f", sm.data_texcoordtexture2f, nv * 8))
	add(A("lightmapcolor4f", sm.data_lightmapcolor4f, nv * 16))
	add(A("skeletalindex4ub", sm.data_skeletalindex4ub, nv * 4))
	add(A("skeletalweight4ub", sm.data_skeletalweight4ub, nv * 4))
	add(A("blends", sm.blends, nv * 2))
	add(A("blendweights", if (sm.num_blends or 0) ~= 0 then sm.data_blendweights else nil, (sm.num_blends or 0) * 8))
	add(A("poses7s", m.data_poses7s, (m.num_poses or 0) * (m.num_bones or 0) * 14))
	add(A("baseboneposeinverse", m.data_baseboneposeinverse, (m.num_bones or 0) * 48))
	add(A("morphmd3vertex", sm.data_morphmd3vertex, nv * nmf * 8))
	add(A("morphmdlvertex", sm.data_morphmdlvertex, nv * nmf * 4))
	add(A("morphtexvecvertex", sm.data_morphtexvecvertex, nv * nmf * 6))
	add(A("morphmd2framesize6f", sm.data_morphmd2framesize6f, (m.numframes or 0) * 24))
	add("F\tmorphmdl" .. hexv(sm.num_morphmdlframescale) .. hexv(sm.num_morphmdlframetranslate))

	-- tags (av_tags)
	local n = if (m.num_bones or 0) ~= 0 then m.num_bones else (m.num_tags or 0)
	for c = 0, 5 do
		local fb = makefb(m, c)
		for i = -1, n do
			local mat = matrixlib.new()
			local ret = model_alias.Mod_Alias_GetTagMatrix(m, fb, nil, i, mat)
			add("TAGM" .. I(c) .. I(i) .. I(ret) .. M(mat))
			mat = matrixlib.new()
			local ret2, parent, tagname = model_alias.Mod_Alias_GetExtendedTagInfoForIndex(m, 0, fb, nil, i, mat)
			add("TAGX" .. I(c) .. I(i) .. I(ret2) .. I(parent or -99) .. S(tagname or "-") .. M(mat))
		end
	end
	if (m.num_bones or 0) ~= 0 and m.num_bones <= 8 then
		local rel = {}
		for i = 0, m.num_bones - 1 do
			local r = matrixlib.new()
			matrixlib.Matrix4x4_FromBonePose7s(
				r,
				m.num_posescale,
				m.data_poses7s,
				14 * ((1 % m.num_poses) * m.num_bones + i)
			)
			r.m[1][4] = R(r.m[1][4] + R(0.125 * i))
			rel[i + 1] = r
		end
		local skel = { model = m, relativetransforms = rel }
		for i = -1, n do
			local mat = matrixlib.new()
			local ret = model_alias.Mod_Alias_GetTagMatrix(m, nil, skel, i, mat)
			add("TAGS" .. I(i) .. I(ret) .. M(mat))
		end
	end
	for i = 0, (m.num_bones or 0) - 1 do
		local nm = m.data_bones[i + 1].name
		add(
			"TAGN"
				.. I(i)
				.. I(model_alias.Mod_Alias_GetTagIndexForName(m, 0, nm))
				.. I(model_alias.Mod_Alias_GetTagIndexForName(m, 7, string.upper(string.sub(nm, 1, 63))))
		)
	end
	for i = 0, (m.num_tags or 0) - 1 do
		add(
			"TAGN"
				.. I(i)
				.. I(model_alias.Mod_Alias_GetTagIndexForName(m, 0, m.data_tags[i + 1].name))
				.. I(model_alias.Mod_Alias_GetTagIndexForName(m, 1, "TAG_HEAD"))
		)
	end
	add("TAGN\t-1" .. I(model_alias.Mod_Alias_GetTagIndexForName(m, 0, "nonexistent")))

	-- animation (av_anim)
	if m.AnimateVertices and nv ~= 0 then
		local sz = (nv + 4) * 12
		for c = 0, 5 do
			local fb = makefb(m, c)
			for mode = 0, 2 do
				local v, nn, s, tt = buffer.create(sz), buffer.create(sz), buffer.create(sz), buffer.create(sz)
				m.AnimateVertices(
					m,
					fb,
					nil,
					if mode ~= 2 then v else nil,
					if mode ~= 1 then nn else nil,
					if mode ~= 1 then s else nil,
					if mode ~= 1 then tt else nil
				)
				add("ANIM" .. I(c) .. I(mode))
				if mode ~= 2 then
					add(A("v", v, nv * 12))
				end
				if mode ~= 1 then
					add(A("n", nn, nv * 12))
					add(A("s", s, nv * 12))
					add(A("t", tt, nv * 12))
				end
			end
		end
	end

	-- traces (av_trace)
	if m.TraceBox and m.TraceLine then
		local starts = { { -40, 1.5, 2.25 }, { 0.5, -50, 0.75 }, { 3, 4, 60 }, { -30, -30, -30 } }
		local ends = { { 40, -1.25, 1.75 }, { -0.25, 50, -0.5 }, { -2, -3, -60 }, { 30, 30, 30 } }
		local mins = { { 0, 0, 0 }, { -2, -2, -3 }, { 1, 1, 1 } }
		local maxs = { { 0, 0, 0 }, { 2, 2, 4 }, { 1, 1, 1 } }
		for c = 0, 2 do
			local fb = makefb(m, if c == 2 then 3 else c)
			for k = 0, 3 do
				for bx = -1, 2 do
					local tr = collision.newtrace()
					if bx < 0 then
						m.TraceLine(m, if c ~= 0 then fb else nil, nil, tr, starts[k + 1], ends[k + 1], 1, 0, 0)
					else
						m.TraceBox(
							m,
							if c ~= 0 then fb else nil,
							nil,
							tr,
							starts[k + 1],
							mins[bx + 1],
							maxs[bx + 1],
							ends[k + 1],
							0x1001,
							0,
							0
						)
					end
					add(
						"TR"
							.. I(c)
							.. I(k)
							.. I(bx)
							.. I(tr.allsolid)
							.. I(tr.startsolid)
							.. dbits(tr.fraction)
							.. dbits(tr.endpos[1])
							.. dbits(tr.endpos[2])
							.. dbits(tr.endpos[3])
							.. hexv(tr.plane.normal)
							.. hexf(tr.plane.dist)
							.. I(tr.hitsupercontents)
							.. I(tr.hitq3surfaceflags)
							.. I(if tr.hittexture then tr.hittexture.index else -1)
							.. I(tr.startsupercontents)
					)
				end
			end
		end
	end
	return out
end

return function(ctx: t.Ctx)
	local vectors = "tests/vectors/alias.tsv"
	if not lfs.isFile(vectors) then
		t.skip(ctx, "tests/vectors/alias.tsv not generated yet (tools/testgen/alias_vectors.sh)")
		return
	end
	-- the C output, split per model; the SSE lines are information only
	local cmodels: { { name: string, lines: { string } } } = {}
	local sse = { same = 0, differ = 0 }
	for line in string.gmatch(t.read(vectors), "[^\n]+") do
		line = string.gsub(line, "\r$", "")
		local name = string.match(line, "^MODEL\t(.*)$")
		if name then
			table.insert(cmodels, { name = name, lines = {} })
		elseif line == "END" then
			break
		elseif string.sub(line, 1, 4) == "SSE\t" then
			local c = string.split(line, "\t")
			for k = 3, 6 do
				if c[k] == "0" then
					sse.same += 1
				else
					sse.differ += 1
				end
			end
		elseif #cmodels > 0 then
			table.insert(cmodels[#cmodels].lines, line)
		end
	end

	-- the fixture directory as the virtual file system
	local files: { string } = {}
	local known: { [string]: boolean } = {}
	local function walk(dir: string, rel: string)
		for _, name in lfs.readDir(dir) do
			local p = dir .. "/" .. name
			local r = if rel == "" then name else rel .. "/" .. name
			if lfs.isDir(p) then
				walk(p, r)
			else
				table.insert(files, r)
				known[r] = true
			end
		end
	end
	walk(string.sub(ROOT, 1, -2), "")
	fs.SetProvider({
		files = files,
		load = function(p: string): string?
			return if known[p] then lfs.readFile(ROOT .. p) else nil
		end,
		pack = function(p: string): string?
			return if known[p] then "fixtures.pk3" else nil
		end,
	})
	cvar.reset()
	cvar.cls_state_dedicated = true
	for _, d in defs do
		if d[1] == "cvar" then
			cvar.Cvar_RegisterVariable(cvar.static(d[3], d[4], d[5], d[6]))
		end
	end
	collision.Collision_Init()
	local oldsink = console.sink
	console.sink = function(_line: string) end
	local ok, err = pcall(function()
		model_shared.Mod_FreeQ3Shaders()
		model_shared.Mod_Init()
		for _, cm in cmodels do
			local m = model_shared.Mod_ForName(cm.name, true, false, nil)
			local lines = modellines(m)
			t.eq(ctx, #lines, #cm.lines, cm.name .. ": number of lines")
			for i = 1, math.max(#lines, #cm.lines) do
				local got, want = lines[i], cm.lines[i]
				if got ~= want then
					local tag = string.match(want or got or "", "^[^\t]*\t[^\t]*") or "?"
					t.eq(ctx, got, want, string.format("%s line %d (%s)", cm.name, i, tag))
				else
					ctx.checks += 1
				end
			end
		end
	end)
	console.sink = oldsink
	model_shared.Mod_FreeQ3Shaders()
	fs.SetProvider(nil)
	cvar.reset()
	t.ok(ctx, ok, tostring(err))
	print(
		string.format(
			"  SSE skeletal code vs generic (C build): %d arrays identical, %d differ (the port has the generic code)",
			sse.same,
			sse.differ
		)
	)
end
