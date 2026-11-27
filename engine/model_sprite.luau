--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

(DarkPlaces model_sprite.c, structs of spritegn.h)
]]
--[[
	Port of model_sprite.c @xonotic-v0.8.6 (task M4-ALIAS): Mod_SpriteInit, Mod_SpriteSetupTexture,
	Mod_Sprite_SharedSetup, Mod_IDSP_Load (Quake, Half-Life and sprite32 .spr) and Mod_IDS2_Load (Quake 2 .sp2),
	installed into model_shared when this module loads. Data layout as in engine/model_alias.luau:
	sprite.sprdata_frames, animscenes and data_textures are 1-based arrays (C element i at [i + 1]).
	Dedicated server: the C skips every texture call (cls.state == ca_dedicated) and so does this port; the client
	branch calls renderer hooks (R_SkinFrame_LoadExternal / LoadInternalBGRA, Image_Copy8bitBGRA) that log NOT YET
	PORTED once.
]]
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libc = require("./_port/libc")
local model_shared = require("./model_shared")

local model_sprite = {}

local R = f32.round
local Con_Printf = console.Con_Printf
local readi32, readf32, readu8 = buffer.readi32, buffer.readf32, buffer.readu8

-- spritegn.h
local SPRITE_VERSION = 1
local SPRITEHL_VERSION = 2
local SPRITE32_VERSION = 32
local SPRITE2_VERSION = 2
local SPR_VP_PARALLEL = 2
local SPRHL_OPAQUE = 0
local SPRHL_ADDITIVE = 1
local SPRHL_INDEXALPHA = 2
local SPRHL_ALPHATEST = 3
local SPR_SINGLE = 0
-- model_shared.h synctype_t
local ST_SYNC = 0
-- model_shared.h MATERIALFLAG_*, bspfile.h SUPERCONTENTS_*, r_textures.h TEXF_*
local MATERIALFLAG_ALPHA = 0x00000002
local MATERIALFLAG_ADD = 0x00000004
local MATERIALFLAG_FULLBRIGHT = 0x00000020
local MATERIALFLAG_WALL = 0x00000040
local MATERIALFLAG_BLENDED = 0x00001000
local MATERIALFLAG_NOSHADOW = 0x00004000
local SUPERCONTENTS_SOLID = 0x00000001
local SUPERCONTENTS_OPAQUE = 0x00001000
local TEXF_ALPHA = 0x00000001
local TEXF_MIPMAP = 0x00000002
local TEXF_CLAMP = 0x00000020
local TEXF_PICMIP = 0x00000100
local TEXF_COMPRESS = 0x00000200
local TEXF_ISSPRITE = 0x00008000
local OFFSETMAPPING_OFF = 0
local TRANSPARENTSORT_DISTANCE = 1
local MAX_QPATH = 128

-- Host_Error (host.c) aborts the load; here it raises a Luau error with the same text.
local function Host_Error(fmt: string, ...: any)
	error("Host_Error: " .. string.format(fmt, ...), 0)
end

local function cvi(name: string): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else 0
end

-- Renderer functions this file calls (gl_rmain.c, image.c); C reaches them only when not dedicated.
local renderer_notported: { [string]: boolean } = {}
local function renderer_missing(what: string)
	if not renderer_notported[what] then
		renderer_notported[what] = true
		print("NOT YET PORTED: " .. what)
	end
end
model_sprite.R_SkinFrame_LoadInternalBGRA = function(
	_name: string,
	_textureflags: number,
	_pixels: buffer,
	_width: number,
	_height: number,
	_sRGB: boolean
): any
	renderer_missing("R_SkinFrame_LoadInternalBGRA (gl_rmain.c)")
	return nil
end
model_sprite.Image_Copy8bitBGRA = function(_in: buffer, _inofs: number, _out: buffer, _pixels: number, _pal: any)
	renderer_missing("Image_Copy8bitBGRA (image.c)")
end

-- the C string at byte o of b (up to the first NUL, the end of the buffer, or max bytes)
local function cstr(b: buffer, o: number, max: number?): string
	local n = buffer.len(b)
	if o >= n then
		return ""
	end
	local e = o
	local lim = if max then math.min(n, o + max) else n
	while e < lim and readu8(b, e) ~= 0 do
		e += 1
	end
	return buffer.readstring(b, o, e - o)
end

-- port: model_sprite.c Mod_SpriteInit L45-58 @xonotic-v0.8.6
function model_sprite.Mod_SpriteInit()
	-- Cvar_RegisterVariable(&r_mipsprites) ... (&r_track_sprites_scaleh): registered by engine/host.luau from
	-- engine/_port/sv_init_defs.luau, like every cvar of the dedicated init path.
end

-- port: model_sprite.c Mod_SpriteSetupTexture L60-87 @xonotic-v0.8.6
local function Mod_SpriteSetupTexture(texture: any, skinframe: any, fullbright: boolean, additive: boolean)
	if not skinframe then
		skinframe = model_shared.R_SkinFrame_LoadMissing()
	end
	texture.offsetmapping = OFFSETMAPPING_OFF
	texture.offsetscale = 1
	texture.offsetbias = 0
	texture.specularscalemod = 1
	texture.specularpowermod = 1
	texture.basematerialflags = MATERIALFLAG_WALL
	texture.basealpha = 1.0
	if fullbright then
		texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_FULLBRIGHT)
	end
	if additive then
		texture.basematerialflags =
			bit32.bor(texture.basematerialflags, MATERIALFLAG_ADD + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW)
	elseif skinframe.hasalpha then
		texture.basematerialflags =
			bit32.bor(texture.basematerialflags, MATERIALFLAG_ALPHA + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW)
	end
	texture.currentmaterialflags = texture.basematerialflags
	texture.shaderpasses = texture.shaderpasses or {}
	texture.shaderpasses[1] = model_shared.Mod_CreateShaderPass(skinframe)
	texture.materialshaderpass = texture.shaderpasses[1]
	texture.currentskinframe = skinframe
	texture.surfaceflags = 0
	texture.supercontents = SUPERCONTENTS_SOLID
	if bit32.band(texture.basematerialflags, MATERIALFLAG_BLENDED) == 0 then
		texture.supercontents = bit32.bor(texture.supercontents, SUPERCONTENTS_OPAQUE)
	end
	texture.transparentsort = TRANSPARENTSORT_DISTANCE
	-- WHEN ADDING DEFAULTS HERE, REMEMBER TO PUT DEFAULTS IN ALL LOADERS
	-- JUST GREP FOR "specularscalemod = 1".
end

-- the zeroed arrays of a sprite model (Mem_Alloc)
local function newscenes(n: number): { any }
	local t = table.create(n)
	for i = 1, n do
		t[i] = { name = "", firstframe = 0, framecount = 0, loop = false, framerate = 0 }
	end
	return t
end
local function newframes(n: number): { any }
	local t = table.create(n)
	for i = 1, n do
		t[i] = { left = 0, right = 0, up = 0, down = 0 }
	end
	return t
end
local function newtextures(n: number): { any }
	local t = table.create(n)
	for i = 1, n do
		t[i] = { index = i - 1 }
	end
	return t
end

-- the sprite's fullbright flag: false when the name has a '!' ("LordHavoc: hack to allow sprites to be
-- non-fullbright")
local function spritefullbright(name: string): boolean
	local fullbright = true
	for i = 1, math.min(#name, MAX_QPATH) do
		if string.sub(name, i, i) == "!" then
			fullbright = false
		end
	end
	return fullbright
end

-- port: model_sprite.c Mod_Sprite_SharedSetup L91-264 @xonotic-v0.8.6
-- (datapointer: byte offset into the file b; palette: 1024 bytes of BGRA, nil = NULL)
local function Mod_Sprite_SharedSetup(
	b: buffer,
	datapointer: number,
	version: number,
	palette: buffer?,
	additive: boolean
)
	local loadmodel = model_shared.loadmodel
	local groupframes, realframes, x, y, width, height
	local fullbright
	local modelradius, interval
	local name, fogname
	local texflags = bit32.bor(
		if cvi("r_mipsprites") ~= 0 then TEXF_MIPMAP else 0,
		if cvi("gl_texturecompression") ~= 0 and cvi("gl_texturecompression_sprites") ~= 0 then TEXF_COMPRESS else 0,
		TEXF_ISSPRITE,
		TEXF_PICMIP,
		TEXF_ALPHA,
		TEXF_CLAMP
	)
	modelradius = 0

	if loadmodel.numframes < 1 then
		Host_Error("Mod_Sprite_SharedSetup: Invalid # of frames: %d", loadmodel.numframes)
	end

	-- LordHavoc: hack to allow sprites to be non-fullbright
	fullbright = spritefullbright(loadmodel.name)

	--
	-- load the frames
	--
	local startframes = datapointer
	realframes = 0
	for _ = 0, loadmodel.numframes - 1 do
		local pinframetype = datapointer
		datapointer += 4 -- sizeof(dspriteframetype_t)

		if readi32(b, pinframetype) == SPR_SINGLE then
			groupframes = 1
		else
			local pingroup = datapointer
			datapointer += 4 -- sizeof(dspritegroup_t)

			groupframes = readi32(b, pingroup)

			datapointer += 4 * groupframes -- sizeof(dspriteinterval_t) * groupframes
		end

		for _j = 0, groupframes - 1 do
			local pinframe = datapointer
			if version == SPRITE32_VERSION then
				datapointer += 16 + readi32(b, pinframe + 8) * readi32(b, pinframe + 12) * 4
			else --if (version == SPRITE_VERSION || version == SPRITEHL_VERSION)
				datapointer += 16 + readi32(b, pinframe + 8) * readi32(b, pinframe + 12)
			end
		end
		realframes += groupframes
	end

	loadmodel.animscenes = newscenes(loadmodel.numframes)
	loadmodel.sprite.sprdata_frames = newframes(realframes)
	loadmodel.num_textures = realframes
	loadmodel.num_texturesperskin = 1
	loadmodel.data_textures = newtextures(loadmodel.num_textures)

	datapointer = startframes
	realframes = 0
	for i = 0, loadmodel.numframes - 1 do
		local pinframetype = datapointer
		datapointer += 4 -- sizeof(dspriteframetype_t)

		if readi32(b, pinframetype) == SPR_SINGLE then
			groupframes = 1
			interval = R(0.1)
		else
			local pingroup = datapointer
			datapointer += 4 -- sizeof(dspritegroup_t)

			groupframes = readi32(b, pingroup)

			local pinintervals = datapointer
			datapointer += 4 * groupframes -- sizeof(dspriteinterval_t) * groupframes

			interval = readf32(b, pinintervals)
			if interval < R(0.01) then
				Host_Error("Mod_Sprite_SharedSetup: invalid interval")
			end
		end

		local sc = loadmodel.animscenes[i + 1]
		sc.name = string.sub(string.format("frame %d", i), 1, 31)
		sc.firstframe = realframes
		sc.framecount = groupframes
		sc.framerate = R(1.0 / interval)
		sc.loop = true

		for j = 0, groupframes - 1 do
			local pinframe = datapointer
			datapointer += 16 -- sizeof(dspriteframe_t)

			local origin0 = readi32(b, pinframe)
			local origin1 = readi32(b, pinframe + 4)
			width = readi32(b, pinframe + 8)
			height = readi32(b, pinframe + 12)

			local fr = loadmodel.sprite.sprdata_frames[realframes + 1]
			-- (mspriteframe_t left / right / up / down are floats: the int sums are rounded when stored)
			fr.left = R(origin0)
			fr.right = R(origin0 + width)
			fr.up = R(origin1)
			fr.down = R(origin1 - height)

			local lsq, rsq = R(fr.left * fr.left), R(fr.right * fr.right)
			x = libc.toint(if lsq > rsq then lsq else rsq)
			local usq, dsq = R(fr.up * fr.up), R(fr.down * fr.down)
			y = libc.toint(if usq > dsq then usq else dsq)
			if modelradius < R(x + y) then -- (float < int: the int is converted to float)
				modelradius = R(x + y)
			end

			if not cvar.cls_state_dedicated then
				local skinframe = nil
				-- note: Nehahra's null.spr has width == 0 and height == 0
				if width > 0 and height > 0 then
					if groupframes > 1 then
						name = string.sub(string.format("%s_%d_%d", loadmodel.name, i, j), 1, MAX_QPATH - 1)
						fogname = string.sub(string.format("%s_%d_%dfog", loadmodel.name, i, j), 1, MAX_QPATH - 1)
					else
						name = string.sub(string.format("%s_%d", loadmodel.name, i), 1, MAX_QPATH - 1)
						fogname = string.sub(string.format("%s_%dfog", loadmodel.name, i), 1, MAX_QPATH - 1)
					end
					local _ = fogname
					skinframe = model_shared.R_SkinFrame_LoadExternal(name, bit32.bor(texflags, TEXF_COMPRESS), false)
					if not skinframe then
						local pixels = buffer.create(width * height * 4)
						if version == SPRITE32_VERSION then
							for p = 0, width * height - 1 do
								buffer.writeu8(pixels, p * 4 + 2, readu8(b, datapointer + p * 4 + 0))
								buffer.writeu8(pixels, p * 4 + 1, readu8(b, datapointer + p * 4 + 1))
								buffer.writeu8(pixels, p * 4 + 0, readu8(b, datapointer + p * 4 + 2))
								buffer.writeu8(pixels, p * 4 + 3, readu8(b, datapointer + p * 4 + 3))
							end
						else --if (version == SPRITEHL_VERSION || version == SPRITE_VERSION)
							model_sprite.Image_Copy8bitBGRA(
								b,
								datapointer,
								pixels,
								width * height,
								palette or "palette_bgra_transparent"
							)
						end
						skinframe =
							model_sprite.R_SkinFrame_LoadInternalBGRA(name, texflags, pixels, width, height, false)
						-- texflags |= TEXF_COMPRESS;
						-- Mem_Free(pixels);
					end
				end
				if skinframe == nil then
					skinframe = model_shared.R_SkinFrame_LoadMissing()
				end
				Mod_SpriteSetupTexture(loadmodel.data_textures[realframes + 1], skinframe, fullbright, additive)
			end

			if version == SPRITE32_VERSION then
				datapointer += width * height * 4
			else --if (version == SPRITE_VERSION || version == SPRITEHL_VERSION)
				datapointer += width * height
			end
			realframes += 1
		end
	end

	modelradius = R(math.sqrt(modelradius))
	loadmodel.normalmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.yawmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.rotatedmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.normalmaxs = { modelradius, modelradius, modelradius }
	loadmodel.yawmaxs = { modelradius, modelradius, modelradius }
	loadmodel.rotatedmaxs = { modelradius, modelradius, modelradius }
	loadmodel.radius = modelradius
	loadmodel.radius2 = R(modelradius * modelradius)
end

-- the renderer entry points of a sprite model (C function pointers; names here, no renderer yet)
local function setspritedraw(loadmodel: any)
	loadmodel.DrawSky = nil
	loadmodel.Draw = "R_Model_Sprite_Draw"
	loadmodel.DrawDepth = nil
	loadmodel.CompileShadowVolume = nil
	loadmodel.DrawShadowVolume = nil
	loadmodel.DrawLight = nil
	loadmodel.DrawAddWaterPlanes = nil
end

-- port: model_sprite.c Mod_IDSP_Load L266-378 @xonotic-v0.8.6
function model_sprite.Mod_IDSP_Load(_mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	local version
	local datapointer = 0

	loadmodel.modeldatatypestring = "SPR1"

	loadmodel.type = "mod_sprite"
	loadmodel.sprite = { sprnum_type = 0, sprdata_frames = {} }
	loadmodel.surfmesh = { num_vertices = 0, num_triangles = 0, isanimated = false }

	setspritedraw(loadmodel)

	version = readi32(b, 4)
	if version == SPRITE_VERSION or version == SPRITE32_VERSION then
		local pinqsprite = datapointer
		datapointer += 36 -- sizeof(dsprite_t)

		loadmodel.numframes = readi32(b, pinqsprite + 24)
		loadmodel.sprite.sprnum_type = readi32(b, pinqsprite + 8)
		loadmodel.synctype = readi32(b, pinqsprite + 32)

		Mod_Sprite_SharedSetup(b, datapointer, readi32(b, pinqsprite + 4), nil, false)
	elseif version == SPRITEHL_VERSION then
		local rendermode
		local palette = buffer.create(256 * 4)

		local pinhlsprite = datapointer
		datapointer += 40 -- sizeof(dspritehl_t)

		loadmodel.numframes = readi32(b, pinhlsprite + 28)
		loadmodel.sprite.sprnum_type = readi32(b, pinhlsprite + 8)
		loadmodel.synctype = readi32(b, pinhlsprite + 36)
		rendermode = readi32(b, pinhlsprite + 12)

		local in_ = datapointer
		datapointer += 2
		local i = readu8(b, in_) + readu8(b, in_ + 1) * 256
		if i ~= 256 then
			Host_Error("Mod_IDSP_Load: unexpected number of palette colors %i (should be 256)", i)
		end
		in_ = datapointer
		datapointer += 768
		local w = buffer.writeu8
		if rendermode == SPRHL_OPAQUE or rendermode == SPRHL_ADDITIVE then
			for c = 0, 255 do
				w(palette, c * 4 + 2, readu8(b, in_ + c * 3 + 0))
				w(palette, c * 4 + 1, readu8(b, in_ + c * 3 + 1))
				w(palette, c * 4 + 0, readu8(b, in_ + c * 3 + 2))
				w(palette, c * 4 + 3, 255)
			end
			-- SPRHL_ADDITIVE: also passes additive == true to Mod_Sprite_SharedSetup
		elseif rendermode == SPRHL_INDEXALPHA then
			for c = 0, 255 do
				w(palette, c * 4 + 2, readu8(b, in_ + 765))
				w(palette, c * 4 + 1, readu8(b, in_ + 766))
				w(palette, c * 4 + 0, readu8(b, in_ + 767))
				w(palette, c * 4 + 3, c)
				in_ += 3
			end
		elseif rendermode == SPRHL_ALPHATEST then
			for c = 0, 255 do
				w(palette, c * 4 + 2, readu8(b, in_ + c * 3 + 0))
				w(palette, c * 4 + 1, readu8(b, in_ + c * 3 + 1))
				w(palette, c * 4 + 0, readu8(b, in_ + c * 3 + 2))
				w(palette, c * 4 + 3, 255)
			end
			w(palette, 255 * 4 + 0, 0)
			w(palette, 255 * 4 + 1, 0)
			w(palette, 255 * 4 + 2, 0)
			w(palette, 255 * 4 + 3, 0)
			-- should this use alpha test or alpha blend?  (currently blend)
		else
			-- (C prints i, the palette size, here)
			Host_Error("Mod_IDSP_Load: unknown texFormat (%i, should be 0, 1, 2, or 3)", i)
			return
		end

		Mod_Sprite_SharedSetup(b, datapointer, readi32(b, pinhlsprite + 4), palette, rendermode == SPRHL_ADDITIVE)
	else
		Host_Error(
			"Mod_IDSP_Load: %s has wrong version number (%i). Only %i (quake), %i (HalfLife), and %i (sprite32) supported",
			loadmodel.name,
			version,
			SPRITE_VERSION,
			SPRITEHL_VERSION,
			SPRITE32_VERSION
		)
	end

	-- TODO: Note that isanimated only means whether vertices change due to
	-- the animation. This may happen due to sprframe parameters changing.
	-- Mere texture chanegs OTOH shouldn't require isanimated to be 1.
	loadmodel.surfmesh.isanimated = loadmodel.numframes > 1
		or (loadmodel.animscenes ~= nil and loadmodel.animscenes[1].framecount > 1)
end

-- port: model_sprite.c Mod_IDS2_Load L381-489 @xonotic-v0.8.6
function model_sprite.Mod_IDS2_Load(_mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	local version
	local fullbright
	local modelradius
	local texflags = bit32.bor(
		if cvi("r_mipsprites") ~= 0 then TEXF_MIPMAP else 0,
		TEXF_ISSPRITE,
		TEXF_PICMIP,
		TEXF_COMPRESS,
		TEXF_ALPHA,
		TEXF_CLAMP
	)

	loadmodel.modeldatatypestring = "SPR2"

	loadmodel.type = "mod_sprite"
	loadmodel.sprite = { sprnum_type = 0, sprdata_frames = {} }
	loadmodel.surfmesh = { num_vertices = 0, num_triangles = 0, isanimated = false }

	setspritedraw(loadmodel)

	local pinqsprite = 0

	version = readi32(b, pinqsprite + 4)
	if version ~= SPRITE2_VERSION then
		Host_Error("Mod_IDS2_Load: %s has wrong version number (%i should be 2 (quake 2)", loadmodel.name, version)
	end

	loadmodel.numframes = readi32(b, pinqsprite + 8)
	if loadmodel.numframes < 1 then
		Host_Error("Mod_IDS2_Load: Invalid # of frames: %d", loadmodel.numframes)
	end
	loadmodel.sprite.sprnum_type = SPR_VP_PARALLEL
	loadmodel.synctype = ST_SYNC

	-- LordHavoc: hack to allow sprites to be non-fullbright
	fullbright = spritefullbright(loadmodel.name)

	loadmodel.animscenes = newscenes(loadmodel.numframes)
	loadmodel.sprite.sprdata_frames = newframes(loadmodel.numframes)
	loadmodel.num_textures = loadmodel.numframes
	loadmodel.num_texturesperskin = 1
	loadmodel.data_textures = newtextures(loadmodel.num_textures)

	modelradius = 0
	for i = 0, loadmodel.numframes - 1 do
		local sc = loadmodel.animscenes[i + 1]
		sc.name = string.sub(string.format("frame %d", i), 1, 31)
		sc.firstframe = i
		sc.framecount = 1
		sc.framerate = 10
		sc.loop = true

		local pinframe = pinqsprite + 12 + i * 80 -- &pinqsprite->frames[i]

		local origin0 = readi32(b, pinframe + 8)
		local origin1 = readi32(b, pinframe + 12)
		local width = readi32(b, pinframe)
		local height = readi32(b, pinframe + 4)

		local sprframe = loadmodel.sprite.sprdata_frames[i + 1]

		-- note that sp2 origin[0] is positive, where as it is negative in
		-- spr/spr32/hlspr
		sprframe.left = R(-origin0)
		sprframe.right = R(-origin0 + width)
		sprframe.up = R(origin1)
		sprframe.down = R(origin1 - height)

		local lsq, rsq = R(sprframe.left * sprframe.left), R(sprframe.right * sprframe.right)
		local x = libc.toint(if lsq > rsq then lsq else rsq)
		local usq, dsq = R(sprframe.up * sprframe.up), R(sprframe.down * sprframe.down)
		local y = libc.toint(if usq > dsq then usq else dsq)
		if modelradius < R(x + y) then -- (float < int: the int is converted to float)
			modelradius = R(x + y)
		end
	end

	if not cvar.cls_state_dedicated then
		for i = 0, loadmodel.numframes - 1 do
			local pinframe = pinqsprite + 12 + i * 80
			local pname = cstr(b, pinframe + 16)
			local skinframe = model_shared.R_SkinFrame_LoadExternal(pname, texflags, false)
			if not skinframe then
				Con_Printf("Mod_IDS2_Load: failed to load %s", pname)
				skinframe = model_shared.R_SkinFrame_LoadMissing()
			end
			Mod_SpriteSetupTexture(loadmodel.data_textures[i + 1], skinframe, fullbright, false)
		end
	end

	modelradius = R(math.sqrt(modelradius))
	loadmodel.normalmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.yawmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.rotatedmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.normalmaxs = { modelradius, modelradius, modelradius }
	loadmodel.yawmaxs = { modelradius, modelradius, modelradius }
	loadmodel.rotatedmaxs = { modelradius, modelradius, modelradius }
	loadmodel.radius = modelradius
	loadmodel.radius2 = R(modelradius * modelradius)

	-- TODO: Note that isanimated only means whether vertices change due to
	-- the animation. This may happen due to sprframe parameters changing.
	-- Mere texture chanegs OTOH shouldn't require isanimated to be 1.
	loadmodel.surfmesh.isanimated = loadmodel.numframes > 1
		or (loadmodel.animscenes ~= nil and loadmodel.animscenes[1].framecount > 1)
end

model_shared.Mod_SpriteInit = model_sprite.Mod_SpriteInit
model_shared.Mod_IDSP_Load = model_sprite.Mod_IDSP_Load
model_shared.Mod_IDS2_Load = model_sprite.Mod_IDS2_Load

return model_sprite
