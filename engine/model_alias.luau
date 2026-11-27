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

(DarkPlaces model_alias.c / model_alias.h, with mod_skeletal_animatevertices_generic.c, the generic skeletal
vertex code model_alias.c includes; structs of model_alias.h, modelgen.h, model_zymotic.h, model_dpmodel.h,
model_iqm.h)
]]
--[[
	Port of model_alias.c @xonotic-v0.8.6 (task M4-ALIAS): the shared helpers (skeletal blends and transforms,
	vertex animation, tag matrices, base bone poses, bounding boxes, morph frame compilation, traces, skins) and
	the loaders Mod_IDP0_Load (mdl), Mod_IDP2_Load (md2), Mod_IDP3_Load (md3), Mod_ZYMOTICMODEL_Load,
	Mod_DARKPLACESMODEL_Load (dpm) and Mod_INTERQUAKEMODEL_Load (iqm). They are installed into model_shared
	(model_shared.Mod_IDP3_Load = ...) when this module loads; model_shared requires this module on first use.

	How the C data is held (as in engine/model_brush.luau):
	  * The file is a `buffer` (buffer.fromstring of the loaded string); LittleLong / LittleFloat / LittleShort are
	    buffer.readi32 / readf32 / readi16, BigLong / BigFloat read the 4 bytes byte-swapped.
	  * dp_model_t and its surfmesh are tables with the C field names. Arrays of structs (data_surfaces,
	    data_textures, animscenes, skinscenes, data_bones, data_tags) are 1-based Luau arrays: C element i at
	    [i + 1]; a C pointer into data_textures is (table, 0-based index); every texture and surface carries its
	    0-based `index` (C pointer arithmetic: the BIH stores texture - data_textures).
	  * Numeric arrays are buffers: float arrays f32, int arrays i32, data_poses7s i16, data_element3s and blends
	    u16, data_skeletalindex4ub / weight4ub u8. Structs of bytes stay packed as in C: data_blendweights is 8
	    bytes per blend (index[4], influence[4]), data_morphmd3vertex 8 bytes per vertex (short origin[3],
	    pitch, yaw), data_morphmdlvertex 4 (v[3], lightnormalindex), data_morphtexvecvertex 6 (svec[3], tvec[3]).
	  * frameblend_t[MAX_FRAMEBLENDS] is a Luau array of { subframe, lerp }, C element i at [i + 1]; a skeleton_t
	    is { model, relativetransforms = { matrix4x4_t } } (C element i at [i + 1]) or nil.
	  * Renderer function pointers (Draw, DrawDepth, ...) are the C function names as strings: there is no
	    renderer yet; Trace* / PointSuperContents / AnimateVertices are the Luau functions.
	Every float operation is rounded like C float arithmetic (D-004); double expressions are rounded once where C
	stores them in a float.

	The skeletal vertex code: DarkPlaces on x86 has an SSE version (mod_skeletal_animatevertices_sse.c) and uses
	it when the CPU has SSE (Mod_AliasInit, r_skeletal_use_sse 1), as the release build does. This port has the
	generic C version (Mod_Skeletal_AnimateVertices_Generic) only; Mod_AliasInit prints what the C prints when SSE
	is not available. Whether the SSE results differ: see tests/unit/model_alias_ref.test.luau.

	Dedicated server: the loaders run the branches C runs with cls.state == ca_dedicated (cvar.cls_state_dedicated),
	where R_SkinFrame_* return NULL and Mod_BuildAliasSkinFromSkinFrame returns at once. The client branches call
	renderer hooks that log NOT YET PORTED once (see "Renderer functions" below).
	NOT YET PORTED: Mod_PSKMODEL_Load (no .psk / .psa file in the release; logs once), the SSE vertex path.
]]
local bih = require("./bih")
local collision = require("./collision")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libc = require("./_port/libc")
local libm = require("./_port/libm")
local matrixlib = require("./matrixlib")
local model_brush = require("./model_brush")
local model_shared = require("./model_shared")

local model_alias = {}

local R = f32.round
local Con_Printf, Con_DPrintf = console.Con_Printf, console.Con_DPrintf
local readi32, readu32, readf32, readi16, readu16, readu8, readi8 =
	buffer.readi32, buffer.readu32, buffer.readf32, buffer.readi16, buffer.readu16, buffer.readu8, buffer.readi8
local writei32, writef32, writei16, writeu16, writeu8, writei8 =
	buffer.writei32, buffer.writef32, buffer.writei16, buffer.writeu16, buffer.writeu8, buffer.writei8
local toshort = matrixlib.toshort

type matrix4x4_t = matrixlib.matrix4x4_t

-- client.h L1340: MAX_FRAMEBLENDS (MAX_FRAMEGROUPBLENDS * 2), protocol.h MAX_FRAMEGROUPBLENDS 4
local MAX_FRAMEBLENDS = 8
model_alias.MAX_FRAMEBLENDS = MAX_FRAMEBLENDS

-- model_shared.h synctype_t (ST_SYNC = 0)
local ST_RAND = 1

-- model_shared.h MATERIALFLAG_* (the ones used here), model_brush.h MATERIALFLAGMASK_TRANSLUCENT,
-- bspfile.h SUPERCONTENTS_*, r_textures.h TEXF_*
local MATERIALFLAG_ALPHA = 0x00000002
local MATERIALFLAG_WALL = 0x00000040
local MATERIALFLAG_SKY = 0x00000080
local MATERIALFLAG_NODRAW = 0x00000200
local MATERIALFLAG_BLENDED = 0x00001000
local MATERIALFLAG_NOSHADOW = 0x00004000
local MATERIALFLAG_WATERSHADER = 0x00040000
local MATERIALFLAG_REFRACTION = 0x00080000
local MATERIALFLAG_REFLECTION = 0x00100000
local MATERIALFLAG_CAMERA = 0x02000000
local MATERIALFLAGMASK_TRANSLUCENT = 0x00000010
	+ 0x00000080
	+ 0x00000200
	+ 0x00000800
	+ 0x00001000
	+ 0x00040000
	+ 0x00080000
local SUPERCONTENTS_SOLID = 0x00000001
local SUPERCONTENTS_OPAQUE = 0x00001000
local TEXF_ALPHA = 0x00000001
local TEXF_MIPMAP = 0x00000002
local TEXF_PICMIP = 0x00000100
local TEXF_COMPRESS = 0x00000200
local OFFSETMAPPING_DEFAULT = 1
local TRANSPARENTSORT_DISTANCE = 1

-- modelgen.h, model_alias.h
local ALIAS_VERSION = 6
local ALIAS_SINGLE = 0
local ALIAS_SKIN_SINGLE = 0
local MD2ALIAS_VERSION = 8
local MD2_SKINNAME = 64
local MD3VERSION = 15
local ZYMSCENEFLAG_NOLOOP = 1
-- model_iqm.h
local IQM_POSITION, IQM_TEXCOORD, IQM_NORMAL, IQM_TANGENT = 0, 1, 2, 3
local IQM_BLENDINDEXES, IQM_BLENDWEIGHTS, IQM_COLOR = 4, 5, 6
local IQM_UBYTE, IQM_FLOAT = 1, 7
local IQM_LOOP = 1

-- Host_Error (host.c) aborts the load; here it raises a Luau error with the same text.
local function Host_Error(fmt: string, ...: any)
	error("Host_Error: " .. string.format(fmt, ...), 0)
end

local notported: { [string]: boolean } = {}
local function NOT_YET_PORTED(what: string)
	if not notported[what] then
		notported[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- cvars: C reads the registered cvar_t; one that is not registered reads 0 / "" (its static initializer only
-- sets the string). The dedicated init path registers them (engine/host.luau from engine/_port/sv_init_defs.luau);
-- r_smoothnormals_areaweighting is registered by the renderer only, so it reads 0 on a dedicated server.
local function cvi(name: string): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else 0
end
local function cvv(name: string): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.value else 0
end
local function cvs(name: string): string
	local v = cvar.Cvar_FindVar(name)
	return if v then v.string.str else ""
end

-- the C string at byte o of b (up to the first NUL, the end of the buffer, or max bytes: strlcpy into a
-- buffer of max + 1 bytes)
local function cstr(b: buffer, o: number, max: number?): string
	local n = buffer.len(b)
	local e = o
	local lim = if max then math.min(n, o + max) else n
	while e < lim and readu8(b, e) ~= 0 do
		e += 1
	end
	if o >= n then
		return ""
	end
	return buffer.readstring(b, o, e - o)
end

-- BigLong / BigFloat (common.h): the 4 bytes at o, big-endian
local swapbuf = buffer.create(4)
local function BigLong(b: buffer, o: number): number
	local v = bit32.byteswap(readu32(b, o))
	return if v >= 0x80000000 then v - 0x100000000 else v
end
local function BigULong(b: buffer, o: number): number
	return bit32.byteswap(readu32(b, o))
end
local function BigFloat(b: buffer, o: number): number
	buffer.writeu32(swapbuf, 0, bit32.byteswap(readu32(b, o)))
	return readf32(swapbuf, 0)
end

-- (unsigned char) / (signed char) of a float: gcc converts through a 32-bit cvttss2si (out of range and NaN
-- give 0x80000000), then keeps the low 8 bits
local function toint32(x: number): number
	if x ~= x or x >= 2147483648 or x < -2147483648 then
		return -2147483648
	end
	return if x < 0 then math.ceil(x) else math.floor(x)
end
local function uchar(x: number): number
	return toint32(x) % 256
end
local function schar(x: number): number
	local v = toint32(x) % 256
	return if v >= 128 then v - 256 else v
end
-- an int value wrapped to 32 bits (C int arithmetic on the release's two's complement machine)
local function int32(x: number): number
	x = x % 4294967296
	return if x >= 2147483648 then x - 4294967296 else x
end
-- C's % on ints: the sign of the dividend
local function cmod(a: number, b: number): number
	return a - b * (if a / b < 0 then math.ceil(a / b) else math.floor(a / b))
end

-- port support: a zeroed texture_t / msurface_t with its 0-based index in data_textures / data_surfaces
local function newtexture(index: number): any
	return { index = index }
end
-- memset(texture, 0, sizeof(*texture)) (the index is the place of the struct, not a field)
local function cleartexture(t: any)
	local index = t.index
	table.clear(t)
	t.index = index
end
local function newsurface(index: number): any
	return { index = index, num_firsttriangle = 0, num_triangles = 0, num_firstvertex = 0, num_vertices = 0 }
end
local function newscene(): any
	return { name = "", firstframe = 0, framecount = 0, loop = false, framerate = 0 }
end
local function newframeblend(): { { subframe: number, lerp: number } }
	local fb = table.create(MAX_FRAMEBLENDS)
	for i = 1, MAX_FRAMEBLENDS do
		fb[i] = { subframe = 0, lerp = 0 }
	end
	return fb
end
model_alias.newframeblend = newframeblend

-- Renderer functions this file calls (gl_rmain.c). On a dedicated server they return NULL (as C's do).
local renderer_notported: { [string]: boolean } = {}
local function renderer_missing(what: string)
	if not renderer_notported[what] then
		renderer_notported[what] = true
		print("NOT YET PORTED: " .. what .. " (gl_rmain.c)")
	end
end
-- gl_rmain.c R_SkinFrame_LoadExternal L3273-3292: returns NULL on a dedicated server
local function R_SkinFrame_LoadExternal(name: string, textureflags: number, complain: boolean): any
	if cvar.cls_state_dedicated then
		return nil
	end
	return model_shared.R_SkinFrame_LoadExternal(name, textureflags, complain)
end
-- gl_rmain.c R_SkinFrame_LoadInternalQuake L3565-3572: returns NULL on a dedicated server
local function R_SkinFrame_LoadInternalQuake(
	_name: string,
	_textureflags: number,
	_loadpantsandshirt: boolean,
	_loadglowtexture: boolean,
	_skindata: buffer,
	_skinofs: number,
	_width: number,
	_height: number
): any
	if cvar.cls_state_dedicated then
		return nil
	end
	renderer_missing("R_SkinFrame_LoadInternalQuake")
	return nil
end
model_alias.R_SkinFrame_LoadInternalQuake = R_SkinFrame_LoadInternalQuake

-- model_alias.c L42: float mod_md3_sin[320] (filled by Mod_AliasInit)
local mod_md3_sin = table.create(320, 0)
model_alias.mod_md3_sin = mod_md3_sin

-- mathlib.c L31-114: float m_bytenormals[NUMVERTEXNORMALS][3] (anorms.h; mathlib.luau has no copy yet)
local m_bytenormals: { { number } } = {}
do
	local t = {
		{ -0.525731, 0.000000, 0.850651 },
		{ -0.442863, 0.238856, 0.864188 },
		{ -0.295242, 0.000000, 0.955423 },
		{ -0.309017, 0.500000, 0.809017 },
		{ -0.162460, 0.262866, 0.951056 },
		{ 0.000000, 0.000000, 1.000000 },
		{ 0.000000, 0.850651, 0.525731 },
		{ -0.147621, 0.716567, 0.681718 },
		{ 0.147621, 0.716567, 0.681718 },
		{ 0.000000, 0.525731, 0.850651 },
		{ 0.309017, 0.500000, 0.809017 },
		{ 0.525731, 0.000000, 0.850651 },
		{ 0.295242, 0.000000, 0.955423 },
		{ 0.442863, 0.238856, 0.864188 },
		{ 0.162460, 0.262866, 0.951056 },
		{ -0.681718, 0.147621, 0.716567 },
		{ -0.809017, 0.309017, 0.500000 },
		{ -0.587785, 0.425325, 0.688191 },
		{ -0.850651, 0.525731, 0.000000 },
		{ -0.864188, 0.442863, 0.238856 },
		{ -0.716567, 0.681718, 0.147621 },
		{ -0.688191, 0.587785, 0.425325 },
		{ -0.500000, 0.809017, 0.309017 },
		{ -0.238856, 0.864188, 0.442863 },
		{ -0.425325, 0.688191, 0.587785 },
		{ -0.716567, 0.681718, -0.147621 },
		{ -0.500000, 0.809017, -0.309017 },
		{ -0.525731, 0.850651, 0.000000 },
		{ 0.000000, 0.850651, -0.525731 },
		{ -0.238856, 0.864188, -0.442863 },
		{ 0.000000, 0.955423, -0.295242 },
		{ -0.262866, 0.951056, -0.162460 },
		{ 0.000000, 1.000000, 0.000000 },
		{ 0.000000, 0.955423, 0.295242 },
		{ -0.262866, 0.951056, 0.162460 },
		{ 0.238856, 0.864188, 0.442863 },
		{ 0.262866, 0.951056, 0.162460 },
		{ 0.500000, 0.809017, 0.309017 },
		{ 0.238856, 0.864188, -0.442863 },
		{ 0.262866, 0.951056, -0.162460 },
		{ 0.500000, 0.809017, -0.309017 },
		{ 0.850651, 0.525731, 0.000000 },
		{ 0.716567, 0.681718, 0.147621 },
		{ 0.716567, 0.681718, -0.147621 },
		{ 0.525731, 0.850651, 0.000000 },
		{ 0.425325, 0.688191, 0.587785 },
		{ 0.864188, 0.442863, 0.238856 },
		{ 0.688191, 0.587785, 0.425325 },
		{ 0.809017, 0.309017, 0.500000 },
		{ 0.681718, 0.147621, 0.716567 },
		{ 0.587785, 0.425325, 0.688191 },
		{ 0.955423, 0.295242, 0.000000 },
		{ 1.000000, 0.000000, 0.000000 },
		{ 0.951056, 0.162460, 0.262866 },
		{ 0.850651, -0.525731, 0.000000 },
		{ 0.955423, -0.295242, 0.000000 },
		{ 0.864188, -0.442863, 0.238856 },
		{ 0.951056, -0.162460, 0.262866 },
		{ 0.809017, -0.309017, 0.500000 },
		{ 0.681718, -0.147621, 0.716567 },
		{ 0.850651, 0.000000, 0.525731 },
		{ 0.864188, 0.442863, -0.238856 },
		{ 0.809017, 0.309017, -0.500000 },
		{ 0.951056, 0.162460, -0.262866 },
		{ 0.525731, 0.000000, -0.850651 },
		{ 0.681718, 0.147621, -0.716567 },
		{ 0.681718, -0.147621, -0.716567 },
		{ 0.850651, 0.000000, -0.525731 },
		{ 0.809017, -0.309017, -0.500000 },
		{ 0.864188, -0.442863, -0.238856 },
		{ 0.951056, -0.162460, -0.262866 },
		{ 0.147621, 0.716567, -0.681718 },
		{ 0.309017, 0.500000, -0.809017 },
		{ 0.425325, 0.688191, -0.587785 },
		{ 0.442863, 0.238856, -0.864188 },
		{ 0.587785, 0.425325, -0.688191 },
		{ 0.688191, 0.587785, -0.425325 },
		{ -0.147621, 0.716567, -0.681718 },
		{ -0.309017, 0.500000, -0.809017 },
		{ 0.000000, 0.525731, -0.850651 },
		{ -0.525731, 0.000000, -0.850651 },
		{ -0.442863, 0.238856, -0.864188 },
		{ -0.295242, 0.000000, -0.955423 },
		{ -0.162460, 0.262866, -0.951056 },
		{ 0.000000, 0.000000, -1.000000 },
		{ 0.295242, 0.000000, -0.955423 },
		{ 0.162460, 0.262866, -0.951056 },
		{ -0.442863, -0.238856, -0.864188 },
		{ -0.309017, -0.500000, -0.809017 },
		{ -0.162460, -0.262866, -0.951056 },
		{ 0.000000, -0.850651, -0.525731 },
		{ -0.147621, -0.716567, -0.681718 },
		{ 0.147621, -0.716567, -0.681718 },
		{ 0.000000, -0.525731, -0.850651 },
		{ 0.309017, -0.500000, -0.809017 },
		{ 0.442863, -0.238856, -0.864188 },
		{ 0.162460, -0.262866, -0.951056 },
		{ 0.238856, -0.864188, -0.442863 },
		{ 0.500000, -0.809017, -0.309017 },
		{ 0.425325, -0.688191, -0.587785 },
		{ 0.716567, -0.681718, -0.147621 },
		{ 0.688191, -0.587785, -0.425325 },
		{ 0.587785, -0.425325, -0.688191 },
		{ 0.000000, -0.955423, -0.295242 },
		{ 0.000000, -1.000000, 0.000000 },
		{ 0.262866, -0.951056, -0.162460 },
		{ 0.000000, -0.850651, 0.525731 },
		{ 0.000000, -0.955423, 0.295242 },
		{ 0.238856, -0.864188, 0.442863 },
		{ 0.262866, -0.951056, 0.162460 },
		{ 0.500000, -0.809017, 0.309017 },
		{ 0.716567, -0.681718, 0.147621 },
		{ 0.525731, -0.850651, 0.000000 },
		{ -0.238856, -0.864188, -0.442863 },
		{ -0.500000, -0.809017, -0.309017 },
		{ -0.262866, -0.951056, -0.162460 },
		{ -0.850651, -0.525731, 0.000000 },
		{ -0.716567, -0.681718, -0.147621 },
		{ -0.716567, -0.681718, 0.147621 },
		{ -0.525731, -0.850651, 0.000000 },
		{ -0.500000, -0.809017, 0.309017 },
		{ -0.238856, -0.864188, 0.442863 },
		{ -0.262866, -0.951056, 0.162460 },
		{ -0.864188, -0.442863, 0.238856 },
		{ -0.809017, -0.309017, 0.500000 },
		{ -0.688191, -0.587785, 0.425325 },
		{ -0.681718, -0.147621, 0.716567 },
		{ -0.442863, -0.238856, 0.864188 },
		{ -0.587785, -0.425325, 0.688191 },
		{ -0.309017, -0.500000, 0.809017 },
		{ -0.147621, -0.716567, 0.681718 },
		{ -0.425325, -0.688191, 0.587785 },
		{ -0.162460, -0.262866, 0.951056 },
		{ 0.442863, -0.238856, 0.864188 },
		{ 0.162460, -0.262866, 0.951056 },
		{ 0.309017, -0.500000, 0.809017 },
		{ 0.147621, -0.716567, 0.681718 },
		{ 0.000000, -0.525731, 0.850651 },
		{ 0.425325, -0.688191, 0.587785 },
		{ 0.587785, -0.425325, 0.688191 },
		{ 0.688191, -0.587785, 0.425325 },
		{ -0.955423, 0.295242, 0.000000 },
		{ -0.951056, 0.162460, 0.262866 },
		{ -1.000000, 0.000000, 0.000000 },
		{ -0.850651, 0.000000, 0.525731 },
		{ -0.955423, -0.295242, 0.000000 },
		{ -0.951056, -0.162460, 0.262866 },
		{ -0.864188, 0.442863, -0.238856 },
		{ -0.951056, 0.162460, -0.262866 },
		{ -0.809017, 0.309017, -0.500000 },
		{ -0.864188, -0.442863, -0.238856 },
		{ -0.951056, -0.162460, -0.262866 },
		{ -0.809017, -0.309017, -0.500000 },
		{ -0.681718, 0.147621, -0.716567 },
		{ -0.681718, -0.147621, -0.716567 },
		{ -0.850651, 0.000000, -0.525731 },
		{ -0.688191, 0.587785, -0.425325 },
		{ -0.587785, 0.425325, -0.688191 },
		{ -0.425325, 0.688191, -0.587785 },
		{ -0.425325, -0.688191, -0.587785 },
		{ -0.587785, -0.425325, -0.688191 },
		{ -0.688191, -0.587785, -0.425325 },
	}
	for i, v in t do
		m_bytenormals[i] = { R(v[1]), R(v[2]), R(v[3]) }
	end
end

-- mathlib.c R_ConcatTransforms (on float[12] arrays: buffer + byte offset; out must not alias in1 / in2)
-- port: mathlib.c R_ConcatTransforms L807-821 @xonotic-v0.8.6
local function R_ConcatTransforms(a: buffer, ao: number, b: buffer, bo: number, o: buffer, oo: number)
	for r = 0, 2 do
		local a0 = readf32(a, ao + (r * 4) * 4)
		local a1 = readf32(a, ao + (r * 4 + 1) * 4)
		local a2 = readf32(a, ao + (r * 4 + 2) * 4)
		for c = 0, 3 do
			local v = R(
				R(R(a0 * readf32(b, bo + c * 4)) + R(a1 * readf32(b, bo + (4 + c) * 4)))
					+ R(a2 * readf32(b, bo + (8 + c) * 4))
			)
			if c == 3 then
				v = R(v + readf32(a, ao + (r * 4 + 3) * 4))
			end
			writef32(o, oo + (r * 4 + c) * 4, v)
		end
	end
end
model_alias.R_ConcatTransforms = R_ConcatTransforms

-- the matrix struct assignment *out = *in
local function mcopy(out: matrix4x4_t, in_: matrix4x4_t)
	matrixlib.Matrix4x4_Copy(out, in_)
end
local function mclone(in_: matrix4x4_t): matrix4x4_t
	local m = matrixlib.new()
	matrixlib.Matrix4x4_Copy(m, in_)
	return m
end

-- ---------------------------------------------------------------------------------------------------------

local Mod_Skeletal_AnimateVertices_maxbonepose = 0
local Mod_Skeletal_AnimateVertices_bonepose: buffer? = nil
-- port: model_alias.c Mod_Skeletal_FreeBuffers L46-52 @xonotic-v0.8.6
function model_alias.Mod_Skeletal_FreeBuffers()
	Mod_Skeletal_AnimateVertices_maxbonepose = 0
	Mod_Skeletal_AnimateVertices_bonepose = nil
end
-- port: model_alias.c Mod_Skeletal_AnimateVertices_AllocBuffers L53-63 @xonotic-v0.8.6
function model_alias.Mod_Skeletal_AnimateVertices_AllocBuffers(nbytes: number): buffer
	if Mod_Skeletal_AnimateVertices_maxbonepose < nbytes then
		Mod_Skeletal_AnimateVertices_bonepose = buffer.create(nbytes)
		Mod_Skeletal_AnimateVertices_maxbonepose = nbytes
	end
	return Mod_Skeletal_AnimateVertices_bonepose :: buffer
end

-- port: model_alias.c Mod_Skeletal_BuildTransforms L65-161 @xonotic-v0.8.6
-- (bonepose / boneposerelative: f32 buffer + byte offset; bonepose nil = NULL)
function model_alias.Mod_Skeletal_BuildTransforms(
	model: any,
	frameblend: any,
	skeleton: any,
	bonepose_: buffer?,
	bpo: number,
	boneposerelative: buffer,
	bro: number
)
	local m = buffer.create(48)
	local num_bones: number = model.num_bones
	local bones = model.data_bones
	local inv: buffer = model.data_baseboneposeinverse
	local bonepose: buffer
	if not bonepose_ then
		bonepose = model_alias.Mod_Skeletal_AnimateVertices_AllocBuffers(48 * num_bones)
		bpo = 0
	else
		bonepose = bonepose_
	end

	if skeleton and not skeleton.relativetransforms then
		skeleton = nil
	end

	-- interpolate matrices
	if skeleton then
		for i = 0, num_bones - 1 do
			matrixlib.Matrix4x4_ToArray12FloatD3D(skeleton.relativetransforms[i + 1], m, 0)
			local parent = bones[i + 1].parent
			if parent >= 0 then
				R_ConcatTransforms(bonepose, bpo + parent * 48, m, 0, bonepose, bpo + i * 48)
			else
				buffer.copy(bonepose, bpo + i * 48, m, 0, 48)
			end

			-- create a relative deformation matrix to describe displacement
			-- from the base mesh, which is used by the actual weighting
			R_ConcatTransforms(bonepose, bpo + i * 48, inv, i * 48, boneposerelative, bro + i * 48)
		end
	else
		local poses: buffer = model.data_poses7s
		local num_posescale: number = model.num_posescale
		local debugbone = cvi("r_skeletal_debugbone")
		local debugbonecomponent = cvi("r_skeletal_debugbonecomponent")
		local debugbonevalue = cvv("r_skeletal_debugbonevalue")
		local debugtranslatex = cvv("r_skeletal_debugtranslatex")
		local debugtranslatey = cvv("r_skeletal_debugtranslatey")
		local debugtranslatez = cvv("r_skeletal_debugtranslatez")
		for i = 0, num_bones - 1 do
			-- blend by transform each quaternion/translation into a dual-quaternion first, then blending
			local fp = 14 * (frameblend[1].subframe * num_bones + i)
			local firstlerp = frameblend[1].lerp
			local firsttx, firstty, firsttz = readi16(poses, fp), readi16(poses, fp + 2), readi16(poses, fp + 4)
			local rx = R(readi16(poses, fp + 6) * firstlerp)
			local ry = R(readi16(poses, fp + 8) * firstlerp)
			local rz = R(readi16(poses, fp + 10) * firstlerp)
			local rw = R(readi16(poses, fp + 12) * firstlerp)
			local dx = R(R(R(firsttx * rw) + R(firstty * rz)) - R(firsttz * ry))
			local dy = R(R(R(-firsttx * rz) + R(firstty * rw)) + R(firsttz * rx))
			local dz = R(R(R(firsttx * ry) - R(firstty * rx)) + R(firsttz * rw))
			local dw = R(R(R(-firsttx * rx) - R(firstty * ry)) - R(firsttz * rz))
			local scale, sx, sy, sz, sw
			local blends = 1
			while blends < MAX_FRAMEBLENDS and frameblend[blends + 1].lerp > 0 do
				local bp = 14 * (frameblend[blends + 1].subframe * num_bones + i)
				local blendlerp = frameblend[blends + 1].lerp
				local blendtx, blendty, blendtz = readi16(poses, bp), readi16(poses, bp + 2), readi16(poses, bp + 4)
				local qx, qy, qz, qw =
					readi16(poses, bp + 6), readi16(poses, bp + 8), readi16(poses, bp + 10), readi16(poses, bp + 12)
				if R(R(R(R(rx * qx) + R(ry * qy)) + R(rz * qz)) + R(rw * qw)) < 0 then
					blendlerp = -blendlerp
				end
				qx = R(qx * blendlerp)
				qy = R(qy * blendlerp)
				qz = R(qz * blendlerp)
				qw = R(qw * blendlerp)
				rx = R(rx + qx)
				ry = R(ry + qy)
				rz = R(rz + qz)
				rw = R(rw + qw)
				dx = R(dx + R(R(R(blendtx * qw) + R(blendty * qz)) - R(blendtz * qy)))
				dy = R(dy + R(R(R(-blendtx * qz) + R(blendty * qw)) + R(blendtz * qx)))
				dz = R(dz + R(R(R(blendtx * qy) - R(blendty * qx)) + R(blendtz * qw)))
				dw = R(dw + R(R(R(-blendtx * qx) - R(blendty * qy)) - R(blendtz * qz)))
				blends += 1
			end
			-- generate a matrix from the dual-quaternion, implicitly normalizing it in the process
			scale = R(1.0 / R(R(R(R(rx * rx) + R(ry * ry)) + R(rz * rz)) + R(rw * rw)))
			sx = R(rx * scale)
			sy = R(ry * scale)
			sz = R(rz * scale)
			sw = R(rw * scale)
			local mm = {
				R(R(R(R(sw * rw) + R(sx * rx)) - R(sy * ry)) - R(sz * rz)),
				R(2 * R(R(sx * ry) - R(sw * rz))),
				R(2 * R(R(sx * rz) + R(sw * ry))),
				R(num_posescale * R(R(R(R(dx * sw) - R(dy * sz)) + R(dz * sy)) - R(dw * sx))),
				R(2 * R(R(sx * ry) + R(sw * rz))),
				R(R(R(R(sw * rw) + R(sy * ry)) - R(sx * rx)) - R(sz * rz)),
				R(2 * R(R(sy * rz) - R(sw * rx))),
				R(num_posescale * R(R(R(R(dx * sz) + R(dy * sw)) - R(dz * sx)) - R(dw * sy))),
				R(2 * R(R(sx * rz) - R(sw * ry))),
				R(2 * R(R(sy * rz) + R(sw * rx))),
				R(R(R(R(sw * rw) + R(sz * rz)) - R(sx * rx)) - R(sy * ry)),
				R(num_posescale * R(R(R(R(dy * sx) + R(dz * sw)) - R(dx * sy)) - R(dw * sz))),
			}
			if i == debugbone then
				local c = cmod(debugbonecomponent, 12) + 1
				mm[c] = R(mm[c] + debugbonevalue)
			end
			mm[4] = R(mm[4] * debugtranslatex)
			mm[8] = R(mm[8] * debugtranslatey)
			mm[12] = R(mm[12] * debugtranslatez)
			for k = 1, 12 do
				writef32(m, (k - 1) * 4, mm[k])
			end
			local parent = bones[i + 1].parent
			if parent >= 0 then
				R_ConcatTransforms(bonepose, bpo + parent * 48, m, 0, bonepose, bpo + i * 48)
			else
				buffer.copy(bonepose, bpo + i * 48, m, 0, 48)
			end
			-- create a relative deformation matrix to describe displacement
			-- from the base mesh, which is used by the actual weighting
			R_ConcatTransforms(bonepose, bpo + i * 48, inv, i * 48, boneposerelative, bro + i * 48)
		end
	end
end

-- port: mod_skeletal_animatevertices_generic.c Mod_Skeletal_AnimateVertices_Generic L3-134 @xonotic-v0.8.6
-- (vertex3f ... tvector3f: f32 buffers from vertex 0, nil = NULL)
function model_alias.Mod_Skeletal_AnimateVertices_Generic(
	model: any,
	frameblend: any,
	skeleton: any,
	vertex3f: buffer?,
	normal3f: buffer?,
	svector3f: buffer?,
	tvector3f: buffer?
)
	-- vertex weighted skeletal
	local surfmesh = model.surfmesh
	local num_bones: number = model.num_bones
	local num_blends: number = surfmesh.num_blends or 0
	local num_vertices: number = surfmesh.num_vertices

	--unsigned long long ts = rdtsc();
	local bonepose = model_alias.Mod_Skeletal_AnimateVertices_AllocBuffers(48 * (num_bones * 2 + num_blends))
	local rel = num_bones * 48 -- boneposerelative = bonepose + model->num_bones * 12

	model_alias.Mod_Skeletal_BuildTransforms(model, frameblend, skeleton, bonepose, 0, bonepose, rel)

	-- generate matrices for all blend combinations
	local weights: buffer? = surfmesh.data_blendweights
	for i = 0, num_blends - 1 do
		local w = weights :: buffer
		local b = rel + 48 * (num_bones + i)
		local mo = rel + 48 * readu8(w, i * 8)
		local f = R(readu8(w, i * 8 + 4) * R(1.0 / 255.0))
		for k = 0, 11 do
			writef32(bonepose, b + k * 4, R(f * readf32(bonepose, mo + k * 4)))
		end
		local k = 1
		while k < 4 and readu8(w, i * 8 + 4 + k) ~= 0 do
			mo = rel + 48 * readu8(w, i * 8 + k)
			f = R(readu8(w, i * 8 + 4 + k) * R(1.0 / 255.0))
			for c = 0, 11 do
				local o = b + c * 4
				writef32(bonepose, o, readf32(bonepose, o) + R(f * readf32(bonepose, mo + c * 4)))
			end
			k += 1
		end
	end

	-- LOAD_MATRIX_SCALAR: const float * RESTRICT m = boneposerelative + 12 * (unsigned int)*b
	local blends: buffer = surfmesh.blends
	local function TRANSFORM_POSITION(src: buffer, mo: number, dst: buffer, i: number)
		local o = i * 12
		local x, y, z = readf32(src, o), readf32(src, o + 4), readf32(src, o + 8)
		local function row(r: number): number
			local ro = mo + r * 16
			return R(
				R(R(R(x * readf32(bonepose, ro)) + R(y * readf32(bonepose, ro + 4))) + R(z * readf32(bonepose, ro + 8)))
					+ readf32(bonepose, ro + 12)
			)
		end
		local a, b2, c = row(0), row(1), row(2)
		writef32(dst, o, a)
		writef32(dst, o + 4, b2)
		writef32(dst, o + 8, c)
	end
	local function TRANSFORM_VECTOR(src: buffer, mo: number, dst: buffer, i: number)
		local o = i * 12
		local x, y, z = readf32(src, o), readf32(src, o + 4), readf32(src, o + 8)
		local function row(r: number): number
			local ro = mo + r * 16
			return R(
				R(R(x * readf32(bonepose, ro)) + R(y * readf32(bonepose, ro + 4))) + R(z * readf32(bonepose, ro + 8))
			)
		end
		local a, b2, c = row(0), row(1), row(2)
		writef32(dst, o, a)
		writef32(dst, o + 4, b2)
		writef32(dst, o + 8, c)
	end

	-- transform vertex attributes by blended matrices
	if vertex3f then
		local v: buffer = surfmesh.data_vertex3f
		-- special case common combinations of attributes to avoid repeated loading of matrices
		if normal3f then
			local n: buffer = surfmesh.data_normal3f
			if svector3f and tvector3f then
				local svec: buffer = surfmesh.data_svector3f
				local tvec: buffer = surfmesh.data_tvector3f

				-- Note that for SSE each iteration stores one element past end, so we break one vertex short
				-- and handle that with scalars in that case
				for i = 0, num_vertices - 1 do
					local mo = rel + 48 * readu16(blends, i * 2)
					TRANSFORM_POSITION(v, mo, vertex3f, i)
					TRANSFORM_VECTOR(n, mo, normal3f, i)
					TRANSFORM_VECTOR(svec, mo, svector3f, i)
					TRANSFORM_VECTOR(tvec, mo, tvector3f, i)
				end

				return
			end

			for i = 0, num_vertices - 1 do
				local mo = rel + 48 * readu16(blends, i * 2)
				TRANSFORM_POSITION(v, mo, vertex3f, i)
				TRANSFORM_VECTOR(n, mo, normal3f, i)
			end
		else
			for i = 0, num_vertices - 1 do
				local mo = rel + 48 * readu16(blends, i * 2)
				TRANSFORM_POSITION(v, mo, vertex3f, i)
			end
		end
	elseif normal3f then
		local n: buffer = surfmesh.data_normal3f
		for i = 0, num_vertices - 1 do
			local mo = rel + 48 * readu16(blends, i * 2)
			TRANSFORM_VECTOR(n, mo, normal3f, i)
		end
	end

	if svector3f then
		local svec: buffer = surfmesh.data_svector3f
		for i = 0, num_vertices - 1 do
			local mo = rel + 48 * readu16(blends, i * 2)
			TRANSFORM_VECTOR(svec, mo, svector3f, i)
		end
	end

	if tvector3f then
		local tvec: buffer = surfmesh.data_tvector3f
		for i = 0, num_vertices - 1 do
			local mo = rel + 48 * readu16(blends, i * 2)
			TRANSFORM_VECTOR(tvec, mo, tvector3f, i)
		end
	end
end

-- port: model_alias.c Mod_Skeletal_AnimateVertices L163-187 @xonotic-v0.8.6
local function Mod_Skeletal_AnimateVertices(
	model: any,
	frameblend: any,
	skeleton: any,
	vertex3f: buffer?,
	normal3f: buffer?,
	svector3f: buffer?,
	tvector3f: buffer?
)
	local surfmesh = model.surfmesh
	if surfmesh.num_vertices == 0 then
		return
	end

	if (model.num_bones or 0) == 0 then
		local n = surfmesh.num_vertices * 12
		if vertex3f then
			buffer.copy(vertex3f, 0, surfmesh.data_vertex3f, 0, n)
		end
		if normal3f then
			buffer.copy(normal3f, 0, surfmesh.data_normal3f, 0, n)
		end
		if svector3f then
			buffer.copy(svector3f, 0, surfmesh.data_svector3f, 0, n)
		end
		if tvector3f then
			buffer.copy(tvector3f, 0, surfmesh.data_tvector3f, 0, n)
		end
		return
	end

	-- #ifdef SSE_POSSIBLE: if(r_skeletal_use_sse_defined) if(r_skeletal_use_sse.integer) Mod_Skeletal_AnimateVertices_SSE
	-- (not ported: r_skeletal_use_sse_defined is false here, see Mod_AliasInit)
	model_alias.Mod_Skeletal_AnimateVertices_Generic(
		model,
		frameblend,
		skeleton,
		vertex3f,
		normal3f,
		svector3f,
		tvector3f
	)
end
model_alias.Mod_Skeletal_AnimateVertices = Mod_Skeletal_AnimateVertices

-- port: model_alias.c Mod_AliasInit L189-214 @xonotic-v0.8.6
function model_alias.Mod_AliasInit()
	-- Cvar_RegisterVariable(&r_skeletal_debugbone) ... (&mod_alias_force_animated): registered by engine/host.luau
	-- from engine/_port/sv_init_defs.luau, like every cvar of the dedicated init path.
	for i = 0, 319 do
		mod_md3_sin[i + 1] = R(libm.sin(i * math.pi * 2.0 / 256.0))
	end
	-- #ifdef SSE_POSSIBLE: if(Sys_HaveSSE()) { "Skeletal animation uses SSE code path"; r_skeletal_use_sse_defined
	-- = true; ... }: the SSE code path is not ported, so this is the branch C takes without SSE
	Con_Printf("Skeletal animation uses generic code path (SSE disabled or not detected)\n")
end

-- the blendweights_t at index i of data_blendweights (8 bytes: index[4], influence[4]) as a string key
local function blendkey(w: buffer, i: number): string
	return buffer.readstring(w, i * 8, 8)
end

-- port: model_alias.c Mod_Skeletal_AddBlend L216-231 @xonotic-v0.8.6
-- (newweights: { index = {4}, influence = {4} }. Port support: surfmesh.blendhash maps the 8 bytes of every stored
-- blend to its position, so the linear memcmp search returns the same position without scanning; the stored
-- blends are all different, as C only stores a blend it did not find.)
local function Mod_Skeletal_AddBlend(model: any, newweights: any): number
	local surfmesh = model.surfmesh
	if newweights.influence[2] == 0 then
		return newweights.index[1]
	end
	local weights: buffer = surfmesh.data_blendweights
	local key = string.char(
		newweights.index[1],
		newweights.index[2],
		newweights.index[3],
		newweights.index[4],
		newweights.influence[1],
		newweights.influence[2],
		newweights.influence[3],
		newweights.influence[4]
	)
	local hash: { [string]: number } = surfmesh.blendhash
	if not hash then
		hash = {}
		for k = 0, surfmesh.num_blends - 1 do
			hash[blendkey(weights, k)] = k
		end
		surfmesh.blendhash = hash
	end
	local found = hash[key]
	if found then
		return model.num_bones + found
	end
	local i = surfmesh.num_blends
	surfmesh.num_blends += 1
	buffer.writestring(weights, i * 8, key)
	hash[key] = i
	return model.num_bones + i
end
model_alias.Mod_Skeletal_AddBlend = Mod_Skeletal_AddBlend

-- port: model_alias.c Mod_Skeletal_CompressBlend L233-274 @xonotic-v0.8.6
-- (newindex: 4 ints, newinfluence: 4 floats, C element i at [i + 1])
local function Mod_Skeletal_CompressBlend(model: any, newindex: { number }, newinfluence: { number }): number
	local total: number
	local scale: number
	local newweights = { index = { 0, 0, 0, 0 }, influence = { 0, 0, 0, 0 } }
	if newinfluence[2] == 0 then
		return newindex[1]
	end
	scale = 0
	for i = 1, 4 do
		scale = R(scale + newinfluence[i])
	end
	scale = R(255.0 / scale)
	total = 0
	for i = 1, 4 do
		newweights.index[i] = newindex[i] % 256 -- (unsigned char)
		newweights.influence[i] = uchar(R(newinfluence[i] * scale))
		total += newweights.influence[i]
	end
	while total > 255 do
		for i = 1, 4 do
			if newweights.influence[i] > 0 and total > 255 then
				newweights.influence[i] -= 1
				total -= 1
			end
		end
	end
	while total < 255 do
		for i = 1, 4 do
			if newweights.influence[i] < 255 and total < 255 then
				newweights.influence[i] += 1
				total += 1
			end
		end
	end
	return Mod_Skeletal_AddBlend(model, newweights)
end
model_alias.Mod_Skeletal_CompressBlend = Mod_Skeletal_CompressBlend

-- port: model_alias.c Mod_MD3_AnimateVertices L276-363 @xonotic-v0.8.6
local function Mod_MD3_AnimateVertices(
	model: any,
	frameblend: any,
	_skeleton: any,
	vertex3f: buffer?,
	normal3f: buffer?,
	svector3f: buffer?,
	tvector3f: buffer?
)
	-- vertex morph
	local surfmesh = model.surfmesh
	local numverts: number = surfmesh.num_vertices
	local numblends = 0
	for blendnum = 0, MAX_FRAMEBLENDS - 1 do
		--VectorMA(translate, model->surfmesh.num_morphmdlframetranslate, frameblend[blendnum].lerp, translate);
		if frameblend[blendnum + 1].lerp > 0 then
			numblends = blendnum + 1
		end
	end
	local md3: buffer = surfmesh.data_morphmd3vertex
	local sin = mod_md3_sin
	-- special case for the first blend because it avoids some adds and the need to memset the arrays first
	for blendnum = 0, numblends - 1 do
		local fb = frameblend[blendnum + 1]
		local verts = 8 * numverts * fb.subframe
		if vertex3f then
			local scale = R(fb.lerp * R(1.0 / 64.0))
			if blendnum == 0 then
				for i = 0, numverts - 1 do
					local o = verts + i * 8
					writef32(vertex3f, i * 12, R(readi16(md3, o) * scale))
					writef32(vertex3f, i * 12 + 4, R(readi16(md3, o + 2) * scale))
					writef32(vertex3f, i * 12 + 8, R(readi16(md3, o + 4) * scale))
				end
			else
				for i = 0, numverts - 1 do
					local o = verts + i * 8
					for k = 0, 2 do
						local d = i * 12 + k * 4
						writef32(vertex3f, d, readf32(vertex3f, d) + R(readi16(md3, o + k * 2) * scale))
					end
				end
			end
		end
		-- the yaw and pitch stored in md3 models are 8bit quantized angles
		-- (0-255), and as such a lookup table is very well suited to
		-- decoding them, and since cosine is equivalent to sine with an
		-- extra 45 degree rotation, this uses one lookup table for both
		-- sine and cosine with a +64 bias to get cosine.
		if normal3f then
			local lerp = fb.lerp
			for i = 0, numverts - 1 do
				local o = verts + i * 8
				local pitch, yaw = readu8(md3, o + 6), readu8(md3, o + 7)
				local n0 = R(R(sin[yaw + 64 + 1] * sin[pitch + 1]) * lerp)
				local n1 = R(R(sin[yaw + 1] * sin[pitch + 1]) * lerp)
				local n2 = R(sin[pitch + 64 + 1] * lerp)
				if blendnum == 0 then
					writef32(normal3f, i * 12, n0)
					writef32(normal3f, i * 12 + 4, n1)
					writef32(normal3f, i * 12 + 8, n2)
				else
					writef32(normal3f, i * 12, readf32(normal3f, i * 12) + n0)
					writef32(normal3f, i * 12 + 4, readf32(normal3f, i * 12 + 4) + n1)
					writef32(normal3f, i * 12 + 8, readf32(normal3f, i * 12 + 8) + n2)
				end
			end
		end
		if svector3f then
			local tv = svector3f :: buffer
			local tt = tvector3f :: buffer
			local texvec: buffer = surfmesh.data_morphtexvecvertex
			local texvecvert = 6 * numverts * fb.subframe
			local f = R(fb.lerp * R(1.0 / 127.0))
			for i = 0, numverts - 1 do
				local o = texvecvert + i * 6
				for k = 0, 2 do
					local d = i * 12 + k * 4
					if blendnum == 0 then
						writef32(tv, d, R(readi8(texvec, o + k) * f))
						writef32(tt, d, R(readi8(texvec, o + 3 + k) * f))
					else
						writef32(tv, d, readf32(tv, d) + R(f * readi8(texvec, o + k)))
						writef32(tt, d, readf32(tt, d) + R(f * readi8(texvec, o + 3 + k)))
					end
				end
			end
		end
	end
end
model_alias.Mod_MD3_AnimateVertices = Mod_MD3_AnimateVertices

-- port: model_alias.c Mod_MDL_AnimateVertices L364-459 @xonotic-v0.8.6
local function Mod_MDL_AnimateVertices(
	model: any,
	frameblend: any,
	_skeleton: any,
	vertex3f: buffer?,
	normal3f: buffer?,
	svector3f: buffer?,
	tvector3f: buffer?
)
	-- vertex morph
	local surfmesh = model.surfmesh
	local numverts: number = surfmesh.num_vertices
	local translate = { 0, 0, 0 }
	local framesize: buffer? = surfmesh.data_morphmd2framesize6f
	local numblends = 0
	-- blend the frame translates to avoid redundantly doing so on each vertex
	-- (a bit of a brain twister but it works)
	for blendnum = 0, MAX_FRAMEBLENDS - 1 do
		local fb = frameblend[blendnum + 1]
		for k = 1, 3 do
			local t = if framesize
				then readf32(framesize, (fb.subframe * 6 + 3 + k - 1) * 4)
				else surfmesh.num_morphmdlframetranslate[k]
			translate[k] = R(translate[k] + R(fb.lerp * t))
		end
		if fb.lerp > 0 then
			numblends = blendnum + 1
		end
	end
	local mdl: buffer = surfmesh.data_morphmdlvertex
	-- special case for the first blend because it avoids some adds and the need to memset the arrays first
	for blendnum = 0, numblends - 1 do
		local fb = frameblend[blendnum + 1]
		local verts = 4 * numverts * fb.subframe
		if vertex3f then
			local scale = { 0, 0, 0 }
			for k = 1, 3 do
				local s = if framesize
					then readf32(framesize, (fb.subframe * 6 + k - 1) * 4)
					else surfmesh.num_morphmdlframescale[k]
				scale[k] = R(s * fb.lerp)
			end
			for i = 0, numverts - 1 do
				local o = verts + i * 4
				for k = 0, 2 do
					local d = i * 12 + k * 4
					if blendnum == 0 then
						writef32(vertex3f, d, R(translate[k + 1] + R(readu8(mdl, o + k) * scale[k + 1])))
					else
						writef32(vertex3f, d, readf32(vertex3f, d) + R(readu8(mdl, o + k) * scale[k + 1]))
					end
				end
			end
		end
		-- the vertex normals in mdl models are an index into a table of
		-- 162 unique values, this very crude quantization reduces the
		-- vertex normal to only one byte, which saves a lot of space but
		-- also makes lighting pretty coarse
		if normal3f then
			local lerp = fb.lerp
			for i = 0, numverts - 1 do
				local vn = m_bytenormals[readu8(mdl, verts + i * 4 + 3) + 1]
				for k = 0, 2 do
					local d = i * 12 + k * 4
					if blendnum == 0 then
						writef32(normal3f, d, R(vn[k + 1] * lerp))
					else
						writef32(normal3f, d, readf32(normal3f, d) + R(lerp * vn[k + 1]))
					end
				end
			end
		end
		if svector3f then
			local tv = svector3f :: buffer
			local tt = tvector3f :: buffer
			local texvec: buffer = surfmesh.data_morphtexvecvertex
			local texvecvert = 6 * numverts * fb.subframe
			local f = R(fb.lerp * R(1.0 / 127.0))
			for i = 0, numverts - 1 do
				local o = texvecvert + i * 6
				for k = 0, 2 do
					local d = i * 12 + k * 4
					if blendnum == 0 then
						writef32(tv, d, R(readi8(texvec, o + k) * f))
						writef32(tt, d, R(readi8(texvec, o + 3 + k) * f))
					else
						writef32(tv, d, readf32(tv, d) + R(f * readi8(texvec, o + k)))
						writef32(tt, d, readf32(tt, d) + R(f * readi8(texvec, o + 3 + k)))
					end
				end
			end
		end
	end
end
model_alias.Mod_MDL_AnimateVertices = Mod_MDL_AnimateVertices

-- port: model_alias.c Mod_Alias_GetTagMatrix L461-526 @xonotic-v0.8.6
-- (outmatrix: a matrix4x4_t written in place; returns the C return value)
function model_alias.Mod_Alias_GetTagMatrix(
	model: any,
	frameblend: any,
	skeleton: any,
	tagindex: number,
	outmatrix: matrix4x4_t
): number
	local temp = matrixlib.new()
	local parentbonematrix = matrixlib.new()
	local tempbonematrix: matrix4x4_t
	local bonematrix = matrixlib.new()
	local blendmatrix = matrixlib.new()
	local parenttagindex: number
	local lerp: number
	local blendtag = buffer.create(48)
	mcopy(outmatrix, matrixlib.identitymatrix)
	if skeleton and skeleton.relativetransforms then
		if tagindex < 0 or tagindex >= skeleton.model.num_bones then
			return 4
		end
		mcopy(outmatrix, skeleton.relativetransforms[tagindex + 1])
		tagindex = model.data_bones[tagindex + 1].parent
		while tagindex >= 0 do
			mcopy(temp, outmatrix)
			matrixlib.Matrix4x4_Concat(outmatrix, skeleton.relativetransforms[tagindex + 1], temp)
			tagindex = model.data_bones[tagindex + 1].parent
		end
	elseif (model.num_bones or 0) ~= 0 then
		if tagindex < 0 or tagindex >= model.num_bones then
			return 4
		end
		matrixlib.Matrix4x4_Clear(blendmatrix)
		local blendindex = 0
		while blendindex < MAX_FRAMEBLENDS and frameblend[blendindex + 1].lerp > 0 do
			local fb = frameblend[blendindex + 1]
			lerp = fb.lerp
			matrixlib.Matrix4x4_FromBonePose7s(
				bonematrix,
				model.num_posescale,
				model.data_poses7s,
				14 * (fb.subframe * model.num_bones + tagindex)
			)
			parenttagindex = model.data_bones[tagindex + 1].parent
			while parenttagindex >= 0 do
				matrixlib.Matrix4x4_FromBonePose7s(
					parentbonematrix,
					model.num_posescale,
					model.data_poses7s,
					14 * (fb.subframe * model.num_bones + parenttagindex)
				)
				tempbonematrix = mclone(bonematrix)
				matrixlib.Matrix4x4_Concat(bonematrix, parentbonematrix, tempbonematrix)
				parenttagindex = model.data_bones[parenttagindex + 1].parent
			end
			matrixlib.Matrix4x4_Accumulate(blendmatrix, bonematrix, lerp)
			blendindex += 1
		end
		mcopy(outmatrix, blendmatrix)
	elseif (model.num_tags or 0) ~= 0 then
		if tagindex < 0 or tagindex >= model.num_tags then
			return 4
		end
		local blend = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
		local blendindex = 0
		while blendindex < MAX_FRAMEBLENDS and frameblend[blendindex + 1].lerp > 0 do
			local fb = frameblend[blendindex + 1]
			lerp = fb.lerp
			local input = model.data_tags[fb.subframe * model.num_tags + tagindex + 1].matrixgl
			for k = 1, 12 do
				blend[k] = R(blend[k] + R(input[k] * lerp))
			end
			blendindex += 1
		end
		for k = 1, 12 do
			writef32(blendtag, (k - 1) * 4, blend[k])
		end
		matrixlib.Matrix4x4_FromArray12FloatGL(outmatrix, blendtag, 0)
	end

	if cvi("mod_alias_supporttagscale") == 0 then
		matrixlib.Matrix4x4_Normalize3(outmatrix, outmatrix)
	end

	return 0
end

-- port: model_alias.c Mod_Alias_GetExtendedTagInfoForIndex L528-583 @xonotic-v0.8.6
-- (tag_localmatrix written in place; returns the C return value, then *parentindex and *tagname, nil where C
-- leaves them unwritten)
function model_alias.Mod_Alias_GetExtendedTagInfoForIndex(
	model: any,
	_skin: number,
	frameblend: any,
	skeleton: any,
	tagindex: number,
	tag_localmatrix: matrix4x4_t
): (number, number?, string?)
	local lerp: number
	local bonematrix = matrixlib.new()
	local blendmatrix = matrixlib.new()
	local blendtag = buffer.create(48)

	if skeleton and skeleton.relativetransforms then
		if tagindex < 0 or tagindex >= skeleton.model.num_bones then
			return 1, nil, nil
		end
		local parentindex = skeleton.model.data_bones[tagindex + 1].parent
		local tagname = skeleton.model.data_bones[tagindex + 1].name
		mcopy(tag_localmatrix, skeleton.relativetransforms[tagindex + 1])
		return 0, parentindex, tagname
	elseif (model.num_bones or 0) ~= 0 then
		if tagindex < 0 or tagindex >= model.num_bones then
			return 1, nil, nil
		end
		local parentindex = model.data_bones[tagindex + 1].parent
		local tagname = model.data_bones[tagindex + 1].name
		matrixlib.Matrix4x4_Clear(blendmatrix)
		local blendindex = 0
		while blendindex < MAX_FRAMEBLENDS and frameblend[blendindex + 1].lerp > 0 do
			local fb = frameblend[blendindex + 1]
			lerp = fb.lerp
			matrixlib.Matrix4x4_FromBonePose7s(
				bonematrix,
				model.num_posescale,
				model.data_poses7s,
				14 * (fb.subframe * model.num_bones + tagindex)
			)
			matrixlib.Matrix4x4_Accumulate(blendmatrix, bonematrix, lerp)
			blendindex += 1
		end
		mcopy(tag_localmatrix, blendmatrix)
		return 0, parentindex, tagname
	elseif (model.num_tags or 0) ~= 0 then
		if tagindex < 0 or tagindex >= model.num_tags then
			return 1, nil, nil
		end
		local parentindex = -1
		local tagname = model.data_tags[tagindex + 1].name
		local blend = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
		local blendindex = 0
		while blendindex < MAX_FRAMEBLENDS and frameblend[blendindex + 1].lerp > 0 do
			local fb = frameblend[blendindex + 1]
			lerp = fb.lerp
			local input = model.data_tags[fb.subframe * model.num_tags + tagindex + 1].matrixgl
			for k = 1, 12 do
				blend[k] = R(blend[k] + R(input[k] * lerp))
			end
			blendindex += 1
		end
		for k = 1, 12 do
			writef32(blendtag, (k - 1) * 4, blend[k])
		end
		matrixlib.Matrix4x4_FromArray12FloatGL(tag_localmatrix, blendtag, 0)
		return 0, parentindex, tagname
	end

	return 2, nil, nil
end

-- port: model_alias.c Mod_Alias_GetTagIndexForName L585-599 @xonotic-v0.8.6
function model_alias.Mod_Alias_GetTagIndexForName(model: any, skin: number, tagname: string): number
	if skin >= (model.numskins or 0) then -- (unsigned int) compare: skin is unsigned
		skin = 0
	end
	if (model.num_bones or 0) ~= 0 then
		for i = 0, model.num_bones - 1 do
			if libc.strcasecmp(tagname, model.data_bones[i + 1].name) == 0 then
				return i + 1
			end
		end
	end
	if (model.num_tags or 0) ~= 0 then
		for i = 0, model.num_tags - 1 do
			if libc.strcasecmp(tagname, model.data_tags[i + 1].name) == 0 then
				return i + 1
			end
		end
	end
	return 0
end

-- port: model_alias.c Mod_BuildBaseBonePoses L601-624 @xonotic-v0.8.6
local function Mod_BuildBaseBonePoses()
	local loadmodel = model_shared.loadmodel
	local outinvmatrix: buffer = loadmodel.data_baseboneposeinverse
	local bonematrix = matrixlib.new()
	local tempbonematrix = matrixlib.new()
	if (loadmodel.num_bones or 0) == 0 then
		return
	end
	local basebonepose: { matrix4x4_t } = table.create(loadmodel.num_bones)
	for boneindex = 0, loadmodel.num_bones - 1 do
		matrixlib.Matrix4x4_FromBonePose7s(bonematrix, loadmodel.num_posescale, loadmodel.data_poses7s, 14 * boneindex)
		local parent = loadmodel.data_bones[boneindex + 1].parent
		if parent >= 0 then
			mcopy(tempbonematrix, bonematrix)
			matrixlib.Matrix4x4_Concat(bonematrix, basebonepose[parent + 1], tempbonematrix)
		end
		basebonepose[boneindex + 1] = mclone(bonematrix)
		matrixlib.Matrix4x4_Invert_Simple(tempbonematrix, basebonepose[boneindex + 1])
		matrixlib.Matrix4x4_ToArray12FloatD3D(tempbonematrix, outinvmatrix, 48 * boneindex)
	end
	-- Mem_Free(basebonepose);
end
model_alias.Mod_BuildBaseBonePoses = Mod_BuildBaseBonePoses

-- port: model_alias.c Mod_Alias_CalculateBoundingBox L626-725 @xonotic-v0.8.6
local function Mod_Alias_CalculateBoundingBox(): boolean
	local loadmodel = model_shared.loadmodel
	local firstvertex = true
	local dist: number
	local yawradius: number
	local radius: number
	local isanimated = false
	local nmins, nmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	loadmodel.normalmins = nmins
	loadmodel.normalmaxs = nmaxs
	yawradius = 0
	radius = 0
	local numv: number = loadmodel.surfmesh.num_vertices
	local function addvertex(v: buffer, o: number)
		local x, y, z = readf32(v, o), readf32(v, o + 4), readf32(v, o + 8)
		if firstvertex then
			firstvertex = false
			nmins[1], nmins[2], nmins[3] = x, y, z
			nmaxs[1], nmaxs[2], nmaxs[3] = x, y, z
		else
			if nmins[1] > x then
				nmins[1] = x
			end
			if nmins[2] > y then
				nmins[2] = y
			end
			if nmins[3] > z then
				nmins[3] = z
			end
			if nmaxs[1] < x then
				nmaxs[1] = x
			end
			if nmaxs[2] < y then
				nmaxs[2] = y
			end
			if nmaxs[3] < z then
				nmaxs[3] = z
			end
		end
		dist = R(R(x * x) + R(y * y))
		if yawradius < dist then
			yawradius = dist
		end
		dist = R(dist + R(z * z))
		if radius < dist then
			radius = dist
		end
	end
	if loadmodel.AnimateVertices then
		local frameblend = newframeblend()
		frameblend[1].lerp = 1
		local vertex3f = buffer.create(numv * 12 * 2)
		local refvertex3f: buffer? = nil
		local n = numv * 12
		frameblend[1].subframe = 0
		while frameblend[1].subframe < loadmodel.num_poses do
			loadmodel.AnimateVertices(loadmodel, frameblend, nil, vertex3f, nil, nil, nil)
			if not refvertex3f then
				-- make a copy of the first frame for comparing all others
				refvertex3f = vertex3f -- refvertex3f = vertex3f + loadmodel->surfmesh.num_vertices * 3
				buffer.copy(vertex3f, n, vertex3f, 0, n)
			else
				if not isanimated and buffer.readstring(vertex3f, n, n) ~= buffer.readstring(vertex3f, 0, n) then
					isanimated = true
				end
			end
			for vnum = 0, numv - 1 do
				addvertex(vertex3f, vnum * 12)
			end
			frameblend[1].subframe += 1
		end
		-- Mem_Free(vertex3f);
	else
		local v: buffer = loadmodel.surfmesh.data_vertex3f
		for vnum = 0, numv - 1 do
			addvertex(v, vnum * 12)
		end
	end
	radius = R(math.sqrt(radius))
	yawradius = R(math.sqrt(yawradius))
	loadmodel.yawmins = { -yawradius, -yawradius, nmins[3] }
	loadmodel.yawmaxs = { yawradius, yawradius, nmaxs[3] }
	loadmodel.rotatedmins = { -radius, -radius, -radius }
	loadmodel.rotatedmaxs = { radius, radius, radius }
	loadmodel.radius = radius
	loadmodel.radius2 = R(radius * radius)
	return isanimated
end
model_alias.Mod_Alias_CalculateBoundingBox = Mod_Alias_CalculateBoundingBox

-- port: model_alias.c Mod_Alias_MorphMesh_CompileFrames L727-753 @xonotic-v0.8.6
local function Mod_Alias_MorphMesh_CompileFrames()
	local loadmodel = model_shared.loadmodel
	local surfmesh = loadmodel.surfmesh
	local frameblend = newframeblend()
	frameblend[1].lerp = 1
	local nv: number = surfmesh.num_vertices
	surfmesh.data_vertex3f = buffer.create(nv * 12)
	surfmesh.data_svector3f = buffer.create(nv * 12)
	surfmesh.data_tvector3f = buffer.create(nv * 12)
	surfmesh.data_normal3f = buffer.create(nv * 12)
	surfmesh.data_morphtexvecvertex = buffer.create(surfmesh.num_morphframes * nv * 6)
	local areaweighting = cvi("r_smoothnormals_areaweighting") ~= 0
	local texvec: buffer = surfmesh.data_morphtexvecvertex
	-- this counts down from the last frame to the first so that the final data in surfmesh is for frame zero (which is what the renderer expects to be there)
	for i = surfmesh.num_morphframes - 1, 0, -1 do
		frameblend[1].subframe = i
		loadmodel.AnimateVertices(loadmodel, frameblend, nil, surfmesh.data_vertex3f, surfmesh.data_normal3f, nil, nil)
		model_shared.Mod_BuildTextureVectorsFromNormals(
			0,
			nv,
			surfmesh.num_triangles,
			surfmesh.data_vertex3f,
			surfmesh.data_texcoordtexture2f,
			surfmesh.data_normal3f,
			surfmesh.data_element3i,
			0,
			surfmesh.data_svector3f,
			surfmesh.data_tvector3f,
			areaweighting
		)
		-- encode the svector and tvector in 3 byte format for permanent storage
		for j = 0, nv - 1 do
			local o = (i * nv + j) * 6
			for k = 0, 2 do
				writei8(texvec, o + k, schar(R(readf32(surfmesh.data_svector3f, j * 12 + k * 4) * 127.0)))
				writei8(texvec, o + 3 + k, schar(R(readf32(surfmesh.data_tvector3f, j * 12 + k * 4) * 127.0)))
			end
		end
	end
end
model_alias.Mod_Alias_MorphMesh_CompileFrames = Mod_Alias_MorphMesh_CompileFrames

-- port: model_alias.c Mod_MDLMD2MD3_TraceLine L755-792 @xonotic-v0.8.6
local function Mod_MDLMD2MD3_TraceLine(
	model: any,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	local segmentmins, segmentmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local vertex3f: buffer
	-- for static cases we can just call CollisionBIH which is much faster
	if
		(frameblend == nil or (frameblend[1].subframe == 0 and frameblend[2].lerp == 0))
		and (skeleton == nil or skeleton.relativetransforms == nil)
	then
		model_brush.Mod_CollisionBIH_TraceLine(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			end_,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		return
	end
	collision.cleartrace(trace)
	trace.fraction = 1
	trace.hitsupercontentsmask = hitsupercontentsmask
	trace.skipsupercontentsmask = skipsupercontentsmask
	trace.skipmaterialflagsmask = skipmaterialflagsmask
	for k = 1, 3 do
		segmentmins[k] = R((if start[k] < end_[k] then start[k] else end_[k]) - 1)
		segmentmaxs[k] = R((if start[k] > end_[k] then start[k] else end_[k]) + 1)
	end
	-- (frameblend[0].lerp != 0 is true for every animated pose, so the BIH vertex array is used only when C sees
	-- a zero lerp in the first blend)
	if frameblend == nil or frameblend[1].subframe ~= 0 or frameblend[1].lerp ~= 0 or skeleton ~= nil then
		-- float vertex3fbuf[1024 * 3] or Mem_Alloc(tempmempool, ...) when there are more vertices
		vertex3f = buffer.create(math.max(model.surfmesh.num_vertices, 1024) * 12)
		model.AnimateVertices(model, frameblend, skeleton, vertex3f, nil, nil, nil)
	else
		vertex3f = model.surfmesh.data_vertex3f
	end
	-- (each surface traces against every triangle of the mesh, with that surface's texture, as in C)
	for i = 0, model.num_surfaces - 1 do
		local surface = model.data_surfaces[i + 1]
		collision.Collision_TraceLineTriangleMeshFloat(
			trace,
			start,
			end_,
			model.surfmesh.num_triangles,
			model.surfmesh.data_element3i,
			0,
			vertex3f,
			0,
			nil,
			bit32.bor(
				SUPERCONTENTS_SOLID,
				if bit32.band(surface.texture.basematerialflags or 0, MATERIALFLAGMASK_TRANSLUCENT) ~= 0
					then 0
					else SUPERCONTENTS_OPAQUE
			),
			0,
			surface.texture,
			segmentmins,
			segmentmaxs
		)
	end
	-- if (freevertex3f) Mem_Free(freevertex3f);
end
model_alias.Mod_MDLMD2MD3_TraceLine = Mod_MDLMD2MD3_TraceLine

-- port: model_alias.c Mod_MDLMD2MD3_TraceBox L794-846 @xonotic-v0.8.6
local function Mod_MDLMD2MD3_TraceBox(
	model: any,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	boxmins: { number },
	boxmaxs: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	local segmentmins, segmentmaxs = { 0, 0, 0 }, { 0, 0, 0 }

	if boxmins[1] == boxmaxs[1] and boxmins[2] == boxmaxs[2] and boxmins[3] == boxmaxs[3] then
		local shiftstart = { R(start[1] + boxmins[1]), R(start[2] + boxmins[2]), R(start[3] + boxmins[3]) }
		local shiftend = { R(end_[1] + boxmins[1]), R(end_[2] + boxmins[2]), R(end_[3] + boxmins[3]) }
		Mod_MDLMD2MD3_TraceLine(
			model,
			frameblend,
			skeleton,
			trace,
			shiftstart,
			shiftend,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		-- (trace_t.endpos is double[3]: the difference is not rounded to float)
		local e = trace.endpos
		e[1], e[2], e[3] = e[1] - boxmins[1], e[2] - boxmins[2], e[3] - boxmins[3]
		return
	end

	-- for static cases we can just call CollisionBIH which is much faster
	if
		(frameblend == nil or (frameblend[1].subframe == 0 and frameblend[2].lerp == 0))
		and (skeleton == nil or skeleton.relativetransforms == nil)
	then
		model_brush.Mod_CollisionBIH_TraceBox(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			boxmins,
			boxmaxs,
			end_,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		return
	end

	-- box trace, performed as brush trace
	collision.cleartrace(trace)
	trace.fraction = 1
	trace.hitsupercontentsmask = hitsupercontentsmask
	trace.skipsupercontentsmask = skipsupercontentsmask
	trace.skipmaterialflagsmask = skipmaterialflagsmask
	-- float vertex3fbuf[1024*3] or Mem_Alloc(tempmempool, ...) when there are more vertices
	local vertex3f = buffer.create(math.max(model.surfmesh.num_vertices, 1024) * 12)
	for k = 1, 3 do
		segmentmins[k] = R(R((if start[k] < end_[k] then start[k] else end_[k]) + boxmins[k]) - 1)
		segmentmaxs[k] = R(R((if start[k] > end_[k] then start[k] else end_[k]) + boxmaxs[k]) + 1)
	end
	local boxstartmins = { R(start[1] + boxmins[1]), R(start[2] + boxmins[2]), R(start[3] + boxmins[3]) }
	local boxstartmaxs = { R(start[1] + boxmaxs[1]), R(start[2] + boxmaxs[2]), R(start[3] + boxmaxs[3]) }
	local boxendmins = { R(end_[1] + boxmins[1]), R(end_[2] + boxmins[2]), R(end_[3] + boxmins[3]) }
	local boxendmaxs = { R(end_[1] + boxmaxs[1]), R(end_[2] + boxmaxs[2]), R(end_[3] + boxmaxs[3]) }
	local thisbrush_start = collision.Collision_BrushForBox(boxstartmins, boxstartmaxs, 0, 0, nil)
	local thisbrush_end = collision.Collision_BrushForBox(boxendmins, boxendmaxs, 0, 0, nil)
	model.AnimateVertices(model, frameblend, skeleton, vertex3f, nil, nil, nil)
	-- (each surface traces against every triangle of the mesh, with that surface's texture, as in C)
	for i = 0, model.num_surfaces - 1 do
		local surface = model.data_surfaces[i + 1]
		collision.Collision_TraceBrushTriangleMeshFloat(
			trace,
			thisbrush_start,
			thisbrush_end,
			model.surfmesh.num_triangles,
			model.surfmesh.data_element3i,
			0,
			vertex3f,
			0,
			nil,
			bit32.bor(
				SUPERCONTENTS_SOLID,
				if bit32.band(surface.texture.basematerialflags or 0, MATERIALFLAGMASK_TRANSLUCENT) ~= 0
					then 0
					else SUPERCONTENTS_OPAQUE
			),
			0,
			surface.texture,
			segmentmins,
			segmentmaxs
		)
	end
	-- if (vertex3f != vertex3fbuf) Mem_Free(vertex3f);
end
model_alias.Mod_MDLMD2MD3_TraceBox = Mod_MDLMD2MD3_TraceBox

-- port: model_alias.c Mod_ConvertAliasVerts L848-862 @xonotic-v0.8.6
-- (v: the file's trivertx_t array at byte vo; out: data_morphmdlvertex at byte oo; vertremap: i32 buffer)
local function Mod_ConvertAliasVerts(inverts: number, v: buffer, vo: number, out: buffer, oo: number, vertremap: buffer)
	for i = 0, inverts - 1 do
		local a, b = readi32(vertremap, i * 4), readi32(vertremap, (i + inverts) * 4)
		if a < 0 and b < 0 then -- only used vertices need apply...
			continue
		end
		local j = a -- not onseam
		if j >= 0 then
			buffer.copy(out, oo + j * 4, v, vo + i * 4, 4)
		end
		j = b -- onseam
		if j >= 0 then
			buffer.copy(out, oo + j * 4, v, vo + i * 4, 4)
		end
	end
end

-- port: model_alias.c Mod_MDL_LoadFrames L864-923 @xonotic-v0.8.6 (datapointer: byte offset into the file b)
local function Mod_MDL_LoadFrames(b: buffer, datapointer: number, inverts: number, vertremap: buffer)
	local loadmodel = model_shared.loadmodel
	local groupframes: number
	local interval: number
	local pose = 0
	local scene = 0 -- loadmodel->animscenes index
	for _f = 0, loadmodel.numframes - 1 do
		local pframetype = datapointer
		datapointer += 4 -- sizeof(daliasframetype_t)
		if readi32(b, pframetype) == ALIAS_SINGLE then
			-- a single frame is still treated as a group
			interval = R(0.1)
			groupframes = 1
		else
			-- read group header
			local group = datapointer
			datapointer += 12 -- sizeof(daliasgroup_t)
			groupframes = readi32(b, group)

			-- intervals (time per frame)
			local intervals = datapointer
			datapointer += 4 * groupframes -- sizeof(daliasinterval_t) * groupframes

			interval = readf32(b, intervals) -- FIXME: support variable framerate groups
			if interval < R(0.01) then
				Con_Printf("%s has an invalid interval %f, changing to 0.1\n", loadmodel.name, interval)
				interval = R(0.1)
			end
		end

		-- get scene name from first frame
		local pinframe = datapointer

		local s = loadmodel.animscenes[scene + 1]
		s.name = cstr(b, pinframe + 8, 31) -- strlcpy(scene->name, pinframe->name, sizeof(scene->name))
		s.firstframe = pose
		s.framecount = groupframes
		s.framerate = R(1.0 / interval)
		s.loop = true
		scene += 1

		-- read frames
		for _i = 0, groupframes - 1 do
			datapointer += 24 -- sizeof(daliasframe_t)
			Mod_ConvertAliasVerts(
				inverts,
				b,
				datapointer,
				loadmodel.surfmesh.data_morphmdlvertex,
				4 * pose * loadmodel.surfmesh.num_vertices,
				vertremap
			)
			datapointer += 4 * inverts -- sizeof(trivertx_t) * inverts
			pose += 1
		end
	end
end

-- port: model_alias.c Mod_BuildAliasSkinFromSkinFrame L925-962 @xonotic-v0.8.6
local function Mod_BuildAliasSkinFromSkinFrame(texture: any, skinframe: any)
	if cvar.cls_state_dedicated then
		return
	end
	-- hack
	if not skinframe then
		skinframe = model_shared.R_SkinFrame_LoadMissing()
	end
	cleartexture(texture)
	texture.currentframe = texture
	--texture->animated = false;
	texture.shaderpasses = {}
	texture.shaderpasses[1] = model_shared.Mod_CreateShaderPass(skinframe)
	texture.materialshaderpass = texture.shaderpasses[1]
	texture.currentskinframe = skinframe
	--texture->backgroundnumskinframes = 0;
	--texture->customblendfunc[0] = 0;
	--texture->customblendfunc[1] = 0;
	--texture->surfaceflags = 0;
	--texture->supercontents = 0;
	--texture->surfaceparms = 0;
	--texture->textureflags = 0;

	texture.basematerialflags = MATERIALFLAG_WALL
	texture.basealpha = 1.0
	if texture.currentskinframe.hasalpha then
		texture.basematerialflags =
			bit32.bor(texture.basematerialflags, MATERIALFLAG_ALPHA + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW)
	end
	texture.currentmaterialflags = texture.basematerialflags
	texture.offsetmapping = OFFSETMAPPING_DEFAULT
	texture.offsetscale = 1
	texture.offsetbias = 0
	texture.specularscalemod = 1
	texture.specularpowermod = 1
	texture.surfaceflags = 0
	texture.supercontents = SUPERCONTENTS_SOLID
	if bit32.band(texture.basematerialflags, MATERIALFLAG_BLENDED) == 0 then
		texture.supercontents = bit32.bor(texture.supercontents, SUPERCONTENTS_OPAQUE)
	end
	texture.transparentsort = TRANSPARENTSORT_DISTANCE
	-- WHEN ADDING DEFAULTS HERE, REMEMBER TO PUT DEFAULTS IN ALL LOADERS
	-- JUST GREP FOR "specularscalemod = 1".
end
model_alias.Mod_BuildAliasSkinFromSkinFrame = Mod_BuildAliasSkinFromSkinFrame

-- the extension after the last '.' of the last path component, else ""
-- port: fs.c FS_FileExtension L1328-1345 @xonotic-v0.8.6
local function FS_FileExtension(s: string): string
	local sep = 0
	for i = #s, 1, -1 do
		local c = string.sub(s, i, i)
		if c == "/" or c == "\\" or c == ":" then
			sep = i
			break
		end
	end
	local dot = nil
	for i = #s, 1, -1 do
		if string.sub(s, i, i) == "." then
			dot = i
			break
		end
	end
	if dot == nil or (sep ~= 0 and dot < sep) then
		return ""
	end
	return string.sub(s, dot + 1)
end

-- port: fs.c FS_StripExtension L3421-3442 @xonotic-v0.8.6
local function FS_StripExtension(in_: string, size_out: number): string
	local out = {}
	local last: number? = nil
	if size_out == 0 then
		return ""
	end
	local i = 1
	while i <= #in_ and size_out > 1 do
		local c = string.sub(in_, i, i)
		if c == "." then
			last = #out + 1
		elseif c == "/" or c == "\\" or c == ":" then
			last = nil
		end
		table.insert(out, c)
		i += 1
		size_out -= 1
	end
	if last then
		return table.concat(out, "", 1, last - 1)
	end
	return table.concat(out)
end

-- port: image.c Image_StripImageExtension L838-850 @xonotic-v0.8.6
local function Image_StripImageExtension(in_: string, size_out: number): string
	if size_out == 0 then
		return ""
	end
	local ext = FS_FileExtension(in_)
	if ext == "tga" or ext == "pcx" or ext == "lmp" or ext == "png" or ext == "jpg" or ext == "wal" then
		return FS_StripExtension(in_, size_out)
	end
	return string.sub(in_, 1, size_out - 1) -- strlcpy(out, in, size_out)
end

local MAX_QPATH = 128

-- port: model_alias.c Mod_BuildAliasSkinsFromSkinFiles L964-1007 @xonotic-v0.8.6
-- (skin: data_textures and the 0-based index of the first texture, as C's texture_t pointer)
function model_alias.Mod_BuildAliasSkinsFromSkinFiles(
	textures: { any },
	skin: number,
	skinfile: any,
	meshname: string,
	shadername: string
)
	local loadmodel = model_shared.loadmodel
	local developer_extra = cvi("developer_extra") ~= 0
	local texflags =
		bit32.bor(if cvi("r_mipskins") ~= 0 then TEXF_MIPMAP else 0, TEXF_ALPHA, TEXF_PICMIP, TEXF_COMPRESS)
	if developer_extra then
		Con_DPrintf("Looking up texture for %s (default: %s)\n", meshname, shadername)
	end
	if skinfile then
		-- the skin += loadmodel->num_surfaces part of this is because data_textures on alias models is arranged as [numskins][numsurfaces]
		while skinfile do
			local tex = textures[skin + 1]
			cleartexture(tex)
			-- see if a mesh
			local skinfileitem = skinfile.items
			while skinfileitem do
				-- leave the skin unitialized (nodraw) if the replacement is "common/nodraw" or "textures/common/nodraw"
				if skinfileitem.name == meshname then
					local stripbuf = Image_StripImageExtension(skinfileitem.replacement, MAX_QPATH)
					if developer_extra then
						Con_DPrintf("--> got %s from skin file\n", stripbuf)
					end
					model_shared.Mod_LoadTextureFromQ3Shader(tex, stripbuf, true, true, texflags)
					break
				end
				skinfileitem = skinfileitem.next
			end
			if not skinfileitem then
				-- don't render unmentioned meshes
				Mod_BuildAliasSkinFromSkinFrame(tex, nil)
				if developer_extra then
					Con_DPrintf("--> skipping\n")
				end
				tex.basematerialflags = MATERIALFLAG_NOSHADOW + MATERIALFLAG_NODRAW
				tex.currentmaterialflags = tex.basematerialflags
			end
			skinfile = skinfile.next
			skin += loadmodel.num_surfaces
		end
	else
		if developer_extra then
			Con_DPrintf("--> using default\n")
		end
		local stripbuf = Image_StripImageExtension(shadername, MAX_QPATH)
		model_shared.Mod_LoadTextureFromQ3Shader(textures[skin + 1], stripbuf, true, true, texflags)
	end
end

-- the end of every loader: one BIH for the first frame, the BIH traces for static models, the sky / water checks
-- (C repeats these lines in each loader; the port lines are on the loaders)
local function finishmodel(_mod: any)
	local loadmodel = model_shared.loadmodel
	-- Always make a BIH for the first frame, we can use it where possible.
	model_brush.Mod_MakeCollisionBIH(loadmodel, true, loadmodel.collision_bih)
	if not loadmodel.surfmesh.isanimated then
		loadmodel.TraceBox = model_brush.Mod_CollisionBIH_TraceBox
		loadmodel.TraceBrush = model_brush.Mod_CollisionBIH_TraceBrush
		loadmodel.TraceLine = model_brush.Mod_CollisionBIH_TraceLine
		loadmodel.TracePoint = model_brush.Mod_CollisionBIH_TracePoint_Mesh
		loadmodel.PointSuperContents = model_brush.Mod_CollisionBIH_PointSuperContents_Mesh
	end
end
local function checkunusualfeatures(mod: any)
	local loadmodel = model_shared.loadmodel
	-- because shaders can do somewhat unexpected things, check for unusual features now
	for i = 0, loadmodel.num_textures - 1 do
		local flags = loadmodel.data_textures[i + 1].basematerialflags or 0
		if bit32.band(flags, MATERIALFLAG_SKY) ~= 0 then
			mod.DrawSky = "R_Q1BSP_DrawSky"
		end
		if
			bit32.band(
				flags,
				MATERIALFLAG_WATERSHADER + MATERIALFLAG_REFRACTION + MATERIALFLAG_REFLECTION + MATERIALFLAG_CAMERA
			) ~= 0
		then
			mod.DrawAddWaterPlanes = "R_Q1BSP_DrawAddWaterPlanes"
		end
	end
end

-- the renderer entry points every alias loader sets (C function pointers; names here, no renderer yet)
local function setaliasdraw(loadmodel: any)
	loadmodel.DrawSky = nil
	loadmodel.DrawAddWaterPlanes = nil
	loadmodel.Draw = "R_Q1BSP_Draw"
	loadmodel.DrawDepth = "R_Q1BSP_DrawDepth"
	loadmodel.DrawDebug = "R_Q1BSP_DrawDebug"
	loadmodel.DrawPrepass = "R_Q1BSP_DrawPrepass"
	loadmodel.CompileShadowMap = "R_Q1BSP_CompileShadowMap"
	loadmodel.DrawShadowMap = "R_Q1BSP_DrawShadowMap"
	loadmodel.CompileShadowVolume = "R_Q1BSP_CompileShadowVolume"
	loadmodel.DrawShadowVolume = "R_Q1BSP_DrawShadowVolume"
	loadmodel.DrawLight = "R_Q1BSP_DrawLight"
	loadmodel.TraceBox = Mod_MDLMD2MD3_TraceBox
	loadmodel.TraceLine = Mod_MDLMD2MD3_TraceLine
end

-- the surfmesh, collision BIH and the arrays every loader allocates (zeroed, as Mem_Alloc returns)
local function newsurfmesh(loadmodel: any)
	loadmodel.surfmesh =
		{ num_vertices = 0, num_triangles = 0, num_blends = 0, num_morphframes = 0, isanimated = false }
	loadmodel.collision_bih = bih.new()
	loadmodel.firstmodelsurface = 0
end

-- (C) effects = ((i & 255) << 24) | (i & 0x00FFFF00) on an int
local function aliaseffects(i: number): number
	return int32(bit32.bor(bit32.lshift(bit32.band(i, 255), 24), bit32.band(i, 0x00FFFF00)))
end

-- BOUNDI(VALUE,MIN,MAX) (model_alias.c L1009): the message has the literal text ##VALUE (no token pasting
-- inside a string literal)
local function BOUNDI(value: number, min: number, max: number)
	if value < min or value >= max then
		Host_Error("model %s has an invalid ##VALUE (%d exceeds %d - %d)", model_shared.loadmodel.name, value, min, max)
	end
end

-- (r_mipskins.integer ? TEXF_MIPMAP : 0) | TEXF_ALPHA | TEXF_PICMIP | TEXF_COMPRESS
local function skintexflags(): number
	return bit32.bor(if cvi("r_mipskins") ~= 0 then TEXF_MIPMAP else 0, TEXF_ALPHA, TEXF_PICMIP, TEXF_COMPRESS)
end

-- the ushort elements array, when there is one: data_element3s[i] = data_element3i[i] ((unsigned short) wraps)
local function copyelements3s(surfmesh: any)
	if surfmesh.data_element3s then
		for i = 0, surfmesh.num_triangles * 3 - 1 do
			writeu16(surfmesh.data_element3s, i * 2, readi32(surfmesh.data_element3i, i * 4) % 65536)
		end
	end
end

local function newskinscenes(n: number): { any }
	local s = table.create(n)
	for i = 1, n do
		s[i] = newscene()
	end
	return s
end
local function newtextures(n: number): { any }
	local t = table.create(n)
	for i = 1, n do
		t[i] = newtexture(i - 1)
	end
	return t
end
local function newsurfaces(n: number): { any }
	local s = table.create(n)
	for i = 1, n do
		s[i] = newsurface(i - 1)
	end
	return s
end
local function newsorted(n: number): { number }
	return table.create(n, 0)
end

-- port: model_alias.c Mod_IDP0_Load L1011-1373 @xonotic-v0.8.6
function model_alias.Mod_IDP0_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local version, totalskins, skinwidth, skinheight, groupframes, groupskins, numverts
	local scales, scalet, interval
	local datapointer, startframes, startskins
	local name: string
	local skinfiles

	datapointer = 0
	local pinmodel = datapointer
	datapointer += 84 -- sizeof(mdl_t)

	version = readi32(b, pinmodel + 4)
	if version ~= ALIAS_VERSION then
		Host_Error("%s has wrong version number (%i should be %i)", loadmodel.name, version, ALIAS_VERSION)
	end

	loadmodel.modeldatatypestring = "MDL"

	loadmodel.type = "mod_alias"
	setaliasdraw(loadmodel)
	-- FIXME add TraceBrush!
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_MDL_AnimateVertices

	local surfmesh = loadmodel.surfmesh
	loadmodel.num_surfaces = 1
	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces[1] = 0

	loadmodel.numskins = readi32(b, pinmodel + 48)
	BOUNDI(loadmodel.numskins, 0, 65536)
	skinwidth = readi32(b, pinmodel + 52)
	BOUNDI(skinwidth, 0, 65536)
	skinheight = readi32(b, pinmodel + 56)
	BOUNDI(skinheight, 0, 65536)
	numverts = readi32(b, pinmodel + 60)
	BOUNDI(numverts, 0, 65536)
	surfmesh.num_triangles = readi32(b, pinmodel + 64)
	BOUNDI(surfmesh.num_triangles, 0, 65536)
	loadmodel.numframes = readi32(b, pinmodel + 68)
	BOUNDI(loadmodel.numframes, 0, 65536)
	loadmodel.synctype = readi32(b, pinmodel + 72)
	BOUNDI(loadmodel.synctype, 0, 2)
	-- convert model flags to EF flags (MF_ROCKET becomes EF_ROCKET, etc)
	local i = readi32(b, pinmodel + 76)
	loadmodel.effects = aliaseffects(i)

	surfmesh.num_morphmdlframescale = { 0, 0, 0 }
	surfmesh.num_morphmdlframetranslate = { 0, 0, 0 }
	for k = 0, 2 do
		surfmesh.num_morphmdlframescale[k + 1] = readf32(b, pinmodel + 8 + k * 4)
		surfmesh.num_morphmdlframetranslate[k + 1] = readf32(b, pinmodel + 20 + k * 4)
	end

	startskins = datapointer
	totalskins = 0
	for _ = 0, loadmodel.numskins - 1 do
		local pinskintype = datapointer
		datapointer += 4 -- sizeof(daliasskintype_t)
		if readi32(b, pinskintype) == ALIAS_SKIN_SINGLE then
			groupskins = 1
		else
			local pinskingroup = datapointer
			datapointer += 4 -- sizeof(daliasskingroup_t)
			groupskins = readi32(b, pinskingroup)
			datapointer += 4 * groupskins -- sizeof(daliasskininterval_t) * groupskins
		end

		for _j = 0, groupskins - 1 do
			datapointer += skinwidth * skinheight
			totalskins += 1
		end
	end

	local pinstverts = datapointer
	datapointer += 12 * numverts -- sizeof(stvert_t) * numverts

	local pintriangles = datapointer
	datapointer += 16 * surfmesh.num_triangles -- sizeof(dtriangle_t)

	startframes = datapointer
	surfmesh.num_morphframes = 0
	for _ = 0, loadmodel.numframes - 1 do
		local pinframetype = datapointer
		datapointer += 4 -- sizeof(daliasframetype_t)
		if readi32(b, pinframetype) == ALIAS_SINGLE then
			groupframes = 1
		else
			local pinframegroup = datapointer
			datapointer += 12 -- sizeof(daliasgroup_t)
			groupframes = readi32(b, pinframegroup)
			datapointer += 4 * groupframes -- sizeof(daliasinterval_t) * groupframes
		end

		for _j = 0, groupframes - 1 do
			datapointer += 24 -- sizeof(daliasframe_t)
			datapointer += 4 * numverts -- sizeof(trivertx_t) * numverts
			surfmesh.num_morphframes += 1
		end
	end
	loadmodel.num_poses = surfmesh.num_morphframes

	-- store texture coordinates into temporary array, they will be stored
	-- after usage is determined (triangle data)
	local vertst = buffer.create(numverts * 2 * 8)
	local vertremap = buffer.create(numverts * 3 * 4)
	local vertonseam = numverts * 2 * 4 -- vertremap + numverts * 2 (byte offset)

	scales = R(1.0 / skinwidth)
	scalet = R(1.0 / skinheight)
	for v = 0, numverts - 1 do
		writei32(vertremap, vertonseam + v * 4, readi32(b, pinstverts + v * 12))
		writef32(vertst, v * 8, R(readi32(b, pinstverts + v * 12 + 4) * scales))
		writef32(vertst, v * 8 + 4, R(readi32(b, pinstverts + v * 12 + 8) * scalet))
		writef32(vertst, (v + numverts) * 8, readf32(vertst, v * 8) + 0.5)
		writef32(vertst, (v + numverts) * 8 + 4, readf32(vertst, v * 8 + 4))
	end

	-- load triangle data
	local nt = surfmesh.num_triangles
	surfmesh.data_element3i = buffer.create(12 * nt)
	local e3i: buffer = surfmesh.data_element3i

	-- read the triangle elements
	for t = 0, nt - 1 do
		for j = 0, 2 do
			writei32(e3i, (t * 3 + j) * 4, readi32(b, pintriangles + t * 16 + 4 + j * 4))
		end
	end
	-- validate (note numverts is used because this is the original data)
	model_shared.Mod_ValidateElements(e3i, 0, nt, 0, numverts, "model_alias.c", 1174)
	-- now butcher the elements according to vertonseam and tri->facesfront
	-- and then compact the vertex set to remove duplicates
	for t = 0, nt - 1 do
		if readi32(b, pintriangles + t * 16) == 0 then -- backface
			for j = 0, 2 do
				local o = (t * 3 + j) * 4
				if readi32(vertremap, vertonseam + readi32(e3i, o) * 4) ~= 0 then
					writei32(e3i, o, readi32(e3i, o) + numverts)
				end
			end
		end
	end
	-- count the usage
	-- (this uses vertremap to count usage to save some memory)
	for v = 0, numverts * 2 - 1 do
		writei32(vertremap, v * 4, 0)
	end
	for k = 0, nt * 3 - 1 do
		local o = readi32(e3i, k * 4) * 4
		writei32(vertremap, o, readi32(vertremap, o) + 1)
	end
	-- build remapping table and compact array
	surfmesh.num_vertices = 0
	for v = 0, numverts * 2 - 1 do
		if readi32(vertremap, v * 4) ~= 0 then
			writei32(vertremap, v * 4, surfmesh.num_vertices)
			writef32(vertst, surfmesh.num_vertices * 8, readf32(vertst, v * 8))
			writef32(vertst, surfmesh.num_vertices * 8 + 4, readf32(vertst, v * 8 + 4))
			surfmesh.num_vertices += 1
		else
			writei32(vertremap, v * 4, -1) -- not used at all
		end
	end
	-- remap the elements to the new vertex set
	for k = 0, nt * 3 - 1 do
		writei32(e3i, k * 4, readi32(vertremap, readi32(e3i, k * 4) * 4))
	end
	-- store the texture coordinates
	surfmesh.data_texcoordtexture2f = buffer.create(8 * surfmesh.num_vertices)
	buffer.copy(surfmesh.data_texcoordtexture2f, 0, vertst, 0, 8 * surfmesh.num_vertices)

	-- generate ushort elements array if possible
	if surfmesh.num_vertices <= 65536 then
		surfmesh.data_element3s = buffer.create(6 * nt)
	end
	copyelements3s(surfmesh)

	-- load the frames
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	surfmesh.data_morphmdlvertex = buffer.create(4 * surfmesh.num_morphframes * surfmesh.num_vertices)
	if cvi("r_enableshadowvolumes") ~= 0 then
		surfmesh.data_neighbor3i = buffer.create(12 * nt)
	end
	Mod_MDL_LoadFrames(b, startframes, numverts, vertremap)
	if surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, nt)
	end
	surfmesh.isanimated = Mod_Alias_CalculateBoundingBox()
	Mod_Alias_MorphMesh_CompileFrames()

	-- Mem_Free(vertst); Mem_Free(vertremap);

	-- load the skins
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if skinfiles then
		loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
		loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
		loadmodel.num_texturesperskin = loadmodel.num_surfaces
		loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
		model_alias.Mod_BuildAliasSkinsFromSkinFiles(loadmodel.data_textures, 0, skinfiles, "default", "")
		model_shared.Mod_FreeSkinFiles(skinfiles)
		for s = 0, loadmodel.numskins - 1 do
			local sc = loadmodel.skinscenes[s + 1]
			sc.firstframe = s
			sc.framecount = 1
			sc.loop = true
			sc.framerate = 10
		end
	else
		loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
		loadmodel.num_textures = loadmodel.num_surfaces * totalskins
		loadmodel.num_texturesperskin = loadmodel.num_surfaces
		loadmodel.data_textures = newtextures(loadmodel.num_surfaces * totalskins)
		totalskins = 0
		datapointer = startskins
		name = ""
		for s = 0, loadmodel.numskins - 1 do
			local pinskintype = datapointer
			datapointer += 4 -- sizeof(daliasskintype_t)

			if readi32(b, pinskintype) == ALIAS_SKIN_SINGLE then
				groupskins = 1
				interval = R(0.1)
			else
				local pinskingroup = datapointer
				datapointer += 4 -- sizeof(daliasskingroup_t)

				groupskins = readi32(b, pinskingroup)

				local pinskinintervals = datapointer
				datapointer += 4 * groupskins -- sizeof(daliasskininterval_t) * groupskins

				interval = readf32(b, pinskinintervals)
				if interval < R(0.01) then
					Con_Printf("%s has an invalid interval %f, changing to 0.1\n", loadmodel.name, interval)
					interval = R(0.1)
				end
			end

			local sc = loadmodel.skinscenes[s + 1]
			sc.name = string.sub(string.format("skin %d", s), 1, 31)
			sc.firstframe = totalskins
			sc.framecount = groupskins
			sc.framerate = R(1.0 / interval)
			sc.loop = true

			for j = 0, groupskins - 1 do
				if groupskins > 1 then
					name = string.sub(string.format("%s_%d_%d", loadmodel.name, s, j), 1, MAX_QPATH - 1)
				else
					name = string.sub(string.format("%s_%d", loadmodel.name, s), 1, MAX_QPATH - 1)
				end
				local tex = loadmodel.data_textures[totalskins * loadmodel.num_surfaces + 1]
				if not model_shared.Mod_LoadTextureFromQ3Shader(tex, name, false, true, skintexflags()) then
					Mod_BuildAliasSkinFromSkinFrame(
						tex,
						R_SkinFrame_LoadInternalQuake(
							name,
							bit32.bor(if cvi("r_mipskins") ~= 0 then TEXF_MIPMAP else 0, TEXF_PICMIP),
							true,
							cvi("r_fullbrights") ~= 0,
							b,
							datapointer,
							skinwidth,
							skinheight
						)
					)
				end
				datapointer += skinwidth * skinheight
				totalskins += 1
			end
		end
		-- check for skins that don't exist in the model, but do exist as external images
		-- (this was added because yummyluv kept pestering me about support for it)
		-- TODO: support shaders here?
		while true do
			-- va(vabuf, sizeof(vabuf), "%s_%i", loadmodel->name, loadmodel->numskins)
			local tempskinframe = R_SkinFrame_LoadExternal(
				string.sub(string.format("%s_%d", loadmodel.name, loadmodel.numskins), 1, 1023),
				skintexflags(),
				false
			)
			if not tempskinframe then
				break
			end
			-- expand the arrays to make room
			table.insert(loadmodel.skinscenes, newscene())
			for _ = 1, loadmodel.num_surfaces do
				table.insert(loadmodel.data_textures, newtexture(#loadmodel.data_textures))
			end

			-- store the info about the new skin
			Mod_BuildAliasSkinFromSkinFrame(
				loadmodel.data_textures[totalskins * loadmodel.num_surfaces + 1],
				tempskinframe
			)
			local sc = loadmodel.skinscenes[loadmodel.numskins + 1]
			sc.name = string.sub(name, 1, 31)
			sc.firstframe = totalskins
			sc.framecount = 1
			sc.framerate = 10.0
			sc.loop = true

			--increase skin counts
			loadmodel.num_textures += 1
			loadmodel.numskins += 1
			totalskins += 1

			-- fix up the pointers since they are pointing at the old textures array
			-- FIXME: this is a hack!
			for j = 0, loadmodel.numskins * loadmodel.num_surfaces - 1 do
				loadmodel.data_textures[j + 1].currentframe = loadmodel.data_textures[j + 1]
			end
		end
	end

	local surface = loadmodel.data_surfaces[1]
	surface.texture = loadmodel.data_textures[1]
	surface.num_firsttriangle = 0
	surface.num_triangles = nt
	surface.num_firstvertex = 0
	surface.num_vertices = surfmesh.num_vertices

	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	finishmodel(mod)
	checkunusualfeatures(mod)
end

-- port: model_alias.c Mod_IDP2_Load L1375-1645 @xonotic-v0.8.6
function model_alias.Mod_IDP2_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local numxyz, numst, xyz, st, skinwidth, skinheight, version, end_
	local iskinwidth, iskinheight
	local skinfiles

	local function L(o: number): number
		return readi32(b, o)
	end
	-- md2_t field offsets
	local num_skins, num_xyz, num_st, num_tris, num_frames = L(20), L(24), L(28), L(32), L(40)
	local ofs_skins, ofs_st, ofs_tris, ofs_frames, ofs_glcmds, ofs_end = L(44), L(48), L(52), L(56), L(60), L(64)

	version = L(4)
	if version ~= MD2ALIAS_VERSION then
		Host_Error("%s has wrong version number (%i should be %i)", loadmodel.name, version, MD2ALIAS_VERSION)
	end

	loadmodel.modeldatatypestring = "MD2"

	loadmodel.type = "mod_alias"
	setaliasdraw(loadmodel)
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_MDL_AnimateVertices

	if num_tris < 1 or num_tris > 65536 then
		Host_Error("%s has invalid number of triangles: %i", loadmodel.name, num_tris)
	end
	if num_xyz < 1 or num_xyz > 65536 then
		Host_Error("%s has invalid number of vertices: %i", loadmodel.name, num_xyz)
	end
	if num_frames < 1 or num_frames > 65536 then
		Host_Error("%s has invalid number of frames: %i", loadmodel.name, num_frames)
	end
	if num_skins < 0 or num_skins > 256 then
		Host_Error("%s has invalid number of skins: %i", loadmodel.name, num_skins)
	end

	end_ = ofs_end
	if num_skins >= 1 and (ofs_skins <= 0 or ofs_skins >= end_) then
		Host_Error("%s is not a valid model", loadmodel.name)
	end
	if ofs_st <= 0 or ofs_st >= end_ then
		Host_Error("%s is not a valid model", loadmodel.name)
	end
	if ofs_tris <= 0 or ofs_tris >= end_ then
		Host_Error("%s is not a valid model", loadmodel.name)
	end
	if ofs_frames <= 0 or ofs_frames >= end_ then
		Host_Error("%s is not a valid model", loadmodel.name)
	end
	if ofs_glcmds <= 0 or ofs_glcmds >= end_ then
		Host_Error("%s is not a valid model", loadmodel.name)
	end

	local surfmesh = loadmodel.surfmesh
	loadmodel.numskins = num_skins
	numxyz = num_xyz
	numst = num_st
	surfmesh.num_triangles = num_tris
	loadmodel.numframes = num_frames
	surfmesh.num_morphframes = loadmodel.numframes
	loadmodel.num_poses = surfmesh.num_morphframes
	skinwidth = L(8)
	skinheight = L(12)
	iskinwidth = R(1.0 / skinwidth)
	iskinheight = R(1.0 / skinheight)

	local nt = surfmesh.num_triangles
	loadmodel.num_surfaces = 1
	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces[1] = 0
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	surfmesh.data_morphmd2framesize6f = buffer.create(loadmodel.numframes * 24)
	surfmesh.data_element3i = buffer.create(nt * 12)
	if cvi("r_enableshadowvolumes") ~= 0 then
		surfmesh.data_neighbor3i = buffer.create(nt * 12)
	end
	local e3i: buffer = surfmesh.data_element3i

	loadmodel.synctype = ST_RAND

	-- load the skins
	local inskin = ofs_skins
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if skinfiles then
		loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
		loadmodel.num_texturesperskin = loadmodel.num_surfaces
		loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
		model_alias.Mod_BuildAliasSkinsFromSkinFiles(loadmodel.data_textures, 0, skinfiles, "default", "")
		model_shared.Mod_FreeSkinFiles(skinfiles)
	elseif loadmodel.numskins ~= 0 then
		-- skins found (most likely not a player model)
		loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
		loadmodel.num_texturesperskin = loadmodel.num_surfaces
		loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
		for s = 0, loadmodel.numskins - 1 do
			model_shared.Mod_LoadTextureFromQ3Shader(
				loadmodel.data_textures[s * loadmodel.num_surfaces + 1],
				cstr(b, inskin),
				true,
				true,
				skintexflags()
			)
			inskin += MD2_SKINNAME
		end
	else
		-- no skins (most likely a player model)
		loadmodel.numskins = 1
		loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
		loadmodel.num_texturesperskin = loadmodel.num_surfaces
		loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
		Mod_BuildAliasSkinFromSkinFrame(loadmodel.data_textures[1], nil)
	end

	loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
	for s = 0, loadmodel.numskins - 1 do
		local sc = loadmodel.skinscenes[s + 1]
		sc.firstframe = s
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	-- load the triangles and stvert data
	local inst = ofs_st
	local intri = ofs_tris
	-- struct md2verthash_s { next; unsigned short xyz; unsigned short st; }: chains of vertex numbers, newest
	-- first; hash(xyz, st) holds the vertex numbers of the chain md2verthash[hashindex]
	local md2verthash: { [number]: { number } } = {}
	local hashxyz = table.create(nt * 3, 0)
	local hashst = table.create(nt * 3, 0)
	-- swap the triangle list
	surfmesh.num_vertices = 0
	for t = 0, nt - 1 do
		for j = 0, 2 do
			xyz = readu16(b, intri + t * 12 + j * 2)
			st = readu16(b, intri + t * 12 + 6 + j * 2)
			if xyz >= numxyz then
				Con_Printf("%s has an invalid xyz index (%i) on triangle %i, resetting to 0\n", loadmodel.name, xyz, t)
				xyz = 0
			end
			if st >= numst then
				Con_Printf("%s has an invalid st index (%i) on triangle %i, resetting to 0\n", loadmodel.name, st, t)
				st = 0
			end
			local hashindex = bit32.band(xyz * 256 + st, 65535)
			local chain = md2verthash[hashindex]
			local found: number? = nil
			if chain then
				for c = #chain, 1, -1 do
					local h = chain[c]
					if hashxyz[h + 1] == xyz and hashst[h + 1] == st then
						found = h
						break
					end
				end
			end
			if found == nil then
				found = surfmesh.num_vertices
				surfmesh.num_vertices += 1
				hashxyz[(found :: number) + 1] = xyz
				hashst[(found :: number) + 1] = st
				if not chain then
					chain = {}
					md2verthash[hashindex] = chain
				end
				table.insert(chain :: { number }, found :: number)
			end
			writei32(e3i, (t * 3 + j) * 4, found :: number)
		end
	end

	local nv = surfmesh.num_vertices
	local vertremap = table.create(nv, 0)
	surfmesh.data_texcoordtexture2f = buffer.create(nv * 8)
	surfmesh.data_morphmdlvertex = buffer.create(nv * surfmesh.num_morphframes * 4)
	for v = 0, nv - 1 do
		vertremap[v + 1] = hashxyz[v + 1]
		local sts = readi16(b, inst + hashst[v + 1] * 4)
		local stt = readi16(b, inst + hashst[v + 1] * 4 + 2)
		if sts < 0 or sts >= skinwidth or stt < 0 or stt >= skinheight then
			Con_Printf(
				"%s has an invalid skin coordinate (%i %i) on vert %i, changing to 0 0\n",
				loadmodel.name,
				sts,
				stt,
				v
			)
			sts = 0
			stt = 0
		end
		writef32(surfmesh.data_texcoordtexture2f, v * 8, R(sts * iskinwidth))
		writef32(surfmesh.data_texcoordtexture2f, v * 8 + 4, R(stt * iskinheight))
	end

	-- generate ushort elements array if possible
	if nv <= 65536 then
		surfmesh.data_element3s = buffer.create(6 * nt)
	end
	copyelements3s(surfmesh)

	-- load the frames
	local datapointer = ofs_frames
	for f = 0, surfmesh.num_morphframes - 1 do
		local pinframe = datapointer
		datapointer += 40 -- sizeof(md2frame_t)
		-- store the frame scale/translate into the appropriate array
		for j = 0, 2 do
			writef32(surfmesh.data_morphmd2framesize6f, (f * 6 + j) * 4, readf32(b, pinframe + j * 4))
			writef32(surfmesh.data_morphmd2framesize6f, (f * 6 + 3 + j) * 4, readf32(b, pinframe + 12 + j * 4))
		end
		-- convert the vertices
		local outo = 4 * f * nv
		for k = 0, nv - 1 do
			buffer.copy(surfmesh.data_morphmdlvertex, outo + k * 4, b, datapointer + vertremap[k + 1] * 4, 4)
		end
		datapointer += numxyz * 4

		local sc = loadmodel.animscenes[f + 1]
		sc.name = cstr(b, pinframe + 24, 31)
		sc.firstframe = f
		sc.framecount = 1
		sc.framerate = 10
		sc.loop = true
	end

	if surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, nt)
	end
	surfmesh.isanimated = Mod_Alias_CalculateBoundingBox()
	Mod_Alias_MorphMesh_CompileFrames()
	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	local surface = loadmodel.data_surfaces[1]
	surface.texture = loadmodel.data_textures[1]
	surface.num_firsttriangle = 0
	surface.num_triangles = nt
	surface.num_firstvertex = 0
	surface.num_vertices = nv

	finishmodel(mod)
	checkunusualfeatures(mod)
end

-- port: model_alias.c Mod_IDP3_Load L1647-1841 @xonotic-v0.8.6
function model_alias.Mod_IDP3_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local version, meshvertices, meshtriangles
	local skinfiles

	local pinmodel = 0

	if buffer.readstring(b, pinmodel, 4) ~= "IDP3" then
		Host_Error("%s is not a MD3 (IDP3) file", loadmodel.name)
	end
	version = readi32(b, pinmodel + 4)
	if version ~= MD3VERSION then
		Host_Error("%s has wrong version number (%i should be %i)", loadmodel.name, version, MD3VERSION)
	end

	local surfmesh = loadmodel.surfmesh
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if (loadmodel.numskins or 0) < 1 then
		loadmodel.numskins = 1
	end

	loadmodel.modeldatatypestring = "MD3"

	loadmodel.type = "mod_alias"
	setaliasdraw(loadmodel)
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_MD3_AnimateVertices
	loadmodel.synctype = ST_RAND
	-- convert model flags to EF flags (MF_ROCKET becomes EF_ROCKET, etc)
	loadmodel.effects = aliaseffects(readi32(b, pinmodel + 72))

	-- set up some global info about the model
	loadmodel.numframes = readi32(b, pinmodel + 76)
	loadmodel.num_surfaces = readi32(b, pinmodel + 84)

	-- make skinscenes for the skins (no groups)
	loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
	for i = 0, loadmodel.numskins - 1 do
		local sc = loadmodel.skinscenes[i + 1]
		sc.firstframe = i
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	-- load frameinfo
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	local pinframe = readi32(b, pinmodel + 92) -- lump_frameinfo
	for i = 0, loadmodel.numframes - 1 do
		local sc = loadmodel.animscenes[i + 1]
		sc.name = cstr(b, pinframe + 40, 31) -- strlcpy(name, pinframe->name, sizeof(name))
		sc.firstframe = i
		sc.framecount = 1
		sc.framerate = 10
		sc.loop = true
		pinframe += 56 -- sizeof(md3frameinfo_t)
	end

	-- load tags
	loadmodel.num_tagframes = loadmodel.numframes
	loadmodel.num_tags = readi32(b, pinmodel + 80)
	local ntags = loadmodel.num_tagframes * loadmodel.num_tags
	loadmodel.data_tags = table.create(ntags)
	local pintag = readi32(b, pinmodel + 96) -- lump_tags
	for i = 0, ntags - 1 do
		local matrixgl = table.create(12, 0)
		for j = 0, 8 do
			matrixgl[j + 1] = readf32(b, pintag + 76 + j * 4)
		end
		for j = 0, 2 do
			matrixgl[9 + j + 1] = readf32(b, pintag + 64 + j * 4)
		end
		loadmodel.data_tags[i + 1] = { name = cstr(b, pintag, 63), matrixgl = matrixgl }
		--Con_Printf("model \"%s\" frame #%i tag #%i \"%s\"\n", loadmodel->name, i / loadmodel->num_tags, i % loadmodel->num_tags, loadmodel->data_tags[i].name);
		pintag += 112 -- sizeof(md3tag_t)
	end

	-- load meshes
	meshvertices = 0
	meshtriangles = 0
	local lump_meshes = readi32(b, pinmodel + 100)
	local pinmesh = lump_meshes
	for _ = 0, loadmodel.num_surfaces - 1 do
		if buffer.readstring(b, pinmesh, 4) ~= "IDP3" then
			Host_Error("Mod_IDP3_Load: invalid mesh identifier (not IDP3)")
		end
		if readi32(b, pinmesh + 72) ~= loadmodel.numframes then
			Host_Error("Mod_IDP3_Load: mesh numframes differs from header")
		end
		meshvertices += readi32(b, pinmesh + 80)
		meshtriangles += readi32(b, pinmesh + 84)
		pinmesh += readi32(b, pinmesh + 104) -- lump_end
	end

	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
	loadmodel.num_texturesperskin = loadmodel.num_surfaces
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
	surfmesh.num_vertices = meshvertices
	surfmesh.num_triangles = meshtriangles
	surfmesh.num_morphframes = loadmodel.numframes -- TODO: remove?
	loadmodel.num_poses = surfmesh.num_morphframes
	surfmesh.data_element3i = buffer.create(meshtriangles * 12)
	if cvi("r_enableshadowvolumes") ~= 0 then
		surfmesh.data_neighbor3i = buffer.create(meshtriangles * 12)
	end
	surfmesh.data_texcoordtexture2f = buffer.create(meshvertices * 8)
	surfmesh.data_morphmd3vertex = buffer.create(meshvertices * loadmodel.numframes * 8)
	if meshvertices <= 65536 then
		surfmesh.data_element3s = buffer.create(meshtriangles * 6)
	end
	local e3i: buffer = surfmesh.data_element3i
	local tc: buffer = surfmesh.data_texcoordtexture2f
	local md3: buffer = surfmesh.data_morphmd3vertex

	meshvertices = 0
	meshtriangles = 0
	pinmesh = lump_meshes
	for i = 0, loadmodel.num_surfaces - 1 do
		if buffer.readstring(b, pinmesh, 4) ~= "IDP3" then
			Host_Error("Mod_IDP3_Load: invalid mesh identifier (not IDP3)")
		end
		loadmodel.sortedmodelsurfaces[i + 1] = i
		local surface = loadmodel.data_surfaces[i + 1]
		surface.texture = loadmodel.data_textures[i + 1]
		surface.num_firsttriangle = meshtriangles
		surface.num_triangles = readi32(b, pinmesh + 84)
		surface.num_firstvertex = meshvertices
		surface.num_vertices = readi32(b, pinmesh + 80)
		meshvertices += surface.num_vertices
		meshtriangles += surface.num_triangles

		local lump_elements = pinmesh + readi32(b, pinmesh + 88)
		for j = 0, surface.num_triangles * 3 - 1 do
			writei32(
				e3i,
				(j + surface.num_firsttriangle * 3) * 4,
				int32(surface.num_firstvertex + readi32(b, lump_elements + j * 4))
			)
		end
		local lump_texcoords = pinmesh + readi32(b, pinmesh + 96)
		for j = 0, surface.num_vertices - 1 do
			writef32(tc, (j + surface.num_firstvertex) * 8, readf32(b, lump_texcoords + j * 8))
			writef32(tc, (j + surface.num_firstvertex) * 8 + 4, readf32(b, lump_texcoords + j * 8 + 4))
		end
		local lump_framevertices = pinmesh + readi32(b, pinmesh + 100)
		for j = 0, loadmodel.numframes - 1 do
			local in_ = lump_framevertices + j * surface.num_vertices * 8
			local out = (surface.num_firstvertex + j * surfmesh.num_vertices) * 8
			for _k = 0, surface.num_vertices - 1 do
				writei16(md3, out, readi16(b, in_))
				writei16(md3, out + 2, readi16(b, in_ + 2))
				writei16(md3, out + 4, readi16(b, in_ + 4))
				writeu8(md3, out + 6, readu8(b, in_ + 6)) -- pitch
				writeu8(md3, out + 7, readu8(b, in_ + 7)) -- yaw
				in_ += 8
				out += 8
			end
		end

		local shadername = ""
		if readi32(b, pinmesh + 76) >= 1 then -- num_shaders
			shadername = cstr(b, pinmesh + readi32(b, pinmesh + 92)) -- ((md3shader_t *)(pinmesh + lump_shaders))->name
		end
		model_alias.Mod_BuildAliasSkinsFromSkinFiles(
			loadmodel.data_textures,
			i,
			skinfiles,
			cstr(b, pinmesh + 4),
			shadername
		)

		model_shared.Mod_ValidateElements(
			e3i,
			surface.num_firsttriangle * 12,
			surface.num_triangles,
			surface.num_firstvertex,
			surface.num_vertices,
			"model_alias.c",
			1808
		)
		pinmesh += readi32(b, pinmesh + 104) -- lump_end
	end
	copyelements3s(surfmesh)
	if surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, surfmesh.num_triangles)
	end
	Mod_Alias_MorphMesh_CompileFrames()
	surfmesh.isanimated = Mod_Alias_CalculateBoundingBox()
	model_shared.Mod_FreeSkinFiles(skinfiles)
	model_shared.Mod_MakeSortedSurfaces(loadmodel)
	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	finishmodel(mod)
	checkunusualfeatures(mod)
end

-- the poses of DPM / ZYM files: float pose[12] matrices (big-endian) of one frame, normalized and stored as
-- bone poses (the loop bodies of Mod_ZYMOTICMODEL_Load L2065-2090 and Mod_DARKPLACESMODEL_Load L2432-2455)
local function storeposes(b: buffer, frameposes: number, frame: number, modelscale: number)
	local loadmodel = model_shared.loadmodel
	local pose = buffer.create(48)
	local posematrix = matrixlib.new()
	local function VectorNormalize(o: number)
		local x, y, z = readf32(pose, o), readf32(pose, o + 4), readf32(pose, o + 8)
		local ilength = R(math.sqrt(R(R(R(x * x) + R(y * y)) + R(z * z))))
		if ilength ~= 0 then
			ilength = R(1.0 / ilength)
		end
		writef32(pose, o, x * ilength)
		writef32(pose, o + 4, y * ilength)
		writef32(pose, o + 8, z * ilength)
	end
	for j = 0, loadmodel.num_bones - 1 do
		for k = 0, 11 do
			writef32(pose, k * 4, BigFloat(b, frameposes + (j * 12 + k) * 4))
		end
		-- scale child bones to match the root scale
		if loadmodel.data_bones[j + 1].parent >= 0 then
			writef32(pose, 12, readf32(pose, 12) * modelscale)
			writef32(pose, 28, readf32(pose, 28) * modelscale)
			writef32(pose, 44, readf32(pose, 44) * modelscale)
		end
		-- normalize rotation matrix
		VectorNormalize(0)
		VectorNormalize(16)
		VectorNormalize(32)
		matrixlib.Matrix4x4_FromArray12FloatD3D(posematrix, pose, 0)
		matrixlib.Matrix4x4_ToBonePose7s(
			posematrix,
			loadmodel.num_poseinvscale,
			loadmodel.data_poses7s,
			14 * (frame * loadmodel.num_bones + j)
		)
	end
end

-- reconstruct frame 0 matrices (float bonepose[num_bones][12]) from the big-endian poses at byte `poses`
local function framezerobonepose(b: buffer, poses: number): buffer
	local loadmodel = model_shared.loadmodel
	local bonepose = buffer.create(loadmodel.num_bones * 48)
	local m = buffer.create(48)
	for i = 0, loadmodel.num_bones - 1 do
		for k = 0, 11 do
			writef32(m, k * 4, BigFloat(b, poses + (i * 12 + k) * 4))
		end
		local parent = loadmodel.data_bones[i + 1].parent
		if parent >= 0 then
			R_ConcatTransforms(bonepose, 48 * parent, m, 0, bonepose, 48 * i)
		else
			buffer.copy(bonepose, 48 * i, m, 0, 48)
		end
	end
	return bonepose
end

-- VectorLength (mathlib.h) of the 3 big-endian floats at o, stored in a float
local function bigvectorlength(b: buffer, o: number): number
	local x, y, z = BigFloat(b, o), BigFloat(b, o + 4), BigFloat(b, o + 8)
	return R(math.sqrt(R(R(R(x * x) + R(y * y)) + R(z * z))))
end

-- the skeletal surfmesh arrays (allocated as one zeroed chunk in C)
local function allocskeletal(surfmesh: any, meshvertices: number, meshtriangles: number)
	surfmesh.data_element3i = buffer.create(meshtriangles * 12)
	if cvi("r_enableshadowvolumes") ~= 0 then
		surfmesh.data_neighbor3i = buffer.create(meshtriangles * 12)
	end
	surfmesh.data_vertex3f = buffer.create(meshvertices * 12)
	surfmesh.data_svector3f = buffer.create(meshvertices * 12)
	surfmesh.data_tvector3f = buffer.create(meshvertices * 12)
	surfmesh.data_normal3f = buffer.create(meshvertices * 12)
	surfmesh.data_texcoordtexture2f = buffer.create(meshvertices * 8)
end

-- port: model_alias.c Mod_ZYMOTICMODEL_Load L1843-2242 @xonotic-v0.8.6
function model_alias.Mod_ZYMOTICMODEL_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local numposes, meshvertices, meshtriangles, count
	local modelradius
	local biggestorigin, modelscale
	local skinfiles

	local pbase = 0
	if buffer.readstring(b, 0, 12) ~= "ZYMOTICMODEL" then
		Host_Error("Mod_ZYMOTICMODEL_Load: %s is not a zymotic model", loadmodel.name)
	end
	if BigLong(b, 12) ~= 1 then
		Host_Error(
			"Mod_ZYMOTICMODEL_Load: only type 1 (skeletal pose) models are currently supported (name = %s)",
			loadmodel.name
		)
	end

	loadmodel.modeldatatypestring = "ZYM"

	loadmodel.type = "mod_alias"
	loadmodel.synctype = ST_RAND

	-- byteswap header
	local ph = {
		type = BigLong(b, 12),
		filesize = BigLong(b, 16),
		mins = { BigFloat(b, 20), BigFloat(b, 24), BigFloat(b, 28) },
		maxs = { BigFloat(b, 32), BigFloat(b, 36), BigFloat(b, 40) },
		radius = BigFloat(b, 44),
		numverts = BigLong(b, 48),
		numtris = BigLong(b, 52),
		numshaders = BigLong(b, 56),
		numbones = BigLong(b, 60),
		numscenes = BigLong(b, 64),
	}
	local function lump(o: number): { start: number, length: number }
		return { start = BigLong(b, o), length = BigLong(b, o + 4) }
	end
	local lump_scenes, lump_poses, lump_bones = lump(68), lump(76), lump(84)
	local lump_vertbonecounts, lump_verts, lump_texcoords = lump(92), lump(100), lump(108)
	local lump_render, lump_shaders, _lump_trizone = lump(116), lump(124), lump(132)

	if ph.numtris < 1 or ph.numverts < 3 or ph.numshaders < 1 then
		Con_Printf("%s has no geometry\n", loadmodel.name)
		return
	end
	if ph.numscenes < 1 or lump_poses.length < 48 then -- (int)sizeof(float[3][4])
		Con_Printf("%s has no animations\n", loadmodel.name)
		return
	end

	setaliasdraw(loadmodel)
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_Skeletal_AnimateVertices

	loadmodel.numframes = ph.numscenes
	loadmodel.num_surfaces = ph.numshaders

	local surfmesh = loadmodel.surfmesh
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if (loadmodel.numskins or 0) < 1 then
		loadmodel.numskins = 1
	end

	-- make skinscenes for the skins (no groups)
	loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
	for i = 0, loadmodel.numskins - 1 do
		local sc = loadmodel.skinscenes[i + 1]
		sc.firstframe = i
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	-- model bbox
	-- LordHavoc: actually we blow this away later with Mod_Alias_CalculateBoundingBox()
	modelradius = ph.radius
	loadmodel.normalmins = { ph.mins[1], ph.mins[2], ph.mins[3] }
	loadmodel.normalmaxs = { ph.maxs[1], ph.maxs[2], ph.maxs[3] }
	loadmodel.rotatedmins = { -modelradius, -modelradius, -modelradius }
	loadmodel.rotatedmaxs = { modelradius, modelradius, modelradius }
	local function fmax(a: number, c: number): number
		return if a > c then a else c
	end
	local corner0 = fmax(math.abs(loadmodel.normalmins[1]), math.abs(loadmodel.normalmaxs[1]))
	local corner1 = fmax(math.abs(loadmodel.normalmins[2]), math.abs(loadmodel.normalmaxs[2]))
	local y = R(math.sqrt(R(R(corner0 * corner0) + R(corner1 * corner1))))
	if y > modelradius then
		y = modelradius
	end
	loadmodel.yawmaxs = { y, y, loadmodel.normalmaxs[3] }
	loadmodel.yawmins = { -y, -y, loadmodel.normalmins[3] }
	loadmodel.radius = modelradius
	loadmodel.radius2 = R(modelradius * modelradius)

	-- go through the lumps, swapping things

	--zymlump_t lump_scenes; // zymscene_t scene[numscenes]; // name and other information for each scene (see zymscene struct)
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	local scene = lump_scenes.start + pbase
	numposes = lump_poses.length // ph.numbones // 48
	for i = 0, ph.numscenes - 1 do
		local sc = loadmodel.animscenes[i + 1]
		sc.name = cstr(b, scene, 32) -- memcpy(name, scene->name, 32)
		sc.firstframe = BigLong(b, scene + 68)
		sc.framecount = BigLong(b, scene + 72)
		sc.framerate = BigFloat(b, scene + 60)
		sc.loop = bit32.band(BigLong(b, scene + 64), ZYMSCENEFLAG_NOLOOP) == 0
		if sc.firstframe % 4294967296 >= numposes % 4294967296 then
			Host_Error("%s scene->firstframe (%i) >= numposes (%i)", loadmodel.name, sc.firstframe, numposes)
		end
		if (sc.firstframe % 4294967296 + sc.framecount % 4294967296) % 4294967296 > numposes % 4294967296 then
			Host_Error(
				"%s scene->firstframe (%i) + framecount (%i) >= numposes (%i)",
				loadmodel.name,
				sc.firstframe,
				sc.framecount,
				numposes
			)
		end
		if sc.framerate < 0 then
			Host_Error("%s scene->framerate (%f) < 0", loadmodel.name, sc.framerate)
		end
		scene += 76 -- sizeof(zymscene_t)
	end

	--zymlump_t lump_bones; // zymbone_t bone[numbones];
	loadmodel.num_bones = ph.numbones
	loadmodel.data_bones = table.create(loadmodel.num_bones)
	local bone = lump_bones.start + pbase
	for i = 0, ph.numbones - 1 do
		local bo = bone + i * 40
		loadmodel.data_bones[i + 1] = {
			name = cstr(b, bo, 32), -- memcpy(name, bone[i].name, sizeof(bone[i].name))
			flags = BigLong(b, bo + 32),
			parent = BigLong(b, bo + 36),
		}
		if loadmodel.data_bones[i + 1].parent >= i then
			Host_Error("%s bone[%i].parent >= %i", loadmodel.name, i, i)
		end
	end

	--zymlump_t lump_vertbonecounts; // int vertbonecounts[numvertices]; // how many bones influence each vertex (separate mainly to make this compress better)
	local bonecount = lump_vertbonecounts.start + pbase
	for i = 0, ph.numverts - 1 do
		local c = BigLong(b, bonecount + i * 4)
		if c ~= 1 then
			Host_Error("%s bonecount[%i] != 1 (vertex weight support is impossible in this format)", loadmodel.name, i)
		end
	end

	loadmodel.num_poses = lump_poses.length // 48 // loadmodel.num_bones

	meshvertices = ph.numverts
	meshtriangles = ph.numtris

	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
	loadmodel.num_texturesperskin = loadmodel.num_surfaces
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
	surfmesh.num_vertices = meshvertices
	surfmesh.num_triangles = meshtriangles
	allocskeletal(surfmesh, meshvertices, meshtriangles)
	surfmesh.data_skeletalindex4ub = buffer.create(meshvertices * 4)
	surfmesh.data_skeletalweight4ub = buffer.create(meshvertices * 4)
	loadmodel.data_baseboneposeinverse = buffer.create(loadmodel.num_bones * 48)
	surfmesh.num_blends = 0
	surfmesh.blends = buffer.create(meshvertices * 2)
	if surfmesh.num_vertices <= 65536 then
		surfmesh.data_element3s = buffer.create(surfmesh.num_triangles * 6)
	end
	loadmodel.data_poses7s = buffer.create(loadmodel.num_poses * loadmodel.num_bones * 14)
	surfmesh.data_blendweights = nil

	--zymlump_t lump_poses; // float pose[numposes][numbones][3][4]; // animation data
	local poses = lump_poses.start + pbase
	-- figure out scale of model from root bone, for compatibility with old zmodel versions
	modelscale = bigvectorlength(b, poses)
	biggestorigin = 0
	for i = 0, loadmodel.num_bones * numposes * 12 - 1 do
		local f = math.abs(BigFloat(b, poses + i * 4))
		biggestorigin = if biggestorigin > f then biggestorigin else f
	end
	loadmodel.num_posescale = R(biggestorigin / 32767.0)
	loadmodel.num_poseinvscale = R(1.0 / loadmodel.num_posescale)
	for i = 0, numposes - 1 do
		storeposes(b, lump_poses.start + pbase + 48 * i * loadmodel.num_bones, i, modelscale)
	end

	--zymlump_t lump_verts; // zymvertex_t vert[numvertices]; // see vertex struct
	local vertdata = lump_verts.start + pbase
	-- reconstruct frame 0 matrices to allow reconstruction of the base mesh
	-- (converting from weight-blending skeletal animation to
	--  deformation-based skeletal animation)
	local bonepose = framezerobonepose(b, poses)
	local v3f: buffer = surfmesh.data_vertex3f
	for j = 0, ph.numverts - 1 do
		-- this format really should have had a per vertexweight weight value...
		-- but since it does not, the weighting is completely ignored and
		-- only one weight is allowed per vertex
		local vo = vertdata + j * 16
		local boneindex = BigLong(b, vo)
		local m = 48 * boneindex
		local r0, r1, r2 = BigFloat(b, vo + 4), BigFloat(b, vo + 8), BigFloat(b, vo + 12)
		local function row(r: number): number
			local ro = m + r * 16
			return R(
				R(
					R(R(r0 * readf32(bonepose, ro)) + R(r1 * readf32(bonepose, ro + 4)))
						+ R(r2 * readf32(bonepose, ro + 8))
				) + readf32(bonepose, ro + 12)
			)
		end
		-- transform the vertex bone weight into the base mesh
		writef32(v3f, j * 12, row(0))
		writef32(v3f, j * 12 + 4, row(1))
		writef32(v3f, j * 12 + 8, row(2))
		-- store the weight as the primary weight on this vertex
		writeu16(surfmesh.blends, j * 2, boneindex % 65536)
		writeu8(surfmesh.data_skeletalindex4ub, j * 4, boneindex % 256)
		writeu8(surfmesh.data_skeletalindex4ub, j * 4 + 1, 0)
		writeu8(surfmesh.data_skeletalindex4ub, j * 4 + 2, 0)
		writeu8(surfmesh.data_skeletalindex4ub, j * 4 + 3, 0)
		writeu8(surfmesh.data_skeletalweight4ub, j * 4, 255)
		writeu8(surfmesh.data_skeletalweight4ub, j * 4 + 1, 0)
		writeu8(surfmesh.data_skeletalweight4ub, j * 4 + 2, 0)
		writeu8(surfmesh.data_skeletalweight4ub, j * 4 + 3, 0)
	end
	-- Z_Free(bonepose);
	-- normals and tangents are calculated after elements are loaded

	--zymlump_t lump_texcoords; // float texcoords[numvertices][2];
	local outtexcoord2f: buffer = surfmesh.data_texcoordtexture2f
	local intexcoord2f = lump_texcoords.start + pbase
	for i = 0, ph.numverts - 1 do
		writef32(outtexcoord2f, i * 8, BigFloat(b, intexcoord2f + i * 8))
		-- flip T coordinate for OpenGL
		writef32(outtexcoord2f, i * 8 + 4, R(1 - BigFloat(b, intexcoord2f + i * 8 + 4)))
	end

	--zymlump_t lump_trizone; // byte trizone[numtris]; // see trizone explanation
	--loadmodel->alias.zymdata_trizone = Mem_Alloc(loadmodel->mempool, pheader->numtris);
	--memcpy(loadmodel->alias.zymdata_trizone, (void *) (pheader->lump_trizone.start + pbase), pheader->numtris);

	--zymlump_t lump_shaders; // char shadername[numshaders][32]; // shaders used on this model
	--zymlump_t lump_render; // int renderlist[rendersize]; // sorted by shader with run lengths (int count), shaders are sequentially used, each run can be used with glDrawElements (each triangle is 3 int indices)
	-- byteswap, validate, and swap winding order of tris
	count = ph.numshaders * 4 + ph.numtris * 12
	if lump_render.length ~= count then
		Host_Error(
			"%s renderlist is wrong size (%i bytes, should be %i bytes)",
			loadmodel.name,
			lump_render.length,
			count
		)
	end
	local renderlist = lump_render.start + pbase
	local renderlistend = renderlist + lump_render.length
	local e3i: buffer = surfmesh.data_element3i
	meshtriangles = 0
	for i = 0, loadmodel.num_surfaces - 1 do
		local firstvertex, lastvertex
		if renderlist >= renderlistend then
			Host_Error("%s corrupt renderlist (wrong size)", loadmodel.name)
		end
		count = BigLong(b, renderlist)
		renderlist += 4
		if
			renderlist + count * 12 > renderlistend
			or (i == ph.numshaders - 1 and renderlist + count * 12 ~= renderlistend)
		then
			Host_Error("%s corrupt renderlist (wrong size)", loadmodel.name)
		end

		loadmodel.sortedmodelsurfaces[i + 1] = i
		local surface = loadmodel.data_surfaces[i + 1]
		surface.texture = loadmodel.data_textures[i + 1]
		surface.num_firsttriangle = meshtriangles
		surface.num_triangles = count
		meshtriangles += surface.num_triangles

		-- load the elements
		local outelements = surface.num_firsttriangle * 12
		for j = 0, surface.num_triangles - 1 do
			writei32(e3i, outelements + (j * 3 + 2) * 4, BigLong(b, renderlist))
			writei32(e3i, outelements + (j * 3 + 1) * 4, BigLong(b, renderlist + 4))
			writei32(e3i, outelements + (j * 3 + 0) * 4, BigLong(b, renderlist + 8))
			renderlist += 12
		end
		-- validate the elements and find the used vertex range
		firstvertex = meshvertices
		lastvertex = 0
		for j = 0, surface.num_triangles * 3 - 1 do
			local e = readi32(e3i, outelements + j * 4)
			if e % 4294967296 >= meshvertices % 4294967296 then
				Host_Error("%s corrupt renderlist (out of bounds index)", loadmodel.name)
			end
			firstvertex = if firstvertex < e then firstvertex else e
			lastvertex = if lastvertex > e then lastvertex else e
		end
		surface.num_firstvertex = firstvertex
		surface.num_vertices = lastvertex + 1 - firstvertex

		-- since zym models do not have named sections, reuse their shader
		-- name as the section name
		local shadername = cstr(b, lump_shaders.start + pbase + i * 32)
		model_alias.Mod_BuildAliasSkinsFromSkinFiles(loadmodel.data_textures, i, skinfiles, shadername, shadername)
	end
	model_shared.Mod_FreeSkinFiles(skinfiles)
	-- Mem_Free(vertbonecounts); Mem_Free(verts);
	model_shared.Mod_MakeSortedSurfaces(loadmodel)

	-- compute all the mesh information that was not loaded from the file
	copyelements3s(surfmesh)
	model_shared.Mod_ValidateElements(e3i, 0, surfmesh.num_triangles, 0, surfmesh.num_vertices, "model_alias.c", 2213)
	Mod_BuildBaseBonePoses()
	local areaweighting = cvi("r_smoothnormals_areaweighting") ~= 0
	model_shared.Mod_BuildNormals(
		0,
		surfmesh.num_vertices,
		surfmesh.num_triangles,
		surfmesh.data_vertex3f,
		e3i,
		0,
		surfmesh.data_normal3f,
		areaweighting
	)
	model_shared.Mod_BuildTextureVectorsFromNormals(
		0,
		surfmesh.num_vertices,
		surfmesh.num_triangles,
		surfmesh.data_vertex3f,
		surfmesh.data_texcoordtexture2f,
		surfmesh.data_normal3f,
		e3i,
		0,
		surfmesh.data_svector3f,
		surfmesh.data_tvector3f,
		areaweighting
	)
	if surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, surfmesh.num_triangles)
	end
	surfmesh.isanimated = Mod_Alias_CalculateBoundingBox()
	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	finishmodel(mod)
	checkunusualfeatures(mod)
end

-- port: model_alias.c Mod_DARKPLACESMODEL_Load L2244-2621 @xonotic-v0.8.6
function model_alias.Mod_DARKPLACESMODEL_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local meshvertices, meshtriangles
	local skinfiles
	local biggestorigin, modelscale

	local pbase = 0
	if buffer.readstring(b, 0, 16) ~= "DARKPLACESMODEL\0" then
		Host_Error("Mod_DARKPLACESMODEL_Load: %s is not a darkplaces model", loadmodel.name)
	end
	if BigULong(b, 16) ~= 2 then
		Host_Error(
			"Mod_DARKPLACESMODEL_Load: only type 2 (hierarchical skeletal pose) models are currently supported (name = %s)",
			loadmodel.name
		)
	end

	loadmodel.modeldatatypestring = "DPM"

	loadmodel.type = "mod_alias"
	loadmodel.synctype = ST_RAND

	-- byteswap header
	local ph = {
		type = BigULong(b, 16),
		filesize = BigULong(b, 20),
		mins = { BigFloat(b, 24), BigFloat(b, 28), BigFloat(b, 32) },
		maxs = { BigFloat(b, 36), BigFloat(b, 40), BigFloat(b, 44) },
		yawradius = BigFloat(b, 48),
		allradius = BigFloat(b, 52),
		num_bones = BigULong(b, 56),
		num_meshs = BigULong(b, 60),
		num_frames = BigULong(b, 64),
		ofs_bones = BigULong(b, 68),
		ofs_meshs = BigULong(b, 72),
		ofs_frames = BigULong(b, 76),
	}

	if ph.num_bones < 1 or ph.num_meshs < 1 then
		Con_Printf("%s has no geometry\n", loadmodel.name)
		return
	end
	if ph.num_frames < 1 then
		Con_Printf("%s has no frames\n", loadmodel.name)
		return
	end

	setaliasdraw(loadmodel)
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_Skeletal_AnimateVertices

	-- model bbox
	-- LordHavoc: actually we blow this away later with Mod_Alias_CalculateBoundingBox()
	loadmodel.normalmins = { 0, 0, 0 }
	loadmodel.normalmaxs = { 0, 0, 0 }
	loadmodel.yawmins = { 0, 0, 0 }
	loadmodel.yawmaxs = { 0, 0, 0 }
	loadmodel.rotatedmins = { 0, 0, 0 }
	loadmodel.rotatedmaxs = { 0, 0, 0 }
	for i = 1, 3 do
		loadmodel.normalmins[i] = ph.mins[i]
		loadmodel.normalmaxs[i] = ph.maxs[i]
		loadmodel.yawmins[i] = if i ~= 3 then -ph.yawradius else ph.mins[i]
		loadmodel.yawmaxs[i] = if i ~= 3 then ph.yawradius else ph.maxs[i]
		loadmodel.rotatedmins[i] = -ph.allradius
		loadmodel.rotatedmaxs[i] = ph.allradius
	end
	loadmodel.radius = ph.allradius
	loadmodel.radius2 = R(ph.allradius * ph.allradius)

	-- load external .skin files if present
	local surfmesh = loadmodel.surfmesh
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if (loadmodel.numskins or 0) < 1 then
		loadmodel.numskins = 1
	end

	meshvertices = 0
	meshtriangles = 0

	-- gather combined statistics from the meshes
	local dpmmesh = pbase + ph.ofs_meshs
	for _ = 0, ph.num_meshs - 1 do
		local numverts = BigLong(b, dpmmesh + 32)
		meshvertices += numverts
		meshtriangles += BigLong(b, dpmmesh + 36)
		dpmmesh += 56 -- sizeof(dpmmesh_t)
	end

	loadmodel.numframes = ph.num_frames
	loadmodel.num_bones = ph.num_bones
	loadmodel.num_poses = loadmodel.numframes
	loadmodel.num_surfaces = ph.num_meshs
	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
	loadmodel.num_texturesperskin = loadmodel.num_surfaces
	-- do most allocations as one merged chunk
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
	surfmesh.num_vertices = meshvertices
	surfmesh.num_triangles = meshtriangles
	allocskeletal(surfmesh, meshvertices, meshtriangles)
	surfmesh.data_skeletalindex4ub = buffer.create(meshvertices * 4)
	surfmesh.data_skeletalweight4ub = buffer.create(meshvertices * 4)
	loadmodel.data_baseboneposeinverse = buffer.create(loadmodel.num_bones * 48)
	loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
	loadmodel.data_bones = table.create(loadmodel.num_bones)
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	surfmesh.num_blends = 0
	surfmesh.blends = buffer.create(meshvertices * 2)
	if meshvertices <= 65536 then
		surfmesh.data_element3s = buffer.create(meshtriangles * 6)
	end
	loadmodel.data_poses7s = buffer.create(loadmodel.num_poses * loadmodel.num_bones * 14)
	surfmesh.data_blendweights = buffer.create(meshvertices * 8)

	for i = 0, loadmodel.numskins - 1 do
		local sc = loadmodel.skinscenes[i + 1]
		sc.firstframe = i
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	-- load the bone info
	local bone = pbase + ph.ofs_bones
	for i = 0, loadmodel.num_bones - 1 do
		local bo = bone + i * 40
		loadmodel.data_bones[i + 1] = {
			name = cstr(b, bo, 32), -- memcpy(name, bone[i].name, sizeof(bone[i].name))
			flags = BigLong(b, bo + 36),
			parent = BigLong(b, bo + 32),
		}
		if loadmodel.data_bones[i + 1].parent >= i then
			Host_Error("%s bone[%i].parent >= %i", loadmodel.name, i, i)
		end
	end

	-- load the frames
	local frames = pbase + ph.ofs_frames
	local function frameposes(i: number): number
		return pbase + BigLong(b, frames + i * 68 + 64) -- frames[i].ofs_bonepositions
	end
	-- figure out scale of model from root bone, for compatibility with old dpmodel versions
	local poses = frameposes(0)
	modelscale = bigvectorlength(b, poses)
	biggestorigin = 0
	for i = 0, loadmodel.numframes - 1 do
		local sc = loadmodel.animscenes[i + 1]
		sc.name = cstr(b, frames + i * 68, 32) -- memcpy(name, frames[i].name, sizeof(frames[i].name))
		sc.firstframe = i
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
		-- load the bone poses for this frame
		poses = frameposes(i)
		for j = 0, loadmodel.num_bones * 12 - 1 do
			local f = math.abs(BigFloat(b, poses + j * 4))
			biggestorigin = if biggestorigin > f then biggestorigin else f
		end
		-- stuff not processed here: mins, maxs, yawradius, allradius
	end
	loadmodel.num_posescale = R(biggestorigin / 32767.0)
	loadmodel.num_poseinvscale = R(1.0 / loadmodel.num_posescale)
	for i = 0, loadmodel.numframes - 1 do
		storeposes(b, frameposes(i), i, modelscale)
	end

	-- load the meshes now
	dpmmesh = pbase + ph.ofs_meshs
	meshvertices = 0
	meshtriangles = 0
	-- reconstruct frame 0 matrices to allow reconstruction of the base mesh
	-- (converting from weight-blending skeletal animation to
	--  deformation-based skeletal animation)
	poses = frameposes(0)
	local bonepose = framezerobonepose(b, poses)
	local e3i: buffer = surfmesh.data_element3i
	local v3f: buffer = surfmesh.data_vertex3f
	local n3f: buffer = surfmesh.data_normal3f
	for i = 0, loadmodel.num_surfaces - 1 do
		loadmodel.sortedmodelsurfaces[i + 1] = i
		local surface = loadmodel.data_surfaces[i + 1]
		surface.texture = loadmodel.data_textures[i + 1]
		surface.num_firsttriangle = meshtriangles
		surface.num_triangles = BigLong(b, dpmmesh + 36)
		surface.num_firstvertex = meshvertices
		surface.num_vertices = BigLong(b, dpmmesh + 32)
		meshvertices += surface.num_vertices
		meshtriangles += surface.num_triangles

		local inelements = pbase + BigLong(b, dpmmesh + 48)
		local outelements = surface.num_firsttriangle * 12
		for _ = 0, surface.num_triangles - 1 do
			-- swap element order to flip triangles, because Quake uses clockwise (rare) and dpm uses counterclockwise (standard)
			writei32(e3i, outelements, int32(surface.num_firstvertex + BigLong(b, inelements + 8)))
			writei32(e3i, outelements + 4, int32(surface.num_firstvertex + BigLong(b, inelements + 4)))
			writei32(e3i, outelements + 8, int32(surface.num_firstvertex + BigLong(b, inelements)))
			inelements += 12
			outelements += 12
		end

		local intexcoord = pbase + BigLong(b, dpmmesh + 44)
		for j = 0, surface.num_vertices * 2 - 1 do
			writef32(
				surfmesh.data_texcoordtexture2f,
				(j + surface.num_firstvertex * 2) * 4,
				BigFloat(b, intexcoord + j * 4)
			)
		end

		local data = pbase + BigLong(b, dpmmesh + 40)
		for j = surface.num_firstvertex, surface.num_firstvertex + surface.num_vertices - 1 do
			local weightindex = { 0, 0, 0, 0 }
			local weightinfluence = { 0, 0, 0, 0 }
			local numweights = BigLong(b, data)
			data += 4 -- sizeof(dpmvertex_t)
			for k = 0, numweights - 1 do
				local vert = data
				local boneindex = BigLong(b, vert + 28)
				local m = 48 * boneindex
				local influence = BigFloat(b, vert + 12)
				local o0, o1, o2 = BigFloat(b, vert), BigFloat(b, vert + 4), BigFloat(b, vert + 8)
				local n0, n1, n2 = BigFloat(b, vert + 16), BigFloat(b, vert + 20), BigFloat(b, vert + 24)
				-- blend the vertex bone weights into the base mesh
				for r = 0, 2 do
					local ro = m + r * 16
					local m0, m1, m2, m3 =
						readf32(bonepose, ro),
						readf32(bonepose, ro + 4),
						readf32(bonepose, ro + 8),
						readf32(bonepose, ro + 12)
					local d = j * 12 + r * 4
					writef32(
						v3f,
						d,
						readf32(v3f, d) + R(R(R(R(o0 * m0) + R(o1 * m1)) + R(o2 * m2)) + R(influence * m3))
					)
				end
				for r = 0, 2 do
					local ro = m + r * 16
					local m0, m1, m2 = readf32(bonepose, ro), readf32(bonepose, ro + 4), readf32(bonepose, ro + 8)
					local d = j * 12 + r * 4
					writef32(n3f, d, readf32(n3f, d) + R(R(R(n0 * m0) + R(n1 * m1)) + R(n2 * m2)))
				end
				if k == 0 then
					-- store the first (and often only) weight
					weightinfluence[1] = influence
					weightindex[1] = boneindex
				else
					-- sort the new weight into this vertex's weight table
					-- (which only accepts up to 4 bones per vertex)
					for l = 1, 4 do
						if weightinfluence[l] < influence then
							-- move weaker influence weights out of the way first
							for l2 = 4, l + 1, -1 do
								weightinfluence[l2] = weightinfluence[l2 - 1]
								weightindex[l2] = weightindex[l2 - 1]
							end
							-- store the new weight
							weightinfluence[l] = influence
							weightindex[l] = boneindex
							break
						end
					end
				end
				data += 32 -- sizeof(dpmbonevert_t)
			end
			writeu16(
				surfmesh.blends,
				j * 2,
				Mod_Skeletal_CompressBlend(loadmodel, weightindex, weightinfluence) % 65536
			)
			for k = 0, 3 do
				writeu8(surfmesh.data_skeletalindex4ub, j * 4 + k, weightindex[k + 1] % 256)
				writeu8(surfmesh.data_skeletalweight4ub, j * 4 + k, uchar(R(weightinfluence[k + 1] * 255.0)))
			end
		end

		-- since dpm models do not have named sections, reuse their shader name as the section name
		local shadername = cstr(b, dpmmesh)
		model_alias.Mod_BuildAliasSkinsFromSkinFiles(loadmodel.data_textures, i, skinfiles, shadername, shadername)

		model_shared.Mod_ValidateElements(
			e3i,
			surface.num_firsttriangle * 12,
			surface.num_triangles,
			surface.num_firstvertex,
			surface.num_vertices,
			"model_alias.c",
			2582
		)
		dpmmesh += 56 -- sizeof(dpmmesh_t)
	end
	-- if (num_blends < meshvertices) data_blendweights = Mem_Realloc(...): the stored blends stay as they are
	-- Z_Free(bonepose);
	model_shared.Mod_FreeSkinFiles(skinfiles)
	model_shared.Mod_MakeSortedSurfaces(loadmodel)

	-- compute all the mesh information that was not loaded from the file
	copyelements3s(surfmesh)
	Mod_BuildBaseBonePoses()
	model_shared.Mod_BuildTextureVectorsFromNormals(
		0,
		surfmesh.num_vertices,
		surfmesh.num_triangles,
		surfmesh.data_vertex3f,
		surfmesh.data_texcoordtexture2f,
		surfmesh.data_normal3f,
		e3i,
		0,
		surfmesh.data_svector3f,
		surfmesh.data_tvector3f,
		cvi("r_smoothnormals_areaweighting") ~= 0
	)
	if surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, surfmesh.num_triangles)
	end
	surfmesh.isanimated = Mod_Alias_CalculateBoundingBox()
	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	finishmodel(mod)
	checkunusualfeatures(mod)
end

-- no idea why PSK/PSA files contain weird quaternions but they do...
-- #define PSKQUATNEGATIONS
-- model_alias.c Mod_PSKMODEL_Load L2625-3300: not ported (the release has no .psk / .psa file)
function model_alias.Mod_PSKMODEL_Load(mod: any, _filedata: string)
	NOT_YET_PORTED(
		"Mod_PSKMODEL_Load (model_alias.c L2625-3300; the model keeps the default 16-unit box, type mod_invalid; first: "
			.. mod.name
			.. ")"
	)
end

-- IQM: Vector4Normalize2 (mathlib.h) on a 4-float Luau array, in place
local function Vector4Normalize2(v: { number })
	local ilength = R(math.sqrt(R(R(R(R(v[1] * v[1]) + R(v[2] * v[2])) + R(v[3] * v[3])) + R(v[4] * v[4]))))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	v[1], v[2], v[3], v[4] = R(v[1] * ilength), R(v[2] * ilength), R(v[3] * ilength), R(v[4] * ilength)
end

-- port: model_alias.c Mod_INTERQUAKEMODEL_Load L3302-4072 @xonotic-v0.8.6
function model_alias.Mod_INTERQUAKEMODEL_Load(mod: any, filedata: string)
	local loadmodel = model_shared.loadmodel
	local b = buffer.fromstring(filedata)
	newsurfmesh(loadmodel) -- (the zeroed surfmesh of the new dp_model_t)
	local pend = #filedata
	local skinfiles
	local meshvertices, meshtriangles
	local biggestorigin: number
	-- this pointers into the file data are read only through Little* functions so they can be unaligned memory
	local vnormal: number? = nil
	local vposition: number? = nil
	local vtangent: number? = nil
	local vtexcoord: number? = nil
	local vcolor4f: number? = nil
	local vblendindexes: number? = nil
	local vblendweights: number? = nil
	local vcolor4ub: number? = nil

	if 124 > pend then -- pbase + sizeof(iqmheader_t) > pend
		Host_Error("Mod_INTERQUAKEMODEL_Load: %s is not an Inter-Quake Model %d", loadmodel.name, pend)
	end

	-- copy struct (otherwise it may be misaligned)
	-- LordHavoc: okay it's definitely not misaligned here, but for consistency...
	if buffer.readstring(b, 0, 16) ~= "INTERQUAKEMODEL\0" then
		Host_Error("Mod_INTERQUAKEMODEL_Load: %s is not an Inter-Quake Model", loadmodel.name)
	end
	if readu32(b, 16) ~= 1 and readu32(b, 16) ~= 2 then
		Host_Error(
			"Mod_INTERQUAKEMODEL_Load: only version 1 and 2 models are currently supported (name = %s)",
			loadmodel.name
		)
	end

	loadmodel.modeldatatypestring = "IQM"

	loadmodel.type = "mod_alias"
	loadmodel.synctype = ST_RAND

	-- byteswap header
	local function U(o: number): number
		return readu32(b, o)
	end
	local header = {
		version = U(16),
		filesize = U(20),
		flags = U(24),
		num_text = U(28),
		ofs_text = U(32),
		num_meshes = U(36),
		ofs_meshes = U(40),
		num_vertexarrays = U(44),
		num_vertexes = U(48),
		ofs_vertexarrays = U(52),
		num_triangles = U(56),
		ofs_triangles = U(60),
		ofs_neighbors = U(64),
		num_joints = U(68),
		ofs_joints = U(72),
		num_poses = U(76),
		ofs_poses = U(80),
		num_anims = U(84),
		ofs_anims = U(88),
		num_frames = U(92),
		num_framechannels = U(96),
		ofs_frames = U(100),
		ofs_bounds = U(104),
		num_comment = U(108),
		ofs_comment = U(112),
		num_extensions = U(116),
		ofs_extensions = U(120),
	}

	if header.version == 1 then
		if header.ofs_joints + header.num_joints * 44 > pend or header.ofs_poses + header.num_poses * 80 > pend then
			Con_Printf("%s has invalid size or offset information\n", loadmodel.name)
			return
		end
	else
		if header.ofs_joints + header.num_joints * 48 > pend or header.ofs_poses + header.num_poses * 88 > pend then
			Con_Printf("%s has invalid size or offset information\n", loadmodel.name)
			return
		end
	end
	if
		header.ofs_text + header.num_text > pend
		or header.ofs_meshes + header.num_meshes * 24 > pend
		or header.ofs_vertexarrays + header.num_vertexarrays * 20 > pend
		or header.ofs_triangles + header.num_triangles * 12 > pend
		or (header.ofs_neighbors ~= 0 and header.ofs_neighbors + header.num_triangles * 12 > pend)
		or header.ofs_anims + header.num_anims * 20 > pend
		or header.ofs_frames + header.num_frames * header.num_framechannels * 2 > pend
		or (header.ofs_bounds ~= 0 and header.ofs_bounds + header.num_frames * 32 > pend)
		or header.ofs_comment + header.num_comment > pend
	then
		Con_Printf("%s has invalid size or offset information\n", loadmodel.name)
		return
	end

	-- copy structs to make them aligned in memory (otherwise we crash on Sparc and PowerPC and others)
	local vas = header.ofs_vertexarrays
	local anims = header.ofs_anims
	local bounds = header.ofs_bounds
	local meshes = header.ofs_meshes

	for i = 0, header.num_vertexarrays - 1 do
		local vo = vas + i * 20
		local va_type, _va_flags, va_format, va_size, va_offset = U(vo), U(vo + 4), U(vo + 8), U(vo + 12), U(vo + 16)
		local vsize = (header.num_vertexes * va_size) % 4294967296 -- unsigned int product
		if va_format == IQM_FLOAT then
			vsize *= 4
		elseif va_format == IQM_UBYTE then
			vsize *= 1
		else
			continue
		end
		if va_offset + vsize > pend then
			continue
		end
		-- no need to copy the vertex data for alignment because LittleLong/LittleShort will be invoked on reading them, and the destination is aligned
		if va_type == IQM_POSITION then
			if va_format == IQM_FLOAT and va_size == 3 then
				vposition = va_offset
			end
		elseif va_type == IQM_TEXCOORD then
			if va_format == IQM_FLOAT and va_size == 2 then
				vtexcoord = va_offset
			end
		elseif va_type == IQM_NORMAL then
			if va_format == IQM_FLOAT and va_size == 3 then
				vnormal = va_offset
			end
		elseif va_type == IQM_TANGENT then
			if va_format == IQM_FLOAT and va_size == 4 then
				vtangent = va_offset
			end
		elseif va_type == IQM_BLENDINDEXES then
			if va_format == IQM_UBYTE and va_size == 4 then
				vblendindexes = va_offset
			end
		elseif va_type == IQM_BLENDWEIGHTS then
			if va_format == IQM_UBYTE and va_size == 4 then
				vblendweights = va_offset
			end
		elseif va_type == IQM_COLOR then
			if va_format == IQM_FLOAT and va_size == 4 then
				vcolor4f = va_offset
			end
			if va_format == IQM_UBYTE and va_size == 4 then
				vcolor4ub = va_offset
			end
		end
	end
	if
		header.num_vertexes > 0
		and (
			not vposition
			or not vtexcoord
			or ((header.num_frames > 0 or header.num_anims > 0) and (not vblendindexes or not vblendweights))
		)
	then
		Con_Printf("%s is missing vertex array data\n", loadmodel.name)
		return
	end

	-- text = header.num_text && header.ofs_text ? (const char *)(pbase + header.ofs_text) : ""
	local hastext = header.num_text ~= 0 and header.ofs_text ~= 0
	local function text(o: number, max: number?): string
		if not hastext then
			return "" -- (&""[o]: only o = 0 is defined in C)
		end
		return cstr(b, header.ofs_text + o, max)
	end

	setaliasdraw(loadmodel)
	loadmodel.PointSuperContents = nil
	loadmodel.AnimateVertices = Mod_Skeletal_AnimateVertices

	-- load external .skin files if present
	local surfmesh = loadmodel.surfmesh
	skinfiles = model_shared.Mod_LoadSkinFiles()
	if (loadmodel.numskins or 0) < 1 then
		loadmodel.numskins = 1
	end

	loadmodel.numframes = if header.num_anims > 1 then header.num_anims else 1
	loadmodel.num_bones = header.num_joints
	loadmodel.num_poses = if header.num_frames > 1 then header.num_frames else 1
	loadmodel.num_surfaces = header.num_meshes
	loadmodel.nummodelsurfaces = loadmodel.num_surfaces
	loadmodel.num_textures = loadmodel.num_surfaces * loadmodel.numskins
	loadmodel.num_texturesperskin = loadmodel.num_surfaces

	meshvertices = header.num_vertexes
	meshtriangles = header.num_triangles

	-- do most allocations as one merged chunk
	loadmodel.data_surfaces = newsurfaces(loadmodel.num_surfaces)
	loadmodel.sortedmodelsurfaces = newsorted(loadmodel.num_surfaces)
	loadmodel.data_textures = newtextures(loadmodel.num_surfaces * loadmodel.numskins)
	surfmesh.num_vertices = meshvertices
	surfmesh.num_triangles = meshtriangles
	allocskeletal(surfmesh, meshvertices, meshtriangles)
	if vcolor4f or vcolor4ub then
		surfmesh.data_lightmapcolor4f = buffer.create(meshvertices * 16)
	end
	if vblendindexes and vblendweights then
		surfmesh.data_skeletalindex4ub = buffer.create(meshvertices * 4)
		surfmesh.data_skeletalweight4ub = buffer.create(meshvertices * 4)
	end
	loadmodel.data_baseboneposeinverse = buffer.create(loadmodel.num_bones * 48)
	loadmodel.skinscenes = newskinscenes(loadmodel.numskins)
	loadmodel.data_bones = table.create(loadmodel.num_bones)
	loadmodel.animscenes = newskinscenes(loadmodel.numframes)
	if vblendindexes and vblendweights then
		surfmesh.num_blends = 0
		surfmesh.blends = buffer.create(meshvertices * 2)
	end
	if meshvertices <= 65536 then
		surfmesh.data_element3s = buffer.create(meshtriangles * 6)
	end
	loadmodel.data_poses7s = buffer.create(loadmodel.num_poses * loadmodel.num_bones * 14)
	if vblendindexes and vblendweights then
		surfmesh.data_blendweights = buffer.create(meshvertices * 8)
	end

	for i = 0, loadmodel.numskins - 1 do
		local sc = loadmodel.skinscenes[i + 1]
		sc.firstframe = i
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	-- load the bone info
	local inv: buffer = loadmodel.data_baseboneposeinverse
	-- joint1 / joint: { name, parent, origin {3}, rotation {3 or 4}, scale {3} }
	local joints: { any } = table.create(loadmodel.num_bones)
	for i = 0, loadmodel.num_bones - 1 do
		local relbase, relinvbase, pinvbase, invbase =
			matrixlib.new(), matrixlib.new(), matrixlib.new(), matrixlib.new()
		local jo, j
		if header.version == 1 then
			jo = header.ofs_joints + i * 44
			j = {
				name = U(jo),
				parent = readi32(b, jo + 4),
				origin = { readf32(b, jo + 8), readf32(b, jo + 12), readf32(b, jo + 16) },
				rotation = { readf32(b, jo + 20), readf32(b, jo + 24), readf32(b, jo + 28) },
				scale = { readf32(b, jo + 32), readf32(b, jo + 36), readf32(b, jo + 40) },
			}
		else
			jo = header.ofs_joints + i * 48
			j = {
				name = U(jo),
				parent = readi32(b, jo + 4),
				origin = { readf32(b, jo + 8), readf32(b, jo + 12), readf32(b, jo + 16) },
				rotation = { readf32(b, jo + 20), readf32(b, jo + 24), readf32(b, jo + 28), readf32(b, jo + 32) },
				scale = { readf32(b, jo + 36), readf32(b, jo + 40), readf32(b, jo + 44) },
			}
		end
		joints[i + 1] = j
		loadmodel.data_bones[i + 1] = { name = text(j.name, 63), flags = 0, parent = j.parent }
		if loadmodel.data_bones[i + 1].parent >= i then
			Host_Error("%s bone[%i].parent >= %i", loadmodel.name, i, i)
		end
		if header.version ~= 1 then
			local rot = j.rotation
			if rot[4] > 0 then
				rot[1], rot[2], rot[3], rot[4] = -rot[1], -rot[2], -rot[3], -rot[4]
			end
			Vector4Normalize2(rot)
		end
		matrixlib.Matrix4x4_FromDoom3Joint(
			relbase,
			j.origin[1],
			j.origin[2],
			j.origin[3],
			j.rotation[1],
			j.rotation[2],
			j.rotation[3]
		)
		matrixlib.Matrix4x4_Invert_Simple(relinvbase, relbase)
		local parent = loadmodel.data_bones[i + 1].parent
		if parent >= 0 then
			matrixlib.Matrix4x4_FromArray12FloatD3D(pinvbase, inv, 48 * parent)
			matrixlib.Matrix4x4_Concat(invbase, relinvbase, pinvbase)
			matrixlib.Matrix4x4_ToArray12FloatD3D(invbase, inv, 48 * i)
		else
			matrixlib.Matrix4x4_ToArray12FloatD3D(relinvbase, inv, 48 * i)
		end
	end

	-- set up the animscenes based on the anims
	for i = 0, header.num_anims - 1 do
		local ao = anims + i * 20
		local sc = loadmodel.animscenes[i + 1]
		sc.name = text(U(ao), 31)
		sc.firstframe = readi32(b, ao + 4)
		sc.framecount = readi32(b, ao + 8)
		sc.loop = bit32.band(U(ao + 16), IQM_LOOP) ~= 0
		sc.framerate = readf32(b, ao + 12)
	end
	if header.num_anims <= 0 then
		local sc = loadmodel.animscenes[1]
		sc.name = "static"
		sc.firstframe = 0
		sc.framecount = 1
		sc.loop = true
		sc.framerate = 10
	end

	surfmesh.isanimated = loadmodel.num_bones > 1
		or loadmodel.numframes > 1
		or (loadmodel.animscenes ~= nil and loadmodel.animscenes[1].framecount > 1)
	if cvs("mod_alias_force_animated") ~= "" then
		surfmesh.isanimated = cvi("mod_alias_force_animated") ~= 0
	end

	local function fmax(a: number, c: number): number
		return if a > c then a else c
	end
	biggestorigin = 0
	local nch = if header.version == 1 then 9 else 10
	local posesize = if header.version == 1 then 80 else 88
	-- pose1 / pose: { parent, channelmask, channeloffset {9 or 10}, channelscale {9 or 10} }
	local pose: { any } = table.create(header.num_poses)
	for i = 0, header.num_poses - 1 do
		local po = header.ofs_poses + i * posesize
		local p = { parent = readi32(b, po), channelmask = U(po + 4), channeloffset = {}, channelscale = {} }
		for j = 0, nch - 1 do
			p.channeloffset[j + 1] = readf32(b, po + 8 + j * 4)
			p.channelscale[j + 1] = readf32(b, po + 8 + nch * 4 + j * 4)
		end
		pose[i + 1] = p
		for k = 1, 3 do
			biggestorigin = fmax(biggestorigin, math.abs(p.channeloffset[k]))
		end
		for k = 1, 3 do
			biggestorigin = fmax(biggestorigin, math.abs(R(p.channeloffset[k] + R(0xFFFF * p.channelscale[k]))))
		end
	end
	if header.num_frames <= 0 then
		for i = 0, loadmodel.num_bones - 1 do
			for k = 1, 3 do
				biggestorigin = fmax(biggestorigin, math.abs(joints[i + 1].origin[k]))
			end
		end
	end
	loadmodel.num_posescale = R(biggestorigin / 32767.0)
	loadmodel.num_poseinvscale = R(1.0 / loadmodel.num_posescale)

	-- load the pose data
	-- this unaligned memory access is safe (LittleShort reads as bytes)
	local framedata = header.ofs_frames
	local p7: buffer = loadmodel.data_poses7s
	local invscale: number = loadmodel.num_poseinvscale
	-- channel c of pose j: offset + (mask & bit ? (unsigned short)LittleShort(*framedata++) * scale : 0)
	local function channel(p: any, c: number): number
		local v = p.channeloffset[c + 1]
		if bit32.band(p.channelmask, bit32.lshift(1, c)) ~= 0 then
			local s = readu16(b, framedata)
			framedata += 2
			return R(v + R(s * p.channelscale[c + 1]))
		end
		return R(v + 0)
	end
	if header.version == 1 then
		local k = 0
		for _ = 0, header.num_frames - 1 do
			for j = 0, header.num_poses - 1 do
				local p = pose[j + 1]
				local qx, qy, qz, qw
				writei16(p7, (k * 7 + 0) * 2, toshort(R(invscale * channel(p, 0))))
				writei16(p7, (k * 7 + 1) * 2, toshort(R(invscale * channel(p, 1))))
				writei16(p7, (k * 7 + 2) * 2, toshort(R(invscale * channel(p, 2))))
				qx = channel(p, 3)
				qy = channel(p, 4)
				qz = channel(p, 5)
				qw = R(1.0 - R(R(R(qx * qx) + R(qy * qy)) + R(qz * qz)))
				qw = if qw > 0.0 then R(-math.sqrt(qw)) else 0.0
				writei16(p7, (k * 7 + 3) * 2, toshort(R(32767.0 * qx)))
				writei16(p7, (k * 7 + 4) * 2, toshort(R(32767.0 * qy)))
				writei16(p7, (k * 7 + 5) * 2, toshort(R(32767.0 * qz)))
				writei16(p7, (k * 7 + 6) * 2, toshort(R(32767.0 * qw)))
				-- skip scale data for now
				if bit32.band(p.channelmask, 64) ~= 0 then
					framedata += 2
				end
				if bit32.band(p.channelmask, 128) ~= 0 then
					framedata += 2
				end
				if bit32.band(p.channelmask, 256) ~= 0 then
					framedata += 2
				end
				k += 1
			end
		end
		if header.num_frames <= 0 then
			for i = 0, loadmodel.num_bones - 1 do
				local jt = joints[i + 1]
				local qx, qy, qz, qw
				writei16(p7, (i * 7 + 0) * 2, toshort(R(invscale * jt.origin[1])))
				writei16(p7, (i * 7 + 1) * 2, toshort(R(invscale * jt.origin[2])))
				writei16(p7, (i * 7 + 2) * 2, toshort(R(invscale * jt.origin[3])))
				qx = jt.rotation[1]
				qy = jt.rotation[2]
				qz = jt.rotation[3]
				qw = R(1.0 - R(R(R(qx * qx) + R(qy * qy)) + R(qz * qz)))
				qw = if qw > 0.0 then R(-math.sqrt(qw)) else 0.0
				writei16(p7, (i * 7 + 3) * 2, toshort(R(32767.0 * qx)))
				writei16(p7, (i * 7 + 4) * 2, toshort(R(32767.0 * qy)))
				writei16(p7, (i * 7 + 5) * 2, toshort(R(32767.0 * qz)))
				writei16(p7, (i * 7 + 6) * 2, toshort(R(32767.0 * qw)))
			end
		end
	else
		local k = 0
		for _ = 0, header.num_frames - 1 do
			for j = 0, header.num_poses - 1 do
				local p = pose[j + 1]
				local rot = { 0, 0, 0, 0 }
				writei16(p7, (k * 7 + 0) * 2, toshort(R(invscale * channel(p, 0))))
				writei16(p7, (k * 7 + 1) * 2, toshort(R(invscale * channel(p, 1))))
				writei16(p7, (k * 7 + 2) * 2, toshort(R(invscale * channel(p, 2))))
				rot[1] = channel(p, 3)
				rot[2] = channel(p, 4)
				rot[3] = channel(p, 5)
				rot[4] = channel(p, 6)
				if rot[4] > 0 then
					rot[1], rot[2], rot[3], rot[4] = -rot[1], -rot[2], -rot[3], -rot[4]
				end
				Vector4Normalize2(rot)
				writei16(p7, (k * 7 + 3) * 2, toshort(R(32767.0 * rot[1])))
				writei16(p7, (k * 7 + 4) * 2, toshort(R(32767.0 * rot[2])))
				writei16(p7, (k * 7 + 5) * 2, toshort(R(32767.0 * rot[3])))
				writei16(p7, (k * 7 + 6) * 2, toshort(R(32767.0 * rot[4])))
				-- skip scale data for now
				if bit32.band(p.channelmask, 128) ~= 0 then
					framedata += 2
				end
				if bit32.band(p.channelmask, 256) ~= 0 then
					framedata += 2
				end
				if bit32.band(p.channelmask, 512) ~= 0 then
					framedata += 2
				end
				k += 1
			end
		end
		if header.num_frames <= 0 then
			for i = 0, loadmodel.num_bones - 1 do
				local jt = joints[i + 1]
				writei16(p7, (i * 7 + 0) * 2, toshort(R(invscale * jt.origin[1])))
				writei16(p7, (i * 7 + 1) * 2, toshort(R(invscale * jt.origin[2])))
				writei16(p7, (i * 7 + 2) * 2, toshort(R(invscale * jt.origin[3])))
				writei16(p7, (i * 7 + 3) * 2, toshort(R(32767.0 * jt.rotation[1])))
				writei16(p7, (i * 7 + 4) * 2, toshort(R(32767.0 * jt.rotation[2])))
				writei16(p7, (i * 7 + 5) * 2, toshort(R(32767.0 * jt.rotation[3])))
				writei16(p7, (i * 7 + 6) * 2, toshort(R(32767.0 * jt.rotation[4])))
			end
		end
	end

	-- load bounding box data
	if header.ofs_bounds ~= 0 then
		local xyradius, radius = 0, 0
		local nmins, nmaxs = { 0, 0, 0 }, { 0, 0, 0 }
		loadmodel.normalmins = nmins
		loadmodel.normalmaxs = nmaxs
		for i = 0, header.num_frames - 1 do
			local bo = bounds + i * 32
			local bmins = { readf32(b, bo), readf32(b, bo + 4), readf32(b, bo + 8) }
			local bmaxs = { readf32(b, bo + 12), readf32(b, bo + 16), readf32(b, bo + 20) }
			local bxyradius = readf32(b, bo + 24)
			local bradius = readf32(b, bo + 28)
			if i == 0 then
				nmins[1], nmins[2], nmins[3] = bmins[1], bmins[2], bmins[3]
				nmaxs[1], nmaxs[2], nmaxs[3] = bmaxs[1], bmaxs[2], bmaxs[3]
			else
				for k = 1, 3 do
					if nmins[k] > bmins[k] then
						nmins[k] = bmins[k]
					end
				end
				for k = 1, 3 do
					if nmaxs[k] < bmaxs[k] then
						nmaxs[k] = bmaxs[k]
					end
				end
			end
			if bxyradius > xyradius then
				xyradius = bxyradius
			end
			if bradius > radius then
				radius = bradius
			end
		end
		loadmodel.yawmins = { -xyradius, -xyradius, nmins[3] }
		loadmodel.yawmaxs = { xyradius, xyradius, nmaxs[3] }
		loadmodel.rotatedmins = { -radius, -radius, -radius }
		loadmodel.rotatedmaxs = { radius, radius, radius }
		loadmodel.radius = radius
		loadmodel.radius2 = R(radius * radius)
	end

	-- load triangle data
	-- this unaligned memory access is safe (LittleLong reads as bytes)
	local e3i: buffer = surfmesh.data_element3i
	buffer.copy(e3i, 0, b, header.ofs_triangles, header.num_triangles * 12)
	model_shared.Mod_ValidateElements(e3i, 0, surfmesh.num_triangles, 0, header.num_vertexes, "model_alias.c", 3884)

	if header.ofs_neighbors ~= 0 and surfmesh.data_neighbor3i then
		-- this unaligned memory access is safe (LittleLong reads as bytes)
		buffer.copy(surfmesh.data_neighbor3i, 0, b, header.ofs_neighbors, header.num_triangles * 12)
	end

	-- load vertex data
	-- this unaligned memory access is safe (LittleFloat reads as bytes)
	local nv = header.num_vertexes
	if nv > 0 then
		buffer.copy(surfmesh.data_vertex3f, 0, b, vposition :: number, nv * 12)
		buffer.copy(surfmesh.data_texcoordtexture2f, 0, b, vtexcoord :: number, nv * 8)
	end

	-- this unaligned memory access is safe (LittleFloat reads as bytes)
	if vnormal then
		buffer.copy(surfmesh.data_normal3f, 0, b, vnormal, nv * 12)
	end

	-- this unaligned memory access is safe (LittleFloat reads as bytes)
	if vnormal and vtangent then
		local n3: buffer = surfmesh.data_normal3f
		local s3: buffer = surfmesh.data_svector3f
		local t3: buffer = surfmesh.data_tvector3f
		for i = 0, nv - 1 do
			local to = vtangent + i * 16
			local o = i * 12
			local s0, s1, s2 = readf32(b, to), readf32(b, to + 4), readf32(b, to + 8)
			writef32(s3, o, s0)
			writef32(s3, o + 4, s1)
			writef32(s3, o + 8, s2)
			local n0, n1, n2 = readf32(n3, o), readf32(n3, o + 4), readf32(n3, o + 8)
			if readf32(b, to + 12) < 0 then
				-- CrossProduct(outsvector, outnormal, outtvector)
				writef32(t3, o, R(R(s1 * n2) - R(s2 * n1)))
				writef32(t3, o + 4, R(R(s2 * n0) - R(s0 * n2)))
				writef32(t3, o + 8, R(R(s0 * n1) - R(s1 * n0)))
			else
				-- CrossProduct(outnormal, outsvector, outtvector)
				writef32(t3, o, R(R(n1 * s2) - R(n2 * s1)))
				writef32(t3, o + 4, R(R(n2 * s0) - R(n0 * s2)))
				writef32(t3, o + 8, R(R(n0 * s1) - R(n1 * s0)))
			end
		end
	end

	-- this unaligned memory access is safe (all bytes)
	if vblendindexes and vblendweights then
		for i = 0, nv - 1 do
			local weights = { index = { 0, 0, 0, 0 }, influence = { 0, 0, 0, 0 } }
			for k = 1, 4 do
				weights.index[k] = readu8(b, vblendindexes + i * 4 + k - 1)
				weights.influence[k] = readu8(b, vblendweights + i * 4 + k - 1)
			end
			writeu16(surfmesh.blends, i * 2, Mod_Skeletal_AddBlend(loadmodel, weights) % 65536)
			for k = 0, 3 do
				writeu8(surfmesh.data_skeletalindex4ub, i * 4 + k, weights.index[k + 1])
				writeu8(surfmesh.data_skeletalweight4ub, i * 4 + k, weights.influence[k + 1])
			end
		end
	end

	if vcolor4f then
		-- this unaligned memory access is safe (LittleFloat reads as bytes)
		buffer.copy(surfmesh.data_lightmapcolor4f, 0, b, vcolor4f, nv * 16)
	elseif vcolor4ub then
		local outcolor: buffer = surfmesh.data_lightmapcolor4f
		-- this unaligned memory access is safe (all bytes)
		for i = 0, nv * 4 - 1 do
			writef32(outcolor, i * 4, R(readu8(b, vcolor4ub + i) * R(1.0 / 255.0)))
		end
	end

	-- load meshes
	for i = 0, header.num_meshes - 1 do
		local mo = meshes + i * 24
		local mesh_name, mesh_material = U(mo), U(mo + 4)
		local first_vertex, num_vertexes = U(mo + 8), U(mo + 12)
		local first_triangle, num_triangles = U(mo + 16), U(mo + 20)

		loadmodel.sortedmodelsurfaces[i + 1] = i
		local surface = loadmodel.data_surfaces[i + 1]
		surface.texture = loadmodel.data_textures[i + 1]
		surface.num_firsttriangle = int32(first_triangle)
		surface.num_triangles = int32(num_triangles)
		surface.num_firstvertex = int32(first_vertex)
		surface.num_vertices = int32(num_vertexes)

		model_alias.Mod_BuildAliasSkinsFromSkinFiles(
			loadmodel.data_textures,
			i,
			skinfiles,
			text(mesh_name),
			text(mesh_material)
		)
	end

	model_shared.Mod_FreeSkinFiles(skinfiles)
	model_shared.Mod_MakeSortedSurfaces(loadmodel)

	-- compute all the mesh information that was not loaded from the file
	copyelements3s(surfmesh)
	local areaweighting = cvi("r_smoothnormals_areaweighting") ~= 0
	if not vnormal then
		model_shared.Mod_BuildNormals(
			0,
			surfmesh.num_vertices,
			surfmesh.num_triangles,
			surfmesh.data_vertex3f,
			e3i,
			0,
			surfmesh.data_normal3f,
			areaweighting
		)
	end
	if not vnormal or not vtangent then
		model_shared.Mod_BuildTextureVectorsFromNormals(
			0,
			surfmesh.num_vertices,
			surfmesh.num_triangles,
			surfmesh.data_vertex3f,
			surfmesh.data_texcoordtexture2f,
			surfmesh.data_normal3f,
			e3i,
			0,
			surfmesh.data_svector3f,
			surfmesh.data_tvector3f,
			areaweighting
		)
	end
	if header.ofs_neighbors == 0 and surfmesh.data_neighbor3i then
		model_shared.Mod_BuildTriangleNeighbors(surfmesh.data_neighbor3i, e3i, surfmesh.num_triangles)
	end
	if header.ofs_bounds == 0 then
		Mod_Alias_CalculateBoundingBox()
	end

	finishmodel(mod)

	-- if (joint) Mem_Free(joint); ... (pose1)

	checkunusualfeatures(mod)
end

model_shared.Mod_IDP0_Load = model_alias.Mod_IDP0_Load
model_shared.Mod_IDP2_Load = model_alias.Mod_IDP2_Load
model_shared.Mod_IDP3_Load = model_alias.Mod_IDP3_Load
model_shared.Mod_ZYMOTICMODEL_Load = model_alias.Mod_ZYMOTICMODEL_Load
model_shared.Mod_DARKPLACESMODEL_Load = model_alias.Mod_DARKPLACESMODEL_Load
model_shared.Mod_PSKMODEL_Load = model_alias.Mod_PSKMODEL_Load
model_shared.Mod_INTERQUAKEMODEL_Load = model_alias.Mod_INTERQUAKEMODEL_Load

model_shared.Mod_AliasInit = model_alias.Mod_AliasInit

return model_alias
