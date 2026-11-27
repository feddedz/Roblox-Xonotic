--!strict
-- M4-ALIAS: every md3 / iqm / dpm / zym / mdl / spr / sp2 model of the release (work/vfs-high) loads through
-- model_shared.Mod_ForName (the real Mod_LoadModel dispatch, skin files, .framegroups, BIH), and what is loaded
-- matches an independent decoder of the file formats (tests/vectors/models.tsv, tools/testgen/models_vectors.py):
-- counts, frame / tag / bone names, element and bind-pose vertex checksums, the bounding boxes and radius where
-- the decoder can compute them. Needs game data.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local defs = require("../../engine/_port/sv_init_defs")
local f32 = require("../../engine/_port/f32")
local fs = require("../../engine/fs")
local model_shared = require("../../engine/model_shared")
local _model_brush = require("../../engine/model_brush") -- installs model_shared.Mod_BrushInit (Mod_Init calls it)
local vfs_provider = require("../_lib/vfs_provider")

-- checksum of tools/testgen/models_vectors.py (as q3bsp_vectors.py): words w[i] of the zero-padded data,
-- a = sum(w[i]), b = sum((w[i] & 0xFFFF) * (i % 65521 + 1) + (w[i] >> 16) * (i % 65519 + 1)), both mod 2^32
local function fnv(b: buffer?, len: number?): string
	if not b then
		return "-"
	end
	local n = len or buffer.len(b)
	local words = n // 4
	local readu32 = buffer.readu32
	local a, s = 0, 0
	local function add(i: number, w: number)
		a = (a + w) % 4294967296
		s = (s + (w % 65536) * (i % 65521 + 1) + (w // 65536) * (i % 65519 + 1)) % 4294967296
	end
	for i = 0, words - 1 do
		add(i, readu32(b, i * 4))
	end
	if n % 4 ~= 0 then
		local w = 0
		for k = 0, n % 4 - 1 do
			w += buffer.readu8(b, words * 4 + k) * 256 ^ k
		end
		add(words, w)
	end
	return string.format("%08x%08x", a, s)
end

local function hexf(x: number): string
	return string.format("%08x", f32.tobits(x))
end
local function vec(v: { number }?): string
	if not v then
		return "-"
	end
	return hexf(v[1]) .. "," .. hexf(v[2]) .. "," .. hexf(v[3])
end
local function names(list: { any }?, n: number): string
	local parts = {}
	for i = 1, n do
		parts[i] = if list and list[i] then list[i].name else ""
	end
	return fnv(buffer.fromstring(table.concat(parts, "\0")))
end

return function(ctx: t.Ctx)
	local provider = vfs_provider("high")
	if not provider or not lfs.isFile("tests/vectors/models.tsv") then
		t.skip(ctx, "needs work/vfs-high")
		return
	end
	-- the cvars of the dedicated init path (engine/host.luau registers the same table)
	cvar.reset()
	cvar.cls_state_dedicated = true
	for _, d in defs do
		if d[1] == "cvar" then
			cvar.Cvar_RegisterVariable(cvar.static(d[3], d[4], d[5], d[6]))
		end
	end
	fs.SetProvider(provider)
	local oldsink = console.sink
	local lines: { string } = {}
	console.sink = function(line: string)
		if #lines < 50 then
			table.insert(lines, line)
		end
	end
	model_shared.Mod_Init()

	local count, loaded = 0, 0
	for line in string.gmatch(t.read("tests/vectors/models.tsv"), "[^\r\n]+") do
		if string.sub(line, 1, 1) == "#" then
			continue
		end
		local c = string.split(line, "\t")
		local name = c[1]
		count += 1
		local ok, mod = pcall(model_shared.Mod_ForName, name, true, false, nil)
		t.ok(ctx, ok, `{name}: Mod_ForName: {tostring(mod)}`)
		if not ok then
			continue
		end
		loaded += 1
		local m: any = mod
		local sm = m.surfmesh or {}
		local col = 1
		local function want(got: any, what: string)
			col += 1
			if c[col] == "*" then
				return -- the decoder cannot compute it
			end
			t.eq(ctx, tostring(got), c[col], `{name}: {what}`)
		end
		want(m.modeldatatypestring, "type")
		want(m.numframes, "numframes")
		want(names(m.animscenes, m.numframes or 0), "animscene names")
		local fr = {}
		for i = 1, m.numframes or 0 do
			local s = m.animscenes[i]
			fr[i] = string.format("%d,%d,%d,%s", s.firstframe, s.framecount, if s.loop then 1 else 0, hexf(s.framerate))
		end
		want(fnv(buffer.fromstring(table.concat(fr, ";"))), "animscenes")
		want(m.num_poses or 0, "num_poses")
		want(m.num_bones or 0, "num_bones")
		want(names(m.data_bones, m.num_bones or 0), "bone names")
		local par = {}
		for i = 1, m.num_bones or 0 do
			par[i] = tostring(m.data_bones[i].parent)
		end
		want(table.concat(par, ","), "bone parents")
		want(m.num_tags or 0, "num_tags")
		want(names(m.data_tags, m.num_tags or 0), "tag names")
		want(m.num_surfaces or 0, "num_surfaces")
		want(m.numskins or 0, "numskins")
		want(sm.num_vertices or 0, "num_vertices")
		want(sm.num_triangles or 0, "num_triangles")
		want(fnv(sm.data_element3i), "element3i")
		want(fnv(sm.data_vertex3f), "vertex3f")
		want(fnv(sm.data_texcoordtexture2f), "texcoord2f")
		want(fnv(m.data_poses7s), "poses7s")
		want(vec(m.normalmins), "normalmins")
		want(vec(m.normalmaxs), "normalmaxs")
		want(vec(m.yawmins), "yawmins")
		want(vec(m.yawmaxs), "yawmaxs")
		want(vec(m.rotatedmins), "rotatedmins")
		want(vec(m.rotatedmaxs), "rotatedmaxs")
		want(hexf(m.radius or 0), "radius")
	end
	console.sink = oldsink
	for _, l in lines do
		print("  console: " .. l)
	end
	print(string.format("  %d models listed, %d loaded", count, loaded))
	fs.SetProvider(nil)
	cvar.reset()
end
