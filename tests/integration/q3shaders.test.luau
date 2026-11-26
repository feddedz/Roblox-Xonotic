--!strict
-- M3-BSPLOAD: Mod_LoadQ3Shaders (engine/model_shared.luau) on the release's scripts/*.shader, cross-checked
-- against the independent parser of tools/shaders/parse.py (assets/data/shaders.json: raw directive lists):
-- the same shaders exist, with the same number of layers, the same surfaceparm bits and the same texture names
-- per layer. Needs game data.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local serde = require("@lune/serde")
local provider = require("../_lib/vfs_provider")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local model_brush = require("../../engine/model_brush")
local model_shared = require("../../engine/model_shared")

return function(ctx: t.Ctx)
	local p = provider("high")
	if not p then
		t.skip(ctx, "needs work/vfs-high (tools/pk3/manifest.py --build high --extract)")
		return
	end
	local ref = serde.decode("json", t.read("assets/data/shaders.json"))
	fs.SetProvider(p)
	cvar.reset()
	local oldsink = console.sink
	console.sink = function(_line: string) end
	model_shared.Mod_FreeQ3Shaders()
	model_shared.Mod_LoadQ3Shaders()
	console.sink = oldsink

	local PARM = model_shared.Q3SURFACEPARM
	local all = model_shared.q3shaders()
	local seen: { [string]: boolean } = {}
	local unique = 0
	local badlayers, badparms, badnames, missing = 0, 0, 0, 0
	local first = ""
	local function note(what: string)
		if first == "" then
			first = what
		end
	end
	for _, s in ref.shaders do
		local name = string.sub(s.name, 1, 63)
		local key = string.lower(name)
		if seen[key] then
			continue -- a redeclaration: the engine keeps the first one
		end
		seen[key] = true
		unique += 1
		local mine = model_shared.Mod_LookupQ3Shader(name)
		if not mine then
			missing += 1
			note("missing " .. name)
			continue
		end
		if mine.numlayers ~= math.min(#s.layers, model_shared.Q3SHADER_MAXLAYERS) then
			badlayers += 1
			note(`{name}: {mine.numlayers} layers, reference {#s.layers}`)
		end
		local parms = 0
		for _, d in s.directives do
			local k = string.lower(d[1])
			if k == "surfaceparm" and d[2] then
				parms = bit32.bor(parms, PARM[string.lower(d[2])] or 0)
			elseif (k == "sky" or k == "skyparms") and d[2] then
				parms = bit32.bor(parms, PARM.sky)
			elseif k == "nomipmaps" then
				parms = bit32.bor(parms, PARM.nomipmaps)
			end
		end
		if parms ~= mine.surfaceparms then
			badparms += 1
			note(string.format("%s: surfaceparms %08x, reference %08x", name, mine.surfaceparms, parms))
		end
		for i = 1, math.min(#s.layers, mine.numlayers) do
			local want: { string }? = nil
			for _, d in s.layers[i] do
				local k = string.lower(d[1])
				if (k == "map" or k == "clampmap") and d[2] then
					want = { string.sub(d[2], 1, 63) }
				elseif (k == "animmap" or k == "animclampmap") and d[3] then
					want = {}
					for j = 3, math.min(#d, 66) do
						table.insert(want, string.sub(d[j], 1, 63))
					end
				end
			end
			local got = mine.layers[i].texturename
			if table.concat(want or {}, "|") ~= table.concat(got or {}, "|") then
				badnames += 1
				note(`{name} layer {i}: {table.concat(got or {}, "|")}, reference {table.concat(want or {}, "|")}`)
			end
		end
	end
	t.eq(ctx, #all, unique, "number of shaders")
	t.eq(ctx, missing, 0, "every reference shader is found " .. first)
	t.eq(ctx, badlayers, 0, "layer counts " .. first)
	t.eq(ctx, badparms, 0, "surfaceparm bits " .. first)
	t.eq(ctx, badnames, 0, "layer texture names " .. first)
	-- shaders the collision code depends on
	local function parms(name: string): number
		local s = model_shared.Mod_LookupQ3Shader(name)
		return if s then s.surfaceparms else -1
	end
	t.eq(ctx, parms("textures/common/caulk"), PARM.nodraw + PARM.nolightmap + PARM.nomarks, "common/caulk")
	t.ok(ctx, bit32.band(parms("textures/common/clip"), PARM.playerclip) ~= 0, "common/clip is playerclip")
	t.ok(ctx, bit32.band(parms("textures/common/weapclip"), PARM.nodraw) ~= 0, "common/weapclip is nodraw")
	t.ok(ctx, model_shared.Mod_LookupQ3Shader("TEXTURES/COMMON/CAULK") ~= nil, "lookup ignores case")
	t.ok(ctx, model_shared.Mod_LookupQ3Shader("textures/no/such/shader") == nil, "unknown shader")

	-- Mod_LoadTextureFromQ3Shader through the map loader: material flags of a stock map's textures
	console.sink = function(_line: string) end
	local mod = model_brush.newmodel("maps/stormkeep.bsp")
	model_brush.Mod_IBSP_Load(mod, lfs.readFile("work/vfs-high/maps/stormkeep.bsp"))
	console.sink = oldsink
	local SKY, NODRAW, WALL =
		model_shared.MATERIALFLAG_SKY, model_shared.MATERIALFLAG_NODRAW, model_shared.MATERIALFLAG_WALL
	local nsky, nnodraw, nwall, nshader, wrong = 0, 0, 0, 0, 0
	local firstwrong = ""
	for _, tex in mod.data_textures do
		local s = model_shared.Mod_LookupQ3Shader(tex.name)
		local flags = tex.basematerialflags
		local kinds = (if bit32.band(flags, SKY) ~= 0 then 1 else 0)
			+ (if bit32.band(flags, NODRAW) ~= 0 then 1 else 0)
			+ (if bit32.band(flags, WALL) ~= 0 then 1 else 0)
		if s then
			nshader += 1
			local want = if bit32.band(s.surfaceparms, PARM.sky) ~= 0
				then SKY
				elseif bit32.band(tex.surfaceflags, 128) ~= 0 or s.numlayers == 0 then NODRAW
				else WALL
			if bit32.band(flags, want) == 0 or kinds ~= 1 then
				wrong += 1
				firstwrong = firstwrong ~= "" and firstwrong or `{tex.name}: flags {flags}`
			end
		elseif kinds ~= 1 and tex.name ~= "noshader" and tex.name ~= "" then
			wrong += 1
			firstwrong = firstwrong ~= "" and firstwrong or `{tex.name} (no shader): flags {flags}`
		end
		nsky += if bit32.band(flags, SKY) ~= 0 then 1 else 0
		nnodraw += if bit32.band(flags, NODRAW) ~= 0 then 1 else 0
		nwall += if bit32.band(flags, WALL) ~= 0 then 1 else 0
		t.ok(ctx, tex.materialshaderpass ~= nil and tex.currentframe == tex, `{tex.name}: has a material pass`)
	end
	t.eq(ctx, wrong, 0, "stormkeep: sky / nodraw / wall material flags " .. firstwrong)
	t.ok(
		ctx,
		nsky >= 1 and nnodraw >= 1 and nwall >= 10,
		`stormkeep: {nsky} sky, {nnodraw} nodraw, {nwall} wall textures`
	)
	t.ok(ctx, nshader > #mod.data_textures / 2, `stormkeep: {nshader} of {#mod.data_textures} textures have a shader`)
	t.ok(ctx, mod.DrawSky == true, "stormkeep: the world draws a sky")
	t.ok(ctx, type(mod.brush.skybox) == "string" and string.sub(mod.brush.skybox, -1) == "_", "stormkeep: skybox name")
	print(
		`    q3shaders: {#all} shaders, {unique} in the reference; stormkeep: {#mod.data_textures} textures, {nshader} with a shader, skybox {mod.brush.skybox}`
	)
	fs.SetProvider(nil)
	model_shared.Mod_FreeQ3Shaders()
	cvar.reset()
end
