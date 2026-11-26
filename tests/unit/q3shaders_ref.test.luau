--!strict
-- Mod_LoadQ3Shaders / Mod_LoadTextureFromQ3Shader (engine/model_shared.luau) against the release's model_shared.c
-- and common.c compiled unchanged (tests/vectors/shader.tsv, tools/testgen/shader_vectors.sh), both run on the
-- fixture scripts of tests/fixtures/shaders/: every field of every shader in the hash, in bucket then chain
-- order, and every field Mod_LoadTextureFromQ3Shader sets on a zeroed texture_t, line for line, floats as bit
-- patterns. The vector file also carries the inputs (the cvar table, the two cvar configurations, the texture
-- cases), so nothing is duplicated here.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local common = require("../../engine/common")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local fs = require("../../engine/fs")
local model_shared = require("../../engine/model_shared")

local ROOT = "tests/fixtures/shaders/"

local function I(v: any): string
	if v == nil or v == false then
		return "0"
	elseif v == true then
		return "1"
	end
	return string.format("%d", v)
end
local function F(v: number?): string
	return string.format("%08x", f32.tobits(v or 0))
end
local function S(s: string?): string
	local out = {}
	for i = 1, #(s or "") do
		local c = string.byte(s :: string, i)
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
local function unescape(s: string): string
	local out = {}
	local i = 1
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			local n = string.sub(s, i + 1, i + 1)
			if n == "t" then
				table.insert(out, "\t")
			elseif n == "n" then
				table.insert(out, "\n")
			elseif n == "r" then
				table.insert(out, "\r")
			elseif n == "x" then
				table.insert(out, string.char(tonumber(string.sub(s, i + 2, i + 3), 16) :: number))
				i += 2
			else
				table.insert(out, n)
			end
			i += 2
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end
-- all fields zero, as the C memcmp with a zeroed struct (-0.0 is not zero); a texture name list is a pointer
local function iszero(v: any): boolean
	if v == nil or v == false or v == "" then
		return true
	elseif type(v) == "number" then
		return v == 0 and 1 / v > 0
	elseif type(v) == "table" then
		for k, x in v do
			if k == "texturename" or not iszero(x) then
				return false
			end
		end
		return true
	end
	return false
end
local function floats(a: { number }?, n: number, out: { string })
	for k = 1, n do
		table.insert(out, F(if a then a[k] else 0))
	end
end
local function gen(g: any, kind: string, nparms: number, out: { string })
	table.insert(out, I(g[kind]))
	floats(g.parms, nparms, out)
	if g.waveparms then
		table.insert(out, I(g.wavefunc))
		floats(g.waveparms, 4, out)
	end
end
local function tcmods(m: { any }, out: { string })
	for k = 1, 8 do
		local e = m[k]
		if iszero(e) then
			table.insert(out, "Z")
		else
			gen(e, "tcmod", 6, out)
		end
	end
end
local function deform(d: any): string
	if iszero(d) then
		return "Z"
	end
	local out = {}
	gen(d, "deform", 3, out)
	return table.concat(out, "\t")
end

local function shaderlines(s: any): { string }
	local lines = {}
	local o = {
		"S",
		I(common.CRC_Block_CaseInsensitive(s.name) % 1021),
		S(s.name),
		I(s.surfaceparms),
		I(s.surfaceflags),
		I(s.textureflags),
		I(s.numlayers),
		I(s.lighting),
		I(s.vertexalpha),
		I(s.textureblendalpha),
		S(s.skyboxname),
		I(s.dpnortlight),
		I(s.dpshadow),
		I(s.dpnoshadow),
		I(s.dpmeshcollisions),
		I(s.dpshaderkill),
		S(s.dpreflectcube),
		F(s.reflectmin),
		F(s.reflectmax),
		F(s.refractfactor),
	}
	floats(s.refractcolor4f, 4, o)
	table.insert(o, F(s.reflectfactor))
	floats(s.reflectcolor4f, 4, o)
	table.insert(o, F(s.r_water_wateralpha))
	floats(s.r_water_waterscroll, 2, o)
	for _, v in
		{
			I(s.offsetmapping),
			F(s.offsetscale),
			F(s.offsetbias),
			F(s.biaspolygonoffset),
			F(s.biaspolygonfactor),
			I(s.transparentsort),
			F(s.specularscalemod),
			F(s.specularpowermod),
			F(s.rtlightambient),
		}
	do
		table.insert(o, v)
	end
	table.insert(lines, table.concat(o, "\t"))
	for i = 0, 7 do
		local l = s.layers[i + 1]
		if iszero(l) then
			table.insert(lines, `L\t{i}\tZ`)
			continue
		end
		local p = {
			"L",
			tostring(i),
			I(l.alphatest),
			I(l.clampmap),
			F(l.framerate),
			I(l.numframes),
			I(l.dptexflags),
			I(l.blendfunc[1]),
			I(l.blendfunc[2]),
		}
		gen(l.rgbgen, "rgbgen", 3, p)
		gen(l.alphagen, "alphagen", 1, p)
		gen(l.tcgen, "tcgen", 6, p)
		if l.texturename == nil then
			table.insert(p, "-")
		else
			table.insert(p, I(l.numframes))
			for j = 1, l.numframes do
				table.insert(p, S(l.texturename[j]))
			end
		end
		tcmods(l.tcmods, p)
		table.insert(lines, table.concat(p, "\t"))
	end
	for k = 0, 3 do
		table.insert(lines, `D\t{k}\t{deform(s.deforms[k + 1])}`)
	end
	return lines
end

local function texturelines(idx: number, tex: any, ret: boolean): { string }
	local lines = {}
	local passes = tex.shaderpasses or {}
	local function passindex(p: any): number
		if p == nil then
			return -1
		end
		for k = 1, 8 do
			if passes[k] == p then
				return k - 1
			end
		end
		return -2
	end
	local n = 0
	for k = 1, 8 do
		if passes[k] then
			n += 1
		end
	end
	local cb = tex.customblendfunc or { 0, 0 }
	local o = {
		"T",
		tostring(idx),
		I(ret),
		S(tex.name),
		F(tex.basealpha),
		I(tex.basematerialflags),
		I(tex.surfaceflags),
		I(tex.supercontents),
		I(cb[1]),
		I(cb[2]),
		I(tex.transparentsort),
		I(tex.offsetmapping),
		F(tex.offsetscale),
		F(tex.offsetbias),
		F(tex.biaspolygonoffset),
		F(tex.biaspolygonfactor),
		F(tex.specularscalemod),
		F(tex.specularpowermod),
		F(tex.rtlightambient),
		F(tex.reflectmin),
		F(tex.reflectmax),
		F(tex.refractfactor),
	}
	floats(tex.refractcolor4f, 4, o)
	table.insert(o, F(tex.reflectfactor))
	floats(tex.reflectcolor4f, 4, o)
	table.insert(o, F(tex.r_water_wateralpha))
	floats(tex.r_water_waterscroll, 2, o)
	for _, v in
		{
			I(tex.startpreshaderpass),
			I(tex.endpreshaderpass),
			I(tex.startpostshaderpass),
			I(tex.endpostshaderpass),
			I(passindex(tex.materialshaderpass)),
			I(passindex(tex.backgroundshaderpass)),
			I(n),
			I(tex.currentframe == tex),
			I(tex.currentskinframe ~= nil),
			I(tex.backgroundcurrentskinframe ~= nil),
			I(tex.reflectcubetexture ~= nil),
			S(model_shared.loadmodel.brush.skybox),
		}
	do
		table.insert(o, v)
	end
	table.insert(lines, table.concat(o, "\t"))
	for k = 1, 8 do
		local p = passes[k]
		if not p then
			continue
		end
		local q = {
			"TP",
			tostring(idx),
			tostring(k - 1),
			I(p.alphatest),
			F(p.framerate),
			I(p.numframes),
			I(p.blendfunc[1]),
			I(p.blendfunc[2]),
		}
		gen(p.rgbgen, "rgbgen", 3, q)
		gen(p.alphagen, "alphagen", 1, q)
		gen(p.tcgen, "tcgen", 6, q)
		tcmods(p.tcmods, q)
		local frames = 0
		for _ in p.skinframes do
			frames += 1
		end
		table.insert(q, tostring(frames))
		table.insert(lines, table.concat(q, "\t"))
	end
	for k = 0, 3 do
		table.insert(lines, `TD\t{idx}\t{k}\t{deform((tex.deforms or {})[k + 1])}`)
	end
	return lines
end

return function(ctx: t.Ctx)
	local want: { string } = {}
	for line in string.gmatch(t.read("tests/vectors/shader.tsv"), "[^\n]+") do
		table.insert(want, line)
	end
	local cur = 1
	local function expect(got: string, what: string)
		local w = want[cur] or "<end of file>"
		if got == w then
			t.ok(ctx, true)
		else
			local a, b = string.split(got, "\t"), string.split(w, "\t")
			local col = 1
			while a[col] == b[col] do
				col += 1
			end
			t.ok(
				ctx,
				false,
				`line {cur} ({what}): column {col} got {a[col] or "<none>"}, want {b[col] or "<none>"}  [{w:sub(1, 120)}]`
			)
		end
		cur += 1
	end

	-- the fixture directory as the virtual file system
	local files: { string } = {}
	local known: { [string]: boolean } = {}
	for _, name in lfs.readDir(ROOT .. "scripts") do
		table.insert(files, "scripts/" .. name)
		known["scripts/" .. name] = true
	end
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
	local oldsink = console.sink
	console.sink = function(_line: string) end
	-- a dedicated server: what the C generator stubs (gl_rmain.c)
	local saved = {
		model_shared.R_SkinFrame_LoadMissing,
		model_shared.R_SkinFrame_LoadExternal,
		model_shared.R_GetCubemap,
		model_shared.loadmodel,
	}
	model_shared.R_SkinFrame_LoadMissing = function(): any
		return nil
	end
	model_shared.R_SkinFrame_LoadExternal = function(_n: string, _f: number, _c: boolean): any
		return nil
	end
	model_shared.R_GetCubemap = function(_n: string): any
		return nil
	end
	model_shared.loadmodel = { name = "tvmodel", brush = { skybox = "" } }

	local ok, err = pcall(function()
		while cur <= #want do
			local c = string.split(want[cur], "\t")
			local kind = c[1]
			if kind == "CV" then
				cvar.Cvar_Get(c[2], c[3], 0)
				cur += 1
			elseif kind == "CFG" then
				for k = 3, #c, 2 do
					cvar.Cvar_Get(c[k], c[k + 1], 0)
				end
				cur += 1
				local search = fs.FS_Search("scripts/*.shader", true, false) or {}
				for i, name in search do
					expect(`F\t{i - 1}\t{name}`, "FS_Search")
				end
				model_shared.Mod_FreeQ3Shaders()
				model_shared.Mod_LoadQ3Shaders()
				local all = model_shared.q3shaders()
				for _, s in all do
					for _, l in shaderlines(s) do
						expect(l, `config {c[2]} shader {s.name}`)
					end
				end
				expect(`SN\t{#all}`, "number of shaders")
			elseif kind == "TC" then
				cur += 1
				local idx = tonumber(c[2]) :: number
				local name: string? = if c[3] == "1" then nil else unescape(c[4])
				local tex: any = { surfaceflags = tonumber(c[5]) }
				model_shared.loadmodel.brush.skybox = ""
				local ret = model_shared.Mod_LoadTextureFromQ3Shader(
					tex,
					name,
					c[7] ~= "0",
					c[8] ~= "0",
					tonumber(c[6]) :: number
				)
				for _, l in texturelines(idx, tex, ret) do
					expect(l, `texture {c[4]}`)
				end
			elseif kind == "END" then
				t.ok(ctx, true, "reached the end of the vector file")
				cur += 1
			else
				expect("<unexpected>", "vector line kind " .. kind)
			end
		end
	end)
	console.sink = oldsink
	model_shared.R_SkinFrame_LoadMissing = saved[1]
	model_shared.R_SkinFrame_LoadExternal = saved[2]
	model_shared.R_GetCubemap = saved[3]
	model_shared.loadmodel = saved[4]
	fs.SetProvider(nil)
	model_shared.Mod_FreeQ3Shaders()
	cvar.reset()
	if not ok then
		error(err, 0)
	end
end
