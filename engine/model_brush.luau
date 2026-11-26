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

(DarkPlaces model_brush.c / model_brush.h)
]]
--[[
	Port of model_brush.c @xonotic-v0.8.6. PARTIAL (task M3-BSPLOAD, part 1): the Quake 3 BSP loader
	Mod_IBSP_Load / Mod_Q3BSP_Load with the lump loaders for entities, textures (lump fields only), planes,
	brush sides, brushes, effects, vertices, triangles, faces (flat, mesh and patch surfaces with their
	collision geometry), models, leaf brushes, leaf faces, leafs, nodes, light grid and PVS, plus the
	contents-flag mapping.

	How the C data is held:
	  * The file (mod_base) is a `buffer`; LittleLong / LittleFloat are buffer.readi32 / readf32.
	  * dp_model_t and its brush / brushq3 parts are tables with the C field names.
	  * Arrays of structs (data_planes, data_brushsides, data_brushes, data_leafs, data_nodes, data_textures,
	    data_effects, data_models) are 1-based Luau arrays: C element i is at [i + 1].
	  * A C pointer to one struct (out->plane, out->texture, node->children[j], node->parent) is a reference to
	    that table. A pointer used as an array start (firstbrushside, firstleafsurface, firstleafbrush) is kept
	    as the 0-based C index; every record also carries its own 0-based `index` where the C code subtracts
	    pointers (leafs).
	  * Big numeric arrays stay binary, as in C: float arrays (data_vertex3f, data_normal3f,
	    data_texcoordtexture2f, data_texcoordlightmap2f, data_color4f) are f32 buffers, data_element3i,
	    data_leafbrushes and data_leafsurfaces are i32 buffers, data_pvsclusters and data_lightgrid are byte
	    buffers. Element k of a float array is buffer.readf32(b, 4 * k).
	NOT YET PORTED (each logs once when reached): Mod_LoadTextureFromQ3Shader (model_shared.c; texture_t has
	only name / surfaceflags / supercontents), Mod_Q3BSP_LoadLightmaps and the lightmap parts of
	Mod_Q3BSP_LoadFaces (surfaces load as on a dedicated server), Mod_Q1BSP_MakePortals, Mod_Q1BSP_CreateShadowMesh, the model registry (submodels are only in
	brush.submodels), the PVS / light-point functions, the Q1 / Q2 /
	HL BSP and OBJ loaders, Mod_BrushInit (cvar registration: the cvars are read with their defaults).
]]
local bih = require("./bih")
local collision = require("./collision")
local curves = require("./curves")
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libc = require("./_port/libc")
local matrixlib = require("./matrixlib")
local mdfour = require("./mdfour")
local model_shared = require("./model_shared")

local model_brush = {}

local R = f32.round
local Con_Print, Con_Printf, Con_DPrintf = console.Con_Print, console.Con_Printf, console.Con_DPrintf
local readi32, readf32, readu8 = buffer.readi32, buffer.readf32, buffer.readu8
local writei32, writef32 = buffer.writei32, buffer.writef32

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

-- model_brush.h L619-641
model_brush.Q3BSPVERSION = 46
model_brush.Q3BSPVERSION_LIVE = 47
model_brush.Q3BSPVERSION_IG = 48
local Q3BSPVERSION, Q3BSPVERSION_LIVE, Q3BSPVERSION_IG = 46, 47, 48
local Q3LUMP_ENTITIES = 0 -- entities to spawn (used by server and client)
local Q3LUMP_TEXTURES = 1 -- textures used (used by faces)
local Q3LUMP_PLANES = 2 -- planes used (used by bsp nodes)
local Q3LUMP_NODES = 3 -- bsp nodes (used by bsp nodes, bsp leafs, rendering, collisions)
local Q3LUMP_LEAFS = 4 -- bsp leafs (used by bsp nodes)
local Q3LUMP_LEAFFACES = 5 -- array of ints indexing faces (used by leafs)
local Q3LUMP_LEAFBRUSHES = 6 -- array of ints indexing brushes (used by leafs)
local Q3LUMP_MODELS = 7 -- models (used by rendering, collisions)
local Q3LUMP_BRUSHES = 8 -- brushes (used by effects, collisions)
local Q3LUMP_BRUSHSIDES = 9 -- brush faces (used by brushes)
local Q3LUMP_VERTICES = 10 -- mesh vertices (used by faces)
local Q3LUMP_TRIANGLES = 11 -- mesh triangles (used by faces)
local Q3LUMP_EFFECTS = 12 -- fog (used by faces)
local Q3LUMP_FACES = 13 -- surfaces (used by leafs)
local Q3LUMP_LIGHTMAPS = 14 -- lightmap textures (used by faces)
local Q3LUMP_LIGHTGRID = 15 -- lighting as a voxel grid (used by rendering)
local Q3LUMP_PVS = 16 -- potentially visible set; bit[clusters][clusters] (used by rendering)
local Q3HEADER_LUMPS = 17
local Q3HEADER_LUMPS_LIVE = 18
local Q3PATHLENGTH = 64 -- bspfile.h

-- model_brush.h L724-727
local Q3FACETYPE_FLAT = 1 -- common
local Q3FACETYPE_PATCH = 2 -- common
local Q3FACETYPE_MESH = 3 -- common
local Q3FACETYPE_FLARE = 4 -- rare (is this ever used?)

-- curves.h
local PATCH_LOD_COLLISION = curves.PATCH_LOD_COLLISION
local PATCH_LOD_VISUAL = curves.PATCH_LOD_VISUAL

-- cls.state == ca_dedicated. Only the dedicated path of the loader is ported so far (no lightmap textures).
model_brush.dedicated = true

-- The render BIH (every render triangle of the model, used by Mod_CollisionBIH_TraceLineAgainstSurfaces and
-- BIH_GetTriangleListForBox) is built like in C when true. Port support: a memory switch for hosts that never
-- trace against render surfaces; it does not change any result of the collision BIH.
model_brush.build_render_bih = true

-- Test hook (port support, no C counterpart): called with the model after Mod_Q3BSP_LoadTriangles, while the
-- brushq3 vertex and triangle arrays still exist (Mod_Q3BSP_LoadFaces frees them).
model_brush.debug_after_triangles = nil :: ((mod: any) -> ())?

-- sizeof() of the on-disk structs (model_brush.h L643-812)
local SIZEOF_q3dheader_t = 8 + 8 * 18
local SIZEOF_q3dtexture_t = Q3PATHLENGTH + 8
local SIZEOF_q3dplane_t = 16
local SIZEOF_q3dnode_t = 36
local SIZEOF_q3dleaf_t = 48
local SIZEOF_q3dmodel_t = 40
local SIZEOF_q3dbrush_t = 12
local SIZEOF_q3dbrushside_t = 8
local SIZEOF_q3dbrushside_ig_t = 12
local SIZEOF_q3dvertex_t = 44
local SIZEOF_q3deffect_t = Q3PATHLENGTH + 8
local SIZEOF_q3dface_t = 104
local SIZEOF_q3dlightgrid_t = 8
local SIZEOF_q3dpvs_t = 8

-- bspfile.h CONTENTSQ3_* L276-296
local CONTENTSQ3_SOLID = 0x00000001 -- solid (opaque and transparent)
local CONTENTSQ3_LAVA = 0x00000008 -- lava
local CONTENTSQ3_SLIME = 0x00000010 -- slime
local CONTENTSQ3_WATER = 0x00000020 -- water
local CONTENTSQ3_PLAYERCLIP = 0x00010000 -- block players
local CONTENTSQ3_MONSTERCLIP = 0x00020000 -- block monsters
local CONTENTSQ3_DONOTENTER = 0x00200000 -- hint for Q3's bots
local CONTENTSQ3_BOTCLIP = 0x00400000 -- hint for Q3's bots
local CONTENTSQ3_BODY = 0x02000000 -- used by bbox entities (should never be on a brush)
local CONTENTSQ3_CORPSE = 0x04000000 -- used by dead bodies (SOLID_CORPSE in darkplaces)
local CONTENTSQ3_TRANSLUCENT = 0x20000000 -- leaves surfaces that are inside for rendering
local CONTENTSQ3_NODROP = 0x80000000 -- remove items that fall into this brush

-- bspfile.h SUPERCONTENTS_* L232-247
model_brush.SUPERCONTENTS_SOLID = 0x00000001
model_brush.SUPERCONTENTS_WATER = 0x00000002
model_brush.SUPERCONTENTS_SLIME = 0x00000004
model_brush.SUPERCONTENTS_LAVA = 0x00000008
model_brush.SUPERCONTENTS_SKY = 0x00000010
model_brush.SUPERCONTENTS_BODY = 0x00000020
model_brush.SUPERCONTENTS_CORPSE = 0x00000040
model_brush.SUPERCONTENTS_NODROP = 0x00000080
model_brush.SUPERCONTENTS_PLAYERCLIP = 0x00000100
model_brush.SUPERCONTENTS_MONSTERCLIP = 0x00000200
model_brush.SUPERCONTENTS_DONOTENTER = 0x00000400
model_brush.SUPERCONTENTS_BOTCLIP = 0x00000800
model_brush.SUPERCONTENTS_OPAQUE = 0x00001000
local SUPERCONTENTS_SOLID = 0x00000001
local SUPERCONTENTS_WATER = 0x00000002
local SUPERCONTENTS_SLIME = 0x00000004
local SUPERCONTENTS_LAVA = 0x00000008
local SUPERCONTENTS_BODY = 0x00000020
local SUPERCONTENTS_CORPSE = 0x00000040
local SUPERCONTENTS_NODROP = 0x00000080
local SUPERCONTENTS_PLAYERCLIP = 0x00000100
local SUPERCONTENTS_MONSTERCLIP = 0x00000200
local SUPERCONTENTS_DONOTENTER = 0x00000400
local SUPERCONTENTS_BOTCLIP = 0x00000800
local SUPERCONTENTS_OPAQUE = 0x00001000

-- model_brush.h mplane_t L49-64
export type mplane_t = {
	normal: { number },
	dist: number,
	-- for texture axis selection and fast side tests
	type: number, -- set by PlaneClassify()
	signbits: number, -- set by PlaneClassify()
}

-- model_shared.h texture_t (only the fields filled so far)
export type texture_t = {
	index: number, -- 0-based position in data_textures (port support)
	name: string,
	surfaceflags: number,
	supercontents: number,
	basematerialflags: number,
}

-- model_brush.h q3mbrushside_t L715-720
export type q3mbrushside_t = { plane: mplane_t, texture: texture_t }

-- model_brush.h q3mbrush_t L706-713
export type q3mbrush_t = {
	colbrushf: any, -- colbrushf_t (collision.luau)
	numbrushsides: number,
	firstbrushside: number, -- 0-based index into data_brushsides
	texture: texture_t,
}

-- model_brush.h mnode_t L145-164 and mleaf_t L166-190 in one record: a leaf has plane == nil
export type mnode_t = {
	index: number, -- 0-based position in data_nodes / data_leafs (port support for pointer arithmetic)
	--this part shared between node and leaf
	plane: mplane_t?, -- != NULL for a node, NULL for a leaf
	parent: mnode_t?,
	-- for bounding box culling
	mins: { number },
	maxs: { number },
	-- supercontents from all brushes inside this node or leaf
	combinedsupercontents: number,
	-- this part unique to node
	children: { mnode_t },
	-- this part unique to leaf
	clusterindex: number, -- -1 is not in pvs, >= 0 is pvs bit number
	areaindex: number, -- q3bsp
	containscollisionsurfaces: boolean, -- indicates whether the leafsurfaces contains q3 patches
	numleafsurfaces: number,
	firstleafsurface: number, -- 0-based index into data_leafsurfaces
	numleafbrushes: number, -- q3bsp
	firstleafbrush: number, -- 0-based index into data_leafbrushes
}

-- model_brush.h q3dmodel_t L688-697 (in-memory copy)
export type q3dmodel_t = {
	mins: { number },
	maxs: { number },
	firstface: number,
	numfaces: number,
	firstbrush: number,
	numbrushes: number,
}

export type lump_t = { fileofs: number, filelen: number }
export type dp_model_t = { [string]: any }

-- A zeroed dp_model_t (C: Mod_FindName allocates it with Mem_Alloc; model_shared.c is not ported yet).
function model_brush.newmodel(name: string): dp_model_t
	return {
		name = name,
		brush = {},
		brushq3 = {
			num_lightgrid_cellsize = { 0, 0, 0 },
			num_lightgrid_scale = { 0, 0, 0 },
			num_lightgrid_imins = { 0, 0, 0 },
			num_lightgrid_imaxs = { 0, 0, 0 },
			num_lightgrid_isize = { 0, 0, 0 },
			num_lightgrid_indexfromworld = matrixlib.new(),
			num_lightgrid = 0,
			deluxemapping = false,
			deluxemapping_modelspace = false,
		},
		num_surfaces = 0,
		lit = false,
	}
end

-- model_shared.c globals
local loadmodel: dp_model_t = nil :: any
local mod_base: buffer = nil :: any

-- port: mathlib.c PlaneClassify L310-329 @xonotic-v0.8.6
local function PlaneClassify(p: mplane_t)
	-- for optimized plane comparisons
	if p.normal[1] == 1 then
		p.type = 0
	elseif p.normal[2] == 1 then
		p.type = 1
	elseif p.normal[3] == 1 then
		p.type = 2
	else
		p.type = 3
	end
	-- for BoxOnPlaneSide
	p.signbits = 0
	if p.normal[1] < 0 then -- 1
		p.signbits = bit32.bor(p.signbits, 1)
	end
	if p.normal[2] < 0 then -- 2
		p.signbits = bit32.bor(p.signbits, 2)
	end
	if p.normal[3] < 0 then -- 4
		p.signbits = bit32.bor(p.signbits, 4)
	end
end
model_brush.PlaneClassify = PlaneClassify

-- NUL-terminated char[n] at a file offset
local function cstring(b: buffer, ofs: number, n: number): string
	local len = 0
	while len < n and readu8(b, ofs + len) ~= 0 do
		len += 1
	end
	return buffer.readstring(b, ofs, len)
end

-- sscanf(value, "%f %f %f", ...): number of floats converted and the floats (float32)
local function sscanf_3f(value: string, v: { number }): number
	local pos = 1
	local n = 0
	for i = 1, 3 do
		local d, nextpos = libc.strtod(value, pos)
		if nextpos == pos then
			break
		end
		v[i] = R(d)
		pos = nextpos
		n += 1
	end
	return n
end

-- port: model_brush.c Mod_Q1BSP_LoadNodes_RecursiveSetParent L2837-2872 @xonotic-v0.8.6
local function Mod_Q1BSP_LoadNodes_RecursiveSetParent(node: mnode_t, parent: mnode_t?)
	--if (node->parent)
	--	Host_Error("Mod_Q1BSP_LoadNodes_RecursiveSetParent: runaway recursion");
	node.parent = parent
	if node.plane then
		-- this is a node, recurse to children
		Mod_Q1BSP_LoadNodes_RecursiveSetParent(node.children[1], node)
		Mod_Q1BSP_LoadNodes_RecursiveSetParent(node.children[2], node)
		-- combine supercontents of children
		node.combinedsupercontents =
			bit32.bor(node.children[1].combinedsupercontents, node.children[2].combinedsupercontents)
	else
		local leaf = node
		-- if this is a leaf, calculate supercontents mask from all collidable
		-- primitives in the leaf (brushes and collision surfaces)
		-- also flag if the leaf contains any collision surfaces
		leaf.combinedsupercontents = 0
		-- combine the supercontents values of all brushes in this leaf
		local brushes: { q3mbrush_t } = loadmodel.brush.data_brushes
		local leafbrushes: buffer = loadmodel.brush.data_leafbrushes
		for j = 0, leaf.numleafbrushes - 1 do
			leaf.combinedsupercontents = bit32.bor(
				leaf.combinedsupercontents,
				brushes[readi32(leafbrushes, 4 * (leaf.firstleafbrush + j)) + 1].texture.supercontents
			)
		end
		-- check if this leaf contains any collision surfaces (q3 patches)
		local surfaces = loadmodel.data_surfaces
		local leafsurfaces: buffer = loadmodel.brush.data_leafsurfaces
		for j = 0, leaf.numleafsurfaces - 1 do
			local surface = surfaces[readi32(leafsurfaces, 4 * (leaf.firstleafsurface + j)) + 1]
			if surface.num_collisiontriangles ~= 0 then
				leaf.containscollisionsurfaces = true
				leaf.combinedsupercontents = bit32.bor(leaf.combinedsupercontents, surface.texture.supercontents)
			end
		end
	end
end

-- port: model_brush.c Mod_Q3BSP_SuperContentsFromNativeContents L7815-7843 @xonotic-v0.8.6
local function Mod_Q3BSP_SuperContentsFromNativeContents(nativecontents: number): number
	local supercontents = 0
	if bit32.band(nativecontents, CONTENTSQ3_SOLID) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_SOLID)
	end
	if bit32.band(nativecontents, CONTENTSQ3_WATER) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_WATER)
	end
	if bit32.band(nativecontents, CONTENTSQ3_SLIME) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_SLIME)
	end
	if bit32.band(nativecontents, CONTENTSQ3_LAVA) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_LAVA)
	end
	if bit32.band(nativecontents, CONTENTSQ3_BODY) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_BODY)
	end
	if bit32.band(nativecontents, CONTENTSQ3_CORPSE) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_CORPSE)
	end
	if bit32.band(nativecontents, CONTENTSQ3_NODROP) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_NODROP)
	end
	if bit32.band(nativecontents, CONTENTSQ3_PLAYERCLIP) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_PLAYERCLIP)
	end
	if bit32.band(nativecontents, CONTENTSQ3_MONSTERCLIP) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_MONSTERCLIP)
	end
	if bit32.band(nativecontents, CONTENTSQ3_DONOTENTER) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_DONOTENTER)
	end
	if bit32.band(nativecontents, CONTENTSQ3_BOTCLIP) ~= 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_BOTCLIP)
	end
	if bit32.band(nativecontents, CONTENTSQ3_TRANSLUCENT) == 0 then
		supercontents = bit32.bor(supercontents, SUPERCONTENTS_OPAQUE)
	end
	return supercontents
end
model_brush.Mod_Q3BSP_SuperContentsFromNativeContents = Mod_Q3BSP_SuperContentsFromNativeContents

-- port: model_brush.c Mod_Q3BSP_NativeContentsFromSuperContents L7845-7873 @xonotic-v0.8.6
local function Mod_Q3BSP_NativeContentsFromSuperContents(supercontents: number): number
	local nativecontents = 0
	if bit32.band(supercontents, SUPERCONTENTS_SOLID) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_SOLID)
	end
	if bit32.band(supercontents, SUPERCONTENTS_WATER) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_WATER)
	end
	if bit32.band(supercontents, SUPERCONTENTS_SLIME) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_SLIME)
	end
	if bit32.band(supercontents, SUPERCONTENTS_LAVA) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_LAVA)
	end
	if bit32.band(supercontents, SUPERCONTENTS_BODY) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_BODY)
	end
	if bit32.band(supercontents, SUPERCONTENTS_CORPSE) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_CORPSE)
	end
	if bit32.band(supercontents, SUPERCONTENTS_NODROP) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_NODROP)
	end
	if bit32.band(supercontents, SUPERCONTENTS_PLAYERCLIP) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_PLAYERCLIP)
	end
	if bit32.band(supercontents, SUPERCONTENTS_MONSTERCLIP) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_MONSTERCLIP)
	end
	if bit32.band(supercontents, SUPERCONTENTS_DONOTENTER) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_DONOTENTER)
	end
	if bit32.band(supercontents, SUPERCONTENTS_BOTCLIP) ~= 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_BOTCLIP)
	end
	if bit32.band(supercontents, SUPERCONTENTS_OPAQUE) == 0 then
		nativecontents = bit32.bor(nativecontents, CONTENTSQ3_TRANSLUCENT)
	end
	return nativecontents
end
model_brush.Mod_Q3BSP_NativeContentsFromSuperContents = Mod_Q3BSP_NativeContentsFromSuperContents

-- port: model_brush.c Mod_Q3BSP_LoadEntities L5225-5290 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadEntities(l: lump_t)
	local key: string
	local value: string
	local v = { 0, 0, 0 }
	loadmodel.brushq3.num_lightgrid_cellsize[1] = 64
	loadmodel.brushq3.num_lightgrid_cellsize[2] = 64
	loadmodel.brushq3.num_lightgrid_cellsize[3] = 128
	if l.filelen == 0 then
		return
	end
	-- C copies filelen bytes and appends a NUL: as a C string the text ends at the first NUL
	loadmodel.brush.entities = cstring(mod_base, l.fileofs, l.filelen)
	local s: string = loadmodel.brush.entities
	local data: number? = 1
	local ok: boolean
	-- some Q3 maps override the lightgrid_cellsize with a worldspawn key
	-- VorteX: q3map2 FS-R generates tangentspace deluxemaps for q3bsp and sets 'deluxeMaps' key
	loadmodel.brushq3.deluxemapping = false
	ok, data = common.COM_ParseToken_Simple(s, data, false, false, true)
	if ok and string.byte(common.com_token, 1) == 123 then -- '{'
		while true do
			ok, data = common.COM_ParseToken_Simple(s, data, false, false, true)
			if not ok then
				break -- error
			end
			if string.byte(common.com_token, 1) == 125 then -- '}'
				break -- end of worldspawn
			end
			if string.byte(common.com_token, 1) == 95 then -- '_'
				key = string.sub(common.com_token, 2, 128) -- strlcpy(key, com_token + 1, sizeof(key))
			else
				key = string.sub(common.com_token, 1, 127)
			end
			while string.byte(key, #key) == 32 do -- remove trailing spaces
				key = string.sub(key, 1, #key - 1)
			end
			ok, data = common.COM_ParseToken_Simple(s, data, false, false, true)
			if not ok then
				break -- error
			end
			value = string.sub(common.com_token, 1, 16384 - 1) -- strlcpy(value, com_token, MAX_INPUTLINE)
			if libc.strcasecmp("gridsize", key) == 0 then -- this one is case insensitive to 100% match q3map2
				v[1], v[2], v[3] = 64, 64, 128
				if sscanf_3f(value, v) ~= 3 then
					Con_Printf(
						'Mod_Q3BSP_LoadEntities: funny gridsize "%s" in %s, interpreting as "%f %f %f" to match q3map2\'s parsing\n',
						value,
						loadmodel.name,
						v[1],
						v[2],
						v[3]
					)
				end
				if v[1] ~= 0 and v[2] ~= 0 and v[3] ~= 0 then
					local cs = loadmodel.brushq3.num_lightgrid_cellsize
					cs[1], cs[2], cs[3] = v[1], v[2], v[3]
				end
			elseif key == "deluxeMaps" then
				if common.com_token == "1" then
					loadmodel.brushq3.deluxemapping = true
					loadmodel.brushq3.deluxemapping_modelspace = true
				elseif common.com_token == "2" then
					loadmodel.brushq3.deluxemapping = true
					loadmodel.brushq3.deluxemapping_modelspace = false
				end
			end
		end
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadTextures L5292-5317 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadTextures(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dtexture_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadTextures: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dtexture_t
	local out: { texture_t } = table.create(count)

	loadmodel.data_textures = out
	loadmodel.num_textures = count
	loadmodel.num_texturesperskin = loadmodel.num_textures

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dtexture_t
		local t: texture_t = {
			index = i,
			name = cstring(mod_base, p, Q3PATHLENGTH),
			surfaceflags = readi32(mod_base, p + Q3PATHLENGTH),
			supercontents = Mod_Q3BSP_SuperContentsFromNativeContents(
				bit32.band(readi32(mod_base, p + Q3PATHLENGTH + 4), 0xFFFFFFFF)
			),
			basematerialflags = 0,
		}
		out[i + 1] = t
		NOT_YET_PORTED("Mod_LoadTextureFromQ3Shader (model_shared.c): textures keep only the lump's name and flags")
		-- restore the surfaceflags and supercontents
		t.surfaceflags = readi32(mod_base, p + Q3PATHLENGTH)
		t.supercontents =
			Mod_Q3BSP_SuperContentsFromNativeContents(bit32.band(readi32(mod_base, p + Q3PATHLENGTH + 4), 0xFFFFFFFF))
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadPlanes L5319-5342 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadPlanes(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dplane_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadPlanes: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dplane_t
	local out: { mplane_t } = table.create(count)

	loadmodel.brush.data_planes = out
	loadmodel.brush.num_planes = count

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dplane_t
		local plane: mplane_t = {
			normal = { readf32(mod_base, p), readf32(mod_base, p + 4), readf32(mod_base, p + 8) },
			dist = readf32(mod_base, p + 12),
			type = 0,
			signbits = 0,
		}
		PlaneClassify(plane)
		out[i + 1] = plane
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadBrushSides L5344-5370 @xonotic-v0.8.6
-- port: model_brush.c Mod_Q3BSP_LoadBrushSides_IG L5372-5398 @xonotic-v0.8.6 (same code, 12-byte records)
local function Mod_Q3BSP_LoadBrushSides(l: lump_t, sizeof_in: number)
	local inofs = l.fileofs
	if l.filelen % sizeof_in ~= 0 then
		Host_Error("Mod_Q3BSP_LoadBrushSides: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // sizeof_in
	local out: { q3mbrushside_t } = table.create(count)

	loadmodel.brush.data_brushsides = out
	loadmodel.brush.num_brushsides = count

	for i = 0, count - 1 do
		local p = inofs + i * sizeof_in
		local n = readi32(mod_base, p)
		if n < 0 or n >= loadmodel.brush.num_planes then
			Host_Error("Mod_Q3BSP_LoadBrushSides: invalid planeindex %i (%i planes)", n, loadmodel.brush.num_planes)
		end
		local plane: mplane_t = loadmodel.brush.data_planes[n + 1]
		n = readi32(mod_base, p + 4)
		if n < 0 or n >= loadmodel.num_textures then
			Host_Error("Mod_Q3BSP_LoadBrushSides: invalid textureindex %i (%i textures)", n, loadmodel.num_textures)
		end
		out[i + 1] = { plane = plane, texture = loadmodel.data_textures[n + 1] }
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadBrushes L5400-5457 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadBrushes(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dbrush_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadBrushes: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dbrush_t
	local out: { q3mbrush_t } = table.create(count)

	loadmodel.brush.data_brushes = out
	loadmodel.brush.num_brushes = count

	local brushsides: { q3mbrushside_t } = loadmodel.brush.data_brushsides

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dbrush_t
		local n = readi32(mod_base, p)
		local c = readi32(mod_base, p + 4)
		if n < 0 or n + c > loadmodel.brush.num_brushsides then
			Host_Error(
				"Mod_Q3BSP_LoadBrushes: invalid brushside range %i : %i (%i brushsides)",
				n,
				n + c,
				loadmodel.brush.num_brushsides
			)
		end
		local firstbrushside = n
		local numbrushsides = c
		n = readi32(mod_base, p + 8)
		if n < 0 or n >= loadmodel.num_textures then
			Host_Error("Mod_Q3BSP_LoadBrushes: invalid textureindex %i (%i textures)", n, loadmodel.num_textures)
		end
		local texture: texture_t = loadmodel.data_textures[n + 1]

		-- make a list of mplane_t structs to construct a colbrush from
		local planes: { collision.colplanef_t } = table.create(numbrushsides)
		local q3surfaceflags = 0
		for j = 0, numbrushsides - 1 do
			local side = brushsides[firstbrushside + j + 1]
			planes[j + 1] = {
				normal = { side.plane.normal[1], side.plane.normal[2], side.plane.normal[3] },
				dist = side.plane.dist,
				q3surfaceflags = side.texture.surfaceflags,
				texture = side.texture,
			}
			q3surfaceflags = bit32.bor(q3surfaceflags, side.texture.surfaceflags)
		end
		-- make the colbrush from the planes
		out[i + 1] = {
			colbrushf = collision.Collision_NewBrushFromPlanes(
				numbrushsides,
				planes,
				texture.supercontents,
				q3surfaceflags,
				texture,
				true
			),
			numbrushsides = numbrushsides,
			firstbrushside = firstbrushside,
			texture = texture,
		}

		-- this whole loop can take a while (e.g. on redstarrepublic4)
		-- CL_KeepaliveMessage(false): client network keepalive, nothing to do while loading here
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadEffects L5459-5486 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadEffects(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3deffect_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadEffects: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3deffect_t
	local out = table.create(count)

	loadmodel.brushq3.data_effects = out
	loadmodel.brushq3.num_effects = count

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3deffect_t
		local n = readi32(mod_base, p + Q3PATHLENGTH)
		if n >= loadmodel.brush.num_brushes then
			Con_Printf(
				"Mod_Q3BSP_LoadEffects: invalid brushindex %i (%i brushes), setting to -1\n",
				n,
				loadmodel.brush.num_brushes
			)
			n = -1
		end
		out[i + 1] = {
			shadername = cstring(mod_base, p, Q3PATHLENGTH - 1), -- strlcpy(..., sizeof(out->shadername))
			brushindex = n,
			unknown = readi32(mod_base, p + Q3PATHLENGTH + 4),
		}
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadVertices L5488-5554 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadVertices(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dvertex_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadVertices: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dvertex_t
	local q3 = loadmodel.brushq3
	q3.num_vertices = count
	local vertex3f = buffer.create(count * 12)
	local normal3f = buffer.create(count * 12)
	local texcoordtexture2f = buffer.create(count * 8)
	local texcoordlightmap2f = buffer.create(count * 8)
	local color4f = buffer.create(count * 16)
	q3.data_vertex3f = vertex3f
	q3.data_normal3f = normal3f
	q3.data_texcoordtexture2f = texcoordtexture2f
	q3.data_texcoordlightmap2f = texcoordlightmap2f
	q3.data_color4f = color4f

	local sRGBlightmaps = cvar.Cvar_VariableValueOr("mod_q3bsp_sRGBlightmaps", 0) ~= 0
	-- vid_sRGB.integer && vid_sRGB_fallback.integer && !vid.sRGB3D (vid.sRGB3D: no GL framebuffer here, false)
	local sRGBfallback = cvar.Cvar_VariableValueOr("vid_sRGB", 0) ~= 0
		and cvar.Cvar_VariableValueOr("vid_sRGB_fallback", 0) ~= 0
	local inv255 = R(1.0 / 255.0) -- (1.0f / 255.0f)

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dvertex_t
		buffer.copy(vertex3f, i * 12, mod_base, p, 12) -- origin3f
		buffer.copy(normal3f, i * 12, mod_base, p + 28, 12) -- normal3f
		buffer.copy(texcoordtexture2f, i * 8, mod_base, p + 12, 8) -- texcoord2f
		buffer.copy(texcoordlightmap2f, i * 8, mod_base, p + 20, 8) -- lightmap2f
		local c0, c1, c2, c3 =
			readu8(mod_base, p + 40), readu8(mod_base, p + 41), readu8(mod_base, p + 42), readu8(mod_base, p + 43)
		-- svector/tvector are calculated later in face loading
		if sRGBlightmaps then
			-- if lightmaps are sRGB, vertex colors are sRGB too, so we need to linearize them
			-- note: when this is in use, lightmap color 128 is no longer neutral, but "sRGB half power" is
			-- working like this may be odd, but matches q3map2 -gamma 2.2
			if sRGBfallback then
				writef32(color4f, i * 16 + 0, c0 * inv255)
				writef32(color4f, i * 16 + 4, c1 * inv255)
				writef32(color4f, i * 16 + 8, c2 * inv255)
				-- we fix the brightness consistently via lightmapscale
			else
				error("NOT YET PORTED: Image_LinearFloatFromsRGB (image.c) for mod_q3bsp_sRGBlightmaps 1")
			end
		else
			if sRGBfallback then
				error("NOT YET PORTED: Image_sRGBFloatFromLinear_Lightmap (image.c) for vid_sRGB + vid_sRGB_fallback")
			else
				writef32(color4f, i * 16 + 0, c0 * inv255)
				writef32(color4f, i * 16 + 4, c1 * inv255)
				writef32(color4f, i * 16 + 8, c2 * inv255)
			end
		end
		writef32(color4f, i * 16 + 12, c3 * inv255)
		if c0 ~= 255 or c1 ~= 255 or c2 ~= 255 then
			loadmodel.lit = true
		end
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadTriangles L5556-5588 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadTriangles(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % 12 ~= 0 then -- sizeof(int[3])
		Host_Error("Mod_Q3BSP_LoadTriangles: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // 4

	if loadmodel.brushq3.num_vertices == 0 then
		if count ~= 0 then
			Con_Printf(
				"Mod_Q3BSP_LoadTriangles: %s has triangles but no vertexes, broken compiler, ignoring problem\n",
				loadmodel.name
			)
		end
		loadmodel.brushq3.num_triangles = 0
		return
	end

	local out = buffer.create(count * 4)
	loadmodel.brushq3.num_triangles = count // 3
	loadmodel.brushq3.data_element3i = out

	for i = 0, count - 1 do
		local e = readi32(mod_base, inofs + i * 4)
		if e < 0 or e >= loadmodel.brushq3.num_vertices then
			Con_Printf(
				"Mod_Q3BSP_LoadTriangles: invalid vertexindex %i (%i vertices), setting to 0\n",
				e,
				loadmodel.brushq3.num_vertices
			)
			e = 0
		end
		writei32(out, i * 4, e)
	end
end

-- model_brush.c Mod_Q3BSP_LoadLightmaps L5590-5865: NOT YET PORTED
local function Mod_Q3BSP_LoadLightmaps(_l: lump_t, _faceslump: lump_t)
	NOT_YET_PORTED("Mod_Q3BSP_LoadLightmaps (model_brush.c L5590-5865)")
end

-- port: model_brush.c Mod_Q3BSP_BuildBBoxes L5867-5912 @xonotic-v0.8.6
-- (element3i: i32 buffer + byte offset; returns *collisionbbox6f (nil = NULL) and *collisionstride)
local function Mod_Q3BSP_BuildBBoxes(
	element3i: buffer,
	eofs: number,
	num_triangles: number,
	vertex3f: buffer,
	stride: number
): (buffer?, number)
	if stride > 0 then
		local cnt = (num_triangles + stride - 1) // stride
		local bbox6f = buffer.create(24 * cnt)
		for j = 0, cnt - 1 do
			local mins = 24 * j
			local maxs = 24 * j + 12
			for k = 0, stride - 1 do
				local tri = j * stride + k
				if tri >= num_triangles then
					break
				end
				for corner = 0, 2 do
					local vert = readi32(element3i, eofs + (3 * tri + corner) * 4) * 12
					for c = 0, 2 do
						local x = readf32(vertex3f, vert + c * 4)
						if (corner == 0 and k == 0) or x < readf32(bbox6f, mins + c * 4) then
							writef32(bbox6f, mins + c * 4, x)
						end
						if (corner == 0 and k == 0) or x > readf32(bbox6f, maxs + c * 4) then
							writef32(bbox6f, maxs + c * 4, x)
						end
					end
				end
			end
		end
		return bbox6f, stride
	else
		return nil, stride
	end
end

-- model_brush.c patchtess_t L5913-5921
type patchtess_t = {
	info: curves.patchinfo_t,
	-- Auxiliary data used only by patch loading code in Mod_Q3BSP_LoadFaces
	surface_id: number,
	lodgroup: { number },
	originalvertex3f: number, -- byte offset into brushq3.data_vertex3f
}

-- model_brush.c PATCHTESS_SAME_LODGROUP L5923-5931
local function PATCHTESS_SAME_LODGROUP(a: patchtess_t, b: patchtess_t): boolean
	return a.lodgroup[1] == b.lodgroup[1]
		and a.lodgroup[2] == b.lodgroup[2]
		and a.lodgroup[3] == b.lodgroup[3]
		and a.lodgroup[4] == b.lodgroup[4]
		and a.lodgroup[5] == b.lodgroup[5]
		and a.lodgroup[6] == b.lodgroup[6]
end

-- quakedef.h bound()
local function bound(min: number, num: number, max: number): number
	return if num >= min then (if num < max then num else max) else min
end

-- cvar_t.integer / cvar_t.value with the engine default when the cvar is not registered (Mod_BrushInit and
-- the renderer's cvar registration are not ported yet)
local function cvi(name: string, def: number): number
	return libc.toint(cvar.Cvar_VariableValueOr(name, def))
end
local function cvf(name: string, def: number): number
	return R(cvar.Cvar_VariableValueOr(name, def))
end

-- A zeroed msurface_t (model_shared.h; C: Mem_Alloc). Fields are added as their users are ported.
local function newsurface(index: number): any
	return {
		index = index, -- 0-based position in data_surfaces (port support)
		texture = nil,
		effect = nil,
		lightmaptexture = nil,
		deluxemaptexture = nil,
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		num_vertices = 0,
		num_triangles = 0,
		num_firstvertex = 0,
		num_firsttriangle = 0,
		num_collisionvertices = 0,
		num_collisiontriangles = 0,
		num_firstcollisiontriangle = 0,
		deprecatedq3data_collisionvertex3f = nil,
		deprecatedq3data_collisionelement3i = nil,
		deprecatedq3data_collisionbbox6f = nil,
		deprecatedq3num_collisionbboxstride = 0,
		deprecatedq3data_bbox6f = nil,
		deprecatedq3num_bboxstride = 0,
		deprecatedq3collisionmarkframe = 0, -- don't collide twice in one trace
	}
end

-- port: model_brush.c Mod_Q3BSP_LoadFaces L5934-6416 @xonotic-v0.8.6
-- The lightmap parts (cls.state != ca_dedicated: lightmaptexture / deluxemaptexture and the lightmap texcoord
-- remapping into merged lightmaps) need Mod_Q3BSP_LoadLightmaps and are NOT YET PORTED: surfaces are loaded as
-- a dedicated server loads them (model_brush.dedicated).
local function Mod_Q3BSP_LoadFaces(l: lump_t)
	local inofs = l.fileofs
	local patchsize = { 0, 0 }
	local patchtess: { patchtess_t } = {}
	local patchtesscount = 0
	local again: boolean
	local q3 = loadmodel.brushq3
	local developer_extra = cvi("developer_extra", 0) ~= 0

	if l.filelen % SIZEOF_q3dface_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadFaces: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dface_t
	local out: { any } = table.create(count)
	for i = 0, count - 1 do
		out[i + 1] = newsurface(i)
	end

	loadmodel.data_surfaces = out
	loadmodel.num_surfaces = count

	local meshvertices = 0
	local meshtriangles = 0
	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dface_t
		local surface = out[i + 1]
		-- check face type first
		local type = readi32(mod_base, p + 8)
		if
			type ~= Q3FACETYPE_FLAT
			and type ~= Q3FACETYPE_PATCH
			and type ~= Q3FACETYPE_MESH
			and type ~= Q3FACETYPE_FLARE
		then
			Con_DPrintf("Mod_Q3BSP_LoadFaces: face #%i: unknown face type %i\n", i, type)
			continue
		end

		local n = readi32(mod_base, p)
		if n < 0 or n >= loadmodel.num_textures then
			Con_DPrintf(
				"Mod_Q3BSP_LoadFaces: face #%i: invalid textureindex %i (%i textures)\n",
				i,
				n,
				loadmodel.num_textures
			)
			continue
		end
		surface.texture = loadmodel.data_textures[n + 1]
		n = readi32(mod_base, p + 4)
		if n < -1 or n >= q3.num_effects then
			if developer_extra then
				Con_DPrintf(
					'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): invalid effectindex %i (%i effects)\n',
					i,
					surface.texture.name,
					n,
					q3.num_effects
				)
			end
			n = -1
		end
		if n == -1 then
			surface.effect = nil
		else
			surface.effect = q3.data_effects[n + 1]
		end

		if not model_brush.dedicated then
			NOT_YET_PORTED(
				"Mod_Q3BSP_LoadFaces: lightmap / deluxemap textures of a surface (client, needs Mod_Q3BSP_LoadLightmaps)"
			)
		end

		local firstvertex = readi32(mod_base, p + 12)
		local numvertices = readi32(mod_base, p + 16)
		local firstelement = readi32(mod_base, p + 20)
		local numelements = readi32(mod_base, p + 24)
		local numtriangles = libc.toint(numelements / 3)
		if numtriangles * 3 ~= numelements then
			Con_Printf(
				'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): numelements %i is not a multiple of 3\n',
				i,
				surface.texture.name,
				numelements
			)
			continue
		end
		if firstvertex < 0 or firstvertex + numvertices > q3.num_vertices then
			Con_Printf(
				'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): invalid vertex range %i : %i (%i vertices)\n',
				i,
				surface.texture.name,
				firstvertex,
				firstvertex + numvertices,
				q3.num_vertices
			)
			continue
		end
		if firstelement < 0 or firstelement + numtriangles * 3 > q3.num_triangles * 3 then
			Con_Printf(
				'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): invalid element range %i : %i (%i elements)\n',
				i,
				surface.texture.name,
				firstelement,
				firstelement + numtriangles * 3,
				q3.num_triangles * 3
			)
			continue
		end
		if type == Q3FACETYPE_PATCH then
			patchsize[1] = readi32(mod_base, p + 96) -- specific.patch.patchsize[0]
			patchsize[2] = readi32(mod_base, p + 100)
			if
				numvertices ~= (patchsize[1] * patchsize[2])
				or patchsize[1] < 3
				or patchsize[2] < 3
				or bit32.band(patchsize[1], 1) == 0
				or bit32.band(patchsize[2], 1) == 0
				or patchsize[1] * patchsize[2]
					>= math.min(
						cvi("r_subdivisions_maxvertices", 65536),
						cvi("r_subdivisions_collision_maxvertices", 4225)
					)
			then
				Con_Printf(
					'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): invalid patchsize %ix%i\n',
					i,
					surface.texture.name,
					patchsize[1],
					patchsize[2]
				)
				continue
			end
			local originalvertex3f = firstvertex * 12
			local vertex3f: buffer = q3.data_vertex3f

			-- convert patch to Q3FACETYPE_MESH
			local xtess = curves.Q3PatchTesselationOnX(
				patchsize[1],
				patchsize[2],
				3,
				vertex3f,
				originalvertex3f,
				cvf("r_subdivisions_tolerance", 4)
			)
			local ytess = curves.Q3PatchTesselationOnY(
				patchsize[1],
				patchsize[2],
				3,
				vertex3f,
				originalvertex3f,
				cvf("r_subdivisions_tolerance", 4)
			)
			-- bound to user settings
			xtess = bound(cvi("r_subdivisions_mintess", 0), xtess, cvi("r_subdivisions_maxtess", 1024))
			ytess = bound(cvi("r_subdivisions_mintess", 0), ytess, cvi("r_subdivisions_maxtess", 1024))
			-- bound to sanity settings
			xtess = bound(0, xtess, 1024)
			ytess = bound(0, ytess, 1024)

			-- lower quality collision patches! Same procedure as before, but different cvars
			-- convert patch to Q3FACETYPE_MESH
			local cxtess = curves.Q3PatchTesselationOnX(
				patchsize[1],
				patchsize[2],
				3,
				vertex3f,
				originalvertex3f,
				cvf("r_subdivisions_collision_tolerance", 15)
			)
			local cytess = curves.Q3PatchTesselationOnY(
				patchsize[1],
				patchsize[2],
				3,
				vertex3f,
				originalvertex3f,
				cvf("r_subdivisions_collision_tolerance", 15)
			)
			-- bound to user settings
			cxtess =
				bound(cvi("r_subdivisions_collision_mintess", 0), cxtess, cvi("r_subdivisions_collision_maxtess", 1024))
			cytess =
				bound(cvi("r_subdivisions_collision_mintess", 0), cytess, cvi("r_subdivisions_collision_maxtess", 1024))
			-- bound to sanity settings
			cxtess = bound(0, cxtess, 1024)
			cytess = bound(0, cytess, 1024)

			-- store it for the LOD grouping step
			patchtesscount += 1
			patchtess[patchtesscount] = {
				info = {
					xsize = patchsize[1],
					ysize = patchsize[2],
					-- lods[PATCH_LOD_COLLISION + 1], lods[PATCH_LOD_VISUAL + 1]
					lods = { { xtess = cxtess, ytess = cytess }, { xtess = xtess, ytess = ytess } },
				},
				surface_id = i,
				lodgroup = {
					readf32(mod_base, p + 60), -- specific.patch.mins
					readf32(mod_base, p + 64),
					readf32(mod_base, p + 68),
					readf32(mod_base, p + 72), -- specific.patch.maxs
					readf32(mod_base, p + 76),
					readf32(mod_base, p + 80),
				},
				originalvertex3f = originalvertex3f,
			}
		elseif type == Q3FACETYPE_FLARE then
			if developer_extra then
				Con_DPrintf(
					'Mod_Q3BSP_LoadFaces: face #%i (texture "%s"): Q3FACETYPE_FLARE not supported (yet)\n',
					i,
					surface.texture.name
				)
			end
			-- don't render it
			continue
		end
		-- (Q3FACETYPE_FLAT, Q3FACETYPE_MESH: no processing necessary)
		surface.num_vertices = numvertices
		surface.num_triangles = numtriangles
		meshvertices += surface.num_vertices
		meshtriangles += surface.num_triangles
	end

	-- Fix patches tesselations so that they make no seams
	repeat
		again = false
		for i = 1, patchtesscount do
			for j = i + 1, patchtesscount do
				if not PATCHTESS_SAME_LODGROUP(patchtess[i], patchtess[j]) then
					continue
				end

				if
					curves.Q3PatchAdjustTesselation(
						3,
						patchtess[i].info,
						q3.data_vertex3f,
						patchtess[i].originalvertex3f,
						patchtess[j].info,
						q3.data_vertex3f,
						patchtess[j].originalvertex3f
					)
				then
					again = true
				end
			end
		end
	until not again

	-- Calculate resulting number of triangles
	local collisionvertices = 0
	local collisiontriangles = 0
	for i = 1, patchtesscount do
		local pt = patchtess[i]
		local surface = out[pt.surface_id + 1]
		local finalwidth = curves.Q3PatchDimForTess(pt.info.xsize, pt.info.lods[PATCH_LOD_VISUAL + 1].xtess)
		local finalheight = curves.Q3PatchDimForTess(pt.info.ysize, pt.info.lods[PATCH_LOD_VISUAL + 1].ytess)
		local numvertices = finalwidth * finalheight
		local numtriangles = (finalwidth - 1) * (finalheight - 1) * 2

		surface.num_vertices = numvertices
		surface.num_triangles = numtriangles
		meshvertices += surface.num_vertices
		meshtriangles += surface.num_triangles

		finalwidth = curves.Q3PatchDimForTess(pt.info.xsize, pt.info.lods[PATCH_LOD_COLLISION + 1].xtess)
		finalheight = curves.Q3PatchDimForTess(pt.info.ysize, pt.info.lods[PATCH_LOD_COLLISION + 1].ytess)
		numvertices = finalwidth * finalheight
		numtriangles = (finalwidth - 1) * (finalheight - 1) * 2

		surface.num_collisionvertices = numvertices
		surface.num_collisiontriangles = numtriangles
		collisionvertices += surface.num_collisionvertices
		collisiontriangles += surface.num_collisiontriangles
	end

	model_shared.loadmodel = loadmodel
	model_shared.Mod_AllocSurfMesh(meshvertices, meshtriangles, false, true, false)
	local surfmesh = loadmodel.surfmesh
	if collisiontriangles ~= 0 then
		loadmodel.brush.data_collisionvertex3f = buffer.create(collisionvertices * 12)
		loadmodel.brush.data_collisionelement3i = buffer.create(collisiontriangles * 12)
	end
	meshvertices = 0
	meshtriangles = 0
	collisionvertices = 0
	collisiontriangles = 0
	local i = 0
	while i < count and meshvertices + out[i + 1].num_vertices <= surfmesh.num_vertices do
		local p = inofs + i * SIZEOF_q3dface_t
		local surface = out[i + 1]
		i += 1
		local fi = i - 1 -- the C loop variable i for this surface
		if surface.num_vertices < 3 or surface.num_triangles < 1 then
			continue
		end

		local type = readi32(mod_base, p + 8)
		local firstvertex = readi32(mod_base, p + 12)
		local firstelement = readi32(mod_base, p + 20)
		surface.num_firstvertex = meshvertices
		surface.num_firsttriangle = meshtriangles
		surface.num_firstcollisiontriangle = collisiontriangles
		local fv = surface.num_firstvertex
		local element3i: buffer = surfmesh.data_element3i
		local eo = 12 * surface.num_firsttriangle -- byte offset of (data_element3i + 3 * num_firsttriangle)
		if type == Q3FACETYPE_FLAT or type == Q3FACETYPE_MESH then
			-- no processing necessary, except for lightmap merging
			local nv = surface.num_vertices
			buffer.copy(surfmesh.data_vertex3f, 12 * fv, q3.data_vertex3f, firstvertex * 12, nv * 12)
			buffer.copy(surfmesh.data_normal3f, 12 * fv, q3.data_normal3f, firstvertex * 12, nv * 12)
			buffer.copy(surfmesh.data_texcoordtexture2f, 8 * fv, q3.data_texcoordtexture2f, firstvertex * 8, nv * 8)
			buffer.copy(surfmesh.data_texcoordlightmap2f, 8 * fv, q3.data_texcoordlightmap2f, firstvertex * 8, nv * 8)
			buffer.copy(surfmesh.data_lightmapcolor4f, 16 * fv, q3.data_color4f, firstvertex * 16, nv * 16)
			local src: buffer = q3.data_element3i
			for j = 0, surface.num_triangles * 3 - 1 do
				writei32(element3i, eo + j * 4, readi32(src, (firstelement + j) * 4) + fv)
			end
		elseif type == Q3FACETYPE_PATCH then
			patchsize[1] = readi32(mod_base, p + 96)
			patchsize[2] = readi32(mod_base, p + 100)
			local originalvertex3f = firstvertex * 12
			local originalnormal3f = firstvertex * 12
			local originaltexcoordtexture2f = firstvertex * 8
			local originaltexcoordlightmap2f = firstvertex * 8
			local originalcolor4f = firstvertex * 16

			local xtess, ytess, cxtess, cytess = -1, -1, -1, -1
			for j = 1, patchtesscount do
				if patchtess[j].surface_id == fi then
					xtess = patchtess[j].info.lods[PATCH_LOD_VISUAL + 1].xtess
					ytess = patchtess[j].info.lods[PATCH_LOD_VISUAL + 1].ytess
					cxtess = patchtess[j].info.lods[PATCH_LOD_COLLISION + 1].xtess
					cytess = patchtess[j].info.lods[PATCH_LOD_COLLISION + 1].ytess
					break
				end
			end
			if xtess == -1 then
				Con_Printf("ERROR: patch %d isn't preprocessed?!?\n", fi)
				xtess, ytess, cxtess, cytess = 0, 0, 0, 0
			end

			local finalwidth = curves.Q3PatchDimForTess(patchsize[1], xtess) --((patchsize[0] - 1) * xtess) + 1;
			local finalheight = curves.Q3PatchDimForTess(patchsize[2], ytess) --((patchsize[1] - 1) * ytess) + 1;
			local finalvertices = finalwidth * finalheight
			local finaltriangles = (finalwidth - 1) * (finalheight - 1) * 2
			local oldnumtriangles = finaltriangles
			type = Q3FACETYPE_MESH
			-- generate geometry
			-- (note: normals are skipped because they get recalculated)
			curves.Q3PatchTesselateFloat(
				3,
				12,
				surfmesh.data_vertex3f,
				12 * fv,
				patchsize[1],
				patchsize[2],
				12,
				q3.data_vertex3f,
				originalvertex3f,
				xtess,
				ytess
			)
			curves.Q3PatchTesselateFloat(
				3,
				12,
				surfmesh.data_normal3f,
				12 * fv,
				patchsize[1],
				patchsize[2],
				12,
				q3.data_normal3f,
				originalnormal3f,
				xtess,
				ytess
			)
			curves.Q3PatchTesselateFloat(
				2,
				8,
				surfmesh.data_texcoordtexture2f,
				8 * fv,
				patchsize[1],
				patchsize[2],
				8,
				q3.data_texcoordtexture2f,
				originaltexcoordtexture2f,
				xtess,
				ytess
			)
			curves.Q3PatchTesselateFloat(
				2,
				8,
				surfmesh.data_texcoordlightmap2f,
				8 * fv,
				patchsize[1],
				patchsize[2],
				8,
				q3.data_texcoordlightmap2f,
				originaltexcoordlightmap2f,
				xtess,
				ytess
			)
			curves.Q3PatchTesselateFloat(
				4,
				16,
				surfmesh.data_lightmapcolor4f,
				16 * fv,
				patchsize[1],
				patchsize[2],
				16,
				q3.data_color4f,
				originalcolor4f,
				xtess,
				ytess
			)
			curves.Q3PatchTriangleElements(element3i, eo, finalwidth, finalheight, fv)

			surface.num_triangles = model_shared.Mod_RemoveDegenerateTriangles(
				surface.num_triangles,
				element3i,
				eo,
				element3i,
				eo,
				surfmesh.data_vertex3f
			)

			if developer_extra then
				if surface.num_triangles < finaltriangles then
					Con_DPrintf(
						"Mod_Q3BSP_LoadFaces: %ix%i curve subdivided to %i vertices / %i triangles, %i degenerate triangles removed (leaving %i)\n",
						patchsize[1],
						patchsize[2],
						surface.num_vertices,
						finaltriangles,
						finaltriangles - surface.num_triangles,
						surface.num_triangles
					)
				else
					Con_DPrintf(
						"Mod_Q3BSP_LoadFaces: %ix%i curve subdivided to %i vertices / %i triangles\n",
						patchsize[1],
						patchsize[2],
						surface.num_vertices,
						surface.num_triangles
					)
				end
			end
			-- q3map does not put in collision brushes for curves... ugh
			-- build the lower quality collision geometry
			finalwidth = curves.Q3PatchDimForTess(patchsize[1], cxtess) --((patchsize[0] - 1) * cxtess) + 1;
			finalheight = curves.Q3PatchDimForTess(patchsize[2], cytess) --((patchsize[1] - 1) * cytess) + 1;
			finalvertices = finalwidth * finalheight
			finaltriangles = (finalwidth - 1) * (finalheight - 1) * 2
			local oldnumtriangles2 = finaltriangles

			-- legacy collision geometry implementation
			local cv = buffer.create(12 * finalvertices)
			local ce = buffer.create(12 * finaltriangles)
			surface.deprecatedq3data_collisionvertex3f = cv
			surface.deprecatedq3data_collisionelement3i = ce
			surface.num_collisionvertices = finalvertices
			surface.num_collisiontriangles = finaltriangles
			curves.Q3PatchTesselateFloat(
				3,
				12,
				cv,
				0,
				patchsize[1],
				patchsize[2],
				12,
				q3.data_vertex3f,
				originalvertex3f,
				cxtess,
				cytess
			)
			curves.Q3PatchTriangleElements(ce, 0, finalwidth, finalheight, 0)

			--Mod_SnapVertices(3, out->num_vertices, (loadmodel->surfmesh.data_vertex3f + 3 * out->num_firstvertex), 0.25);
			model_shared.Mod_SnapVertices(3, finalvertices, cv, 0, 1)

			surface.num_collisiontriangles =
				model_shared.Mod_RemoveDegenerateTriangles(finaltriangles, ce, 0, ce, 0, cv)

			-- now optimize the collision mesh by finding triangle bboxes...
			surface.deprecatedq3data_collisionbbox6f, surface.deprecatedq3num_collisionbboxstride =
				Mod_Q3BSP_BuildBBoxes(
					ce,
					0,
					surface.num_collisiontriangles,
					cv,
					cvi("mod_q3bsp_curves_collisions_stride", 16)
				)
			surface.deprecatedq3data_bbox6f, surface.deprecatedq3num_bboxstride = Mod_Q3BSP_BuildBBoxes(
				element3i,
				eo,
				surface.num_triangles,
				surfmesh.data_vertex3f,
				cvi("mod_q3bsp_curves_stride", 16)
			)

			-- store collision geometry for BIH collision tree
			local scv: buffer = loadmodel.brush.data_collisionvertex3f
			local sce: buffer = loadmodel.brush.data_collisionelement3i
			local scvo = collisionvertices * 12
			local sceo = collisiontriangles * 12
			curves.Q3PatchTesselateFloat(
				3,
				12,
				scv,
				scvo,
				patchsize[1],
				patchsize[2],
				12,
				q3.data_vertex3f,
				originalvertex3f,
				cxtess,
				cytess
			)
			curves.Q3PatchTriangleElements(sce, sceo, finalwidth, finalheight, collisionvertices)
			model_shared.Mod_SnapVertices(3, finalvertices, scv, scvo, 1)
			-- remove this once the legacy code is removed
			local nc = surface.num_collisiontriangles
			surface.num_collisiontriangles =
				model_shared.Mod_RemoveDegenerateTriangles(finaltriangles, sce, sceo, sce, sceo, scv)
			if nc ~= surface.num_collisiontriangles then
				Con_Printf("number of collision triangles differs between BIH and BSP. FAIL.\n")
			end

			if developer_extra then
				Con_DPrintf(
					"Mod_Q3BSP_LoadFaces: %ix%i curve became %i:%i vertices / %i:%i triangles (%i:%i degenerate)\n",
					patchsize[1],
					patchsize[2],
					surface.num_vertices,
					surface.num_collisionvertices,
					oldnumtriangles,
					oldnumtriangles2,
					oldnumtriangles - surface.num_triangles,
					oldnumtriangles2 - surface.num_collisiontriangles
				)
			end

			collisionvertices += finalvertices
			collisiontriangles += surface.num_collisiontriangles
		end
		meshvertices += surface.num_vertices
		meshtriangles += surface.num_triangles
		local invalidelements = 0
		for j = 0, surface.num_triangles * 3 - 1 do
			local e = readi32(element3i, eo + j * 4)
			if e < fv or e >= fv + surface.num_vertices then
				invalidelements += 1
			end
		end
		if invalidelements ~= 0 then
			Con_Printf(
				'Mod_Q3BSP_LoadFaces: Warning: face #%i has %i invalid elements, type = %i, texture->name = "%s", texture->surfaceflags = %i, firstvertex = %i, numvertices = %i, firstelement = %i, numelements = %i, elements list:\n',
				fi,
				invalidelements,
				type,
				surface.texture.name,
				surface.texture.surfaceflags,
				firstvertex,
				surface.num_vertices,
				firstelement,
				surface.num_triangles * 3
			)
			for j = 0, surface.num_triangles * 3 - 1 do
				local e = readi32(element3i, eo + j * 4)
				Con_Printf(" %i", e - fv)
				if e < fv or e >= fv + surface.num_vertices then
					writei32(element3i, eo + j * 4, fv)
				end
			end
			Con_Print("\n")
		end
		-- calculate a bounding box
		local mins, maxs = surface.mins, surface.maxs
		mins[1], mins[2], mins[3] = 0, 0, 0
		maxs[1], maxs[2], maxs[3] = 0, 0, 0
		if surface.num_vertices ~= 0 then
			-- (cls.state != ca_dedicated && out->lightmaptexture: lightmap texcoords are remapped into the merged
			-- lightmap; NOT YET PORTED, see the note above the function)
			local vertex3f: buffer = surfmesh.data_vertex3f
			for c = 1, 3 do
				mins[c] = readf32(vertex3f, 12 * fv + (c - 1) * 4)
				maxs[c] = mins[c]
			end
			for j = 1, surface.num_vertices - 1 do
				local v = 12 * (fv + j)
				for c = 1, 3 do
					local x = readf32(vertex3f, v + (c - 1) * 4)
					mins[c] = math.min(mins[c], x)
					maxs[c] = math.max(maxs[c], x)
				end
			end
			for c = 1, 3 do
				mins[c] = R(mins[c] - 1.0)
				maxs[c] = R(maxs[c] + 1.0)
			end
		end
		-- set lightmap styles for consistency with q1bsp
		--out->lightmapinfo->styles[0] = 0;
		--out->lightmapinfo->styles[1] = 255;
		--out->lightmapinfo->styles[2] = 255;
		--out->lightmapinfo->styles[3] = 255;
	end

	for si = 0, count - 1 do
		local surface = out[si + 1]
		if surface.num_vertices ~= 0 and surface.num_triangles ~= 0 then
			continue
		end
		local texname = if surface.texture then surface.texture.name else "(none)"
		if surface.num_vertices == 0 then
			Con_Printf("Mod_Q3BSP_LoadFaces: surface %d (texture %s) has no vertices, ignoring\n", si, texname)
			if surface.num_triangles == 0 then
				Con_Printf("Mod_Q3BSP_LoadFaces: surface %d (texture %s) has no triangles, ignoring\n", si, texname)
			end
		elseif surface.num_triangles == 0 then
			local vertex3f: buffer = surfmesh.data_vertex3f
			local fv = surface.num_firstvertex
			Con_Printf(
				"Mod_Q3BSP_LoadFaces: surface %d (texture %s, near %f %f %f) has no triangles, ignoring\n",
				si,
				texname,
				readf32(vertex3f, 12 * fv + 0 * 12),
				readf32(vertex3f, 12 * fv + 1 * 12),
				readf32(vertex3f, 12 * fv + 2 * 12)
			)
		end
	end

	-- for per pixel lighting
	if surfmesh.num_vertices ~= 0 and surfmesh.num_triangles ~= 0 then
		model_shared.Mod_BuildTextureVectorsFromNormals(
			0,
			surfmesh.num_vertices,
			surfmesh.num_triangles,
			surfmesh.data_vertex3f,
			surfmesh.data_texcoordtexture2f,
			surfmesh.data_normal3f,
			surfmesh.data_element3i,
			0,
			surfmesh.data_svector3f,
			surfmesh.data_tvector3f,
			cvi("r_smoothnormals_areaweighting", 1) ~= 0
		)
	end

	-- generate ushort elements array if possible
	if surfmesh.data_element3s then
		local e3s: buffer = surfmesh.data_element3s
		local e3i: buffer = surfmesh.data_element3i
		for j = 0, surfmesh.num_triangles * 3 - 1 do
			buffer.writeu16(e3s, j * 2, bit32.band(readi32(e3i, j * 4), 0xFFFF))
		end
	end

	-- free the no longer needed vertex data
	q3.num_vertices = 0
	q3.data_vertex3f = nil
	q3.data_normal3f = nil
	q3.data_texcoordtexture2f = nil
	q3.data_texcoordlightmap2f = nil
	q3.data_color4f = nil
	-- free the no longer needed triangle data
	q3.num_triangles = 0
	q3.data_element3i = nil
end

-- port: model_brush.c Mod_Q3BSP_LoadModels L6418-6453 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadModels(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dmodel_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadModels: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dmodel_t
	local out: { q3dmodel_t } = table.create(count)

	loadmodel.brushq3.data_models = out
	loadmodel.brushq3.num_models = count

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dmodel_t
		local mins, maxs = { 0, 0, 0 }, { 0, 0, 0 }
		for j = 0, 2 do
			mins[j + 1] = readf32(mod_base, p + j * 4)
			maxs[j + 1] = readf32(mod_base, p + 12 + j * 4)
		end
		local n = readi32(mod_base, p + 24)
		local c = readi32(mod_base, p + 28)
		if n < 0 or n + c > loadmodel.num_surfaces then
			Host_Error("Mod_Q3BSP_LoadModels: invalid face range %i : %i (%i faces)", n, n + c, loadmodel.num_surfaces)
		end
		local firstface, numfaces = n, c
		n = readi32(mod_base, p + 32)
		c = readi32(mod_base, p + 36)
		if n < 0 or n + c > loadmodel.brush.num_brushes then
			Host_Error(
				"Mod_Q3BSP_LoadModels: invalid brush range %i : %i (%i brushes)",
				n,
				n + c,
				loadmodel.brush.num_brushes
			)
		end
		out[i + 1] =
			{ mins = mins, maxs = maxs, firstface = firstface, numfaces = numfaces, firstbrush = n, numbrushes = c }
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadLeafBrushes L6455-6477 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadLeafBrushes(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % 4 ~= 0 then
		Host_Error("Mod_Q3BSP_LoadLeafBrushes: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // 4
	local out = buffer.create(count * 4)

	loadmodel.brush.data_leafbrushes = out
	loadmodel.brush.num_leafbrushes = count

	for i = 0, count - 1 do
		local n = readi32(mod_base, inofs + i * 4)
		if n < 0 or n >= loadmodel.brush.num_brushes then
			Host_Error("Mod_Q3BSP_LoadLeafBrushes: invalid brush index %i (%i brushes)", n, loadmodel.brush.num_brushes)
		end
		writei32(out, i * 4, n)
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadLeafFaces L6479-6501 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadLeafFaces(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % 4 ~= 0 then
		Host_Error("Mod_Q3BSP_LoadLeafFaces: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // 4
	local out = buffer.create(count * 4)

	loadmodel.brush.data_leafsurfaces = out
	loadmodel.brush.num_leafsurfaces = count

	for i = 0, count - 1 do
		local n = readi32(mod_base, inofs + i * 4)
		if n < 0 or n >= loadmodel.num_surfaces then
			Host_Error("Mod_Q3BSP_LoadLeafFaces: invalid face index %i (%i faces)", n, loadmodel.num_surfaces)
		end
		writei32(out, i * 4, n)
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadLeafs L6503-6543 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadLeafs(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dleaf_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadLeafs: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dleaf_t
	local out: { mnode_t } = table.create(count)

	loadmodel.brush.data_leafs = out
	loadmodel.brush.num_leafs = count

	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dleaf_t
		local mins, maxs = { 0, 0, 0 }, { 0, 0, 0 }
		for j = 0, 2 do
			-- yes the mins/maxs are ints
			mins[j + 1] = readi32(mod_base, p + 8 + j * 4) - 1
			maxs[j + 1] = readi32(mod_base, p + 20 + j * 4) + 1
		end
		local n = readi32(mod_base, p + 32)
		local c = readi32(mod_base, p + 36)
		if n < 0 or n + c > loadmodel.brush.num_leafsurfaces then
			Host_Error(
				"Mod_Q3BSP_LoadLeafs: invalid leafsurface range %i : %i (%i leafsurfaces)",
				n,
				n + c,
				loadmodel.brush.num_leafsurfaces
			)
		end
		local firstleafsurface, numleafsurfaces = n, c
		n = readi32(mod_base, p + 40)
		c = readi32(mod_base, p + 44)
		if n < 0 or n + c > loadmodel.brush.num_leafbrushes then
			Host_Error(
				"Mod_Q3BSP_LoadLeafs: invalid leafbrush range %i : %i (%i leafbrushes)",
				n,
				n + c,
				loadmodel.brush.num_leafbrushes
			)
		end
		out[i + 1] = {
			index = i,
			parent = nil,
			plane = nil,
			mins = mins,
			maxs = maxs,
			combinedsupercontents = 0,
			children = {},
			clusterindex = readi32(mod_base, p),
			areaindex = readi32(mod_base, p + 4),
			containscollisionsurfaces = false,
			numleafsurfaces = numleafsurfaces,
			firstleafsurface = firstleafsurface,
			numleafbrushes = c,
			firstleafbrush = n,
		}
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadNodes L6545-6596 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadNodes(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dnode_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadNodes: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dnode_t
	if count == 0 then
		Host_Error("Mod_Q3BSP_LoadNodes: missing BSP tree in %s", loadmodel.name)
	end
	local out: { mnode_t } = table.create(count)

	loadmodel.brush.data_nodes = out
	loadmodel.brush.num_nodes = count

	-- C fills children with pointers into the (already allocated) array: create every node record first
	for i = 0, count - 1 do
		out[i + 1] = {
			index = i,
			parent = nil,
			plane = nil,
			mins = { 0, 0, 0 },
			maxs = { 0, 0, 0 },
			combinedsupercontents = 0,
			children = {},
			clusterindex = 0,
			areaindex = 0,
			containscollisionsurfaces = false,
			numleafsurfaces = 0,
			firstleafsurface = 0,
			numleafbrushes = 0,
			firstleafbrush = 0,
		}
	end
	local leafs: { mnode_t } = loadmodel.brush.data_leafs
	for i = 0, count - 1 do
		local p = inofs + i * SIZEOF_q3dnode_t
		local node = out[i + 1]
		node.parent = nil
		local n = readi32(mod_base, p)
		if n < 0 or n >= loadmodel.brush.num_planes then
			Host_Error("Mod_Q3BSP_LoadNodes: invalid planeindex %i (%i planes)", n, loadmodel.brush.num_planes)
		end
		node.plane = loadmodel.brush.data_planes[n + 1]
		for j = 0, 1 do
			n = readi32(mod_base, p + 4 + j * 4)
			if n >= 0 then
				if n >= loadmodel.brush.num_nodes then
					Host_Error(
						"Mod_Q3BSP_LoadNodes: invalid child node index %i (%i nodes)",
						n,
						loadmodel.brush.num_nodes
					)
				end
				node.children[j + 1] = out[n + 1]
			else
				n = -1 - n
				if n >= loadmodel.brush.num_leafs then
					Host_Error(
						"Mod_Q3BSP_LoadNodes: invalid child leaf index %i (%i leafs)",
						n,
						loadmodel.brush.num_leafs
					)
				end
				node.children[j + 1] = leafs[n + 1]
			end
		end
		for j = 0, 2 do
			-- yes the mins/maxs are ints
			node.mins[j + 1] = readi32(mod_base, p + 12 + j * 4) - 1
			node.maxs[j + 1] = readi32(mod_base, p + 24 + j * 4) + 1
		end
	end

	-- set the parent pointers
	Mod_Q1BSP_LoadNodes_RecursiveSetParent(out[1], nil)
end

-- port: model_brush.c Mod_Q3BSP_LoadLightGrid L6598-6679 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadLightGrid(l: lump_t)
	local inofs = l.fileofs
	if l.filelen % SIZEOF_q3dlightgrid_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadLightGrid: funny lump size in %s", loadmodel.name)
	end
	local q3 = loadmodel.brushq3
	local cellsize: { number } = q3.num_lightgrid_cellsize
	local scale: { number } = q3.num_lightgrid_scale
	local imins: { number } = q3.num_lightgrid_imins
	local imaxs: { number } = q3.num_lightgrid_imaxs
	local isize: { number } = q3.num_lightgrid_isize
	local model0: q3dmodel_t = q3.data_models[1]
	for k = 1, 3 do
		scale[k] = R(1.0 / cellsize[k])
	end
	for k = 1, 3 do
		imins[k] = math.ceil(R(model0.mins[k] * scale[k])) + 0 -- (int): + 0 turns a Luau -0 into 0
	end
	for k = 1, 3 do
		imaxs[k] = math.floor(R(model0.maxs[k] * scale[k])) + 0
	end
	for k = 1, 3 do
		isize[k] = imaxs[k] - imins[k] + 1
	end
	local count = isize[1] * isize[2] * isize[3]
	matrixlib.Matrix4x4_CreateScale3(q3.num_lightgrid_indexfromworld, scale[1], scale[2], scale[3])
	matrixlib.Matrix4x4_ConcatTranslate(
		q3.num_lightgrid_indexfromworld,
		R(-imins[1] * cellsize[1]),
		R(-imins[2] * cellsize[2]),
		R(-imins[3] * cellsize[3])
	)

	-- if lump is empty there is nothing to load, we can deal with that in the LightPoint code
	if l.filelen ~= 0 then
		if l.filelen < count * SIZEOF_q3dlightgrid_t then
			Con_Printf(
				"Mod_Q3BSP_LoadLightGrid: invalid lightgrid lump size %i bytes, should be %i bytes (%ix%ix%i)",
				l.filelen,
				count * SIZEOF_q3dlightgrid_t,
				isize[1],
				isize[2],
				isize[3]
			)
			return -- ignore the grid if we cannot understand it
		end
		if l.filelen ~= count * SIZEOF_q3dlightgrid_t then
			Con_Printf(
				"Mod_Q3BSP_LoadLightGrid: Warning: calculated lightgrid size %i bytes does not match lump size %i\n",
				count * SIZEOF_q3dlightgrid_t,
				l.filelen
			)
		end
		local out = buffer.create(count * SIZEOF_q3dlightgrid_t)
		q3.data_lightgrid = out
		q3.num_lightgrid = count
		-- no swapping or validation necessary
		buffer.copy(out, 0, mod_base, inofs, count * SIZEOF_q3dlightgrid_t)

		local sRGBfallback = cvar.Cvar_VariableValueOr("vid_sRGB", 0) ~= 0
			and cvar.Cvar_VariableValueOr("vid_sRGB_fallback", 0) ~= 0
		if cvar.Cvar_VariableValueOr("mod_q3bsp_sRGBlightmaps", 0) ~= 0 then
			-- with the sRGB fallback: we fix the brightness consistently via lightmapscale
			if not sRGBfallback then
				error("NOT YET PORTED: Image_LinearFloatFromsRGB (image.c) for mod_q3bsp_sRGBlightmaps 1")
			end
		elseif sRGBfallback then
			error("NOT YET PORTED: Image_sRGBFloatFromLinear_Lightmap (image.c) for vid_sRGB + vid_sRGB_fallback")
		end
		-- otherwise: all is good
	end
end

-- port: model_brush.c Mod_Q3BSP_LoadPVS L6681-6717 @xonotic-v0.8.6
local function Mod_Q3BSP_LoadPVS(l: lump_t)
	local totalchains: number

	if l.filelen == 0 then
		-- unvised maps often have cluster indices even without pvs, so check
		-- leafs to find real number of clusters
		loadmodel.brush.num_pvsclusters = 1
		local leafs: { mnode_t } = loadmodel.brush.data_leafs
		for i = 0, loadmodel.brush.num_leafs - 1 do
			loadmodel.brush.num_pvsclusters = math.max(loadmodel.brush.num_pvsclusters, leafs[i + 1].clusterindex + 1)
		end

		-- create clusters
		loadmodel.brush.num_pvsclusterbytes = (loadmodel.brush.num_pvsclusters + 7) // 8
		totalchains = loadmodel.brush.num_pvsclusterbytes * loadmodel.brush.num_pvsclusters
		local pvs = buffer.create(totalchains)
		buffer.fill(pvs, 0, 0xFF)
		loadmodel.brush.data_pvsclusters = pvs
		return
	end

	local inofs = l.fileofs
	if l.filelen < 9 then
		Host_Error("Mod_Q3BSP_LoadPVS: funny lump size in %s", loadmodel.name)
	end

	loadmodel.brush.num_pvsclusters = readi32(mod_base, inofs)
	loadmodel.brush.num_pvsclusterbytes = readi32(mod_base, inofs + 4)
	if loadmodel.brush.num_pvsclusterbytes < ((loadmodel.brush.num_pvsclusters + 7) // 8) then
		Host_Error(
			"Mod_Q3BSP_LoadPVS: (chainlength = %i) < ((numclusters = %i) + 7) / 8",
			loadmodel.brush.num_pvsclusterbytes,
			loadmodel.brush.num_pvsclusters
		)
	end
	totalchains = loadmodel.brush.num_pvsclusterbytes * loadmodel.brush.num_pvsclusters
	if l.filelen < totalchains + SIZEOF_q3dpvs_t then
		Host_Error(
			"Mod_Q3BSP_LoadPVS: lump too small ((numclusters = %i) * (chainlength = %i) + sizeof(q3dpvs_t) == %i bytes, lump is %i bytes)",
			loadmodel.brush.num_pvsclusters,
			loadmodel.brush.num_pvsclusterbytes,
			totalchains + SIZEOF_q3dpvs_t,
			l.filelen
		)
	end

	local pvs = buffer.create(totalchains)
	buffer.copy(pvs, 0, mod_base, inofs + SIZEOF_q3dpvs_t, totalchains)
	loadmodel.brush.data_pvsclusters = pvs
end

-- model_brush.h MATERIALFLAG_* L73-123 (the ones read here)
local MATERIALFLAG_MESHCOLLISIONS = 0x00000001
local MATERIALFLAG_SKY = 0x00000080
local MATERIALFLAG_WATERSHADER = 0x00040000
local MATERIALFLAG_REFRACTION = 0x00080000
local MATERIALFLAG_REFLECTION = 0x00100000
local MATERIALFLAG_CAMERA = 0x02000000

-- ---------------------------------------------------------------------------------------------------------
-- Tracing (model_brush.c L6800-7677)

-- model_brush.h L133, bspfile.h L214
local MATERIALFLAGMASK_TRANSLUCENT = 0x00000010
	+ 0x00000080
	+ 0x00000200
	+ 0x00000800
	+ 0x00001000
	+ 0x00040000
	+ 0x00080000
local SUPERCONTENTS_VISBLOCKERMASK = SUPERCONTENTS_OPAQUE

local BIH_SPLITX, BIH_SPLITZ, BIH_UNORDERED = bih.BIH_SPLITX, bih.BIH_SPLITZ, bih.BIH_UNORDERED
local BIH_BRUSH, BIH_COLLISIONTRIANGLE, BIH_RENDERTRIANGLE =
	bih.BIH_BRUSH, bih.BIH_COLLISIONTRIANGLE, bih.BIH_RENDERTRIANGLE
local BIH_MAXUNORDEREDCHILDREN = bih.BIH_MAXUNORDEREDCHILDREN

-- model_brush.c L46-64: the static cvar_t that the trace functions read as struct fields (same scheme as
-- collision.cv: 0 until Mod_BrushInit registers them, as in C). The loader still reads its cvars with cvi().
local TRACE_CVAR_DEFS: { { string } } = {
	{ "mod_q3bsp_curves_collisions", "1", "enables collisions with curves (SLOW)" },
	{
		"mod_q3bsp_optimizedtraceline",
		"1",
		"whether to use optimized traceline code for line traces (as opposed to tracebox code)",
	},
	{
		"mod_q3bsp_tracelineofsight_brushes",
		"0",
		"enables culling of entities behind detail brushes, curves, etc",
	},
	{
		"mod_collision_bih",
		"1",
		"enables use of generated Bounding Interval Hierarchy tree instead of compiled bsp tree in collision code",
	},
}
local cv: { [string]: cvar.Cvar } = {}
for _, d in TRACE_CVAR_DEFS do
	cv[d[1]] = cvar.static(0, d[1], d[2], d[3])
end
model_brush.cv = cv

-- port: model_brush.c Mod_BrushInit L75-143 @xonotic-v0.8.6
-- PARTIAL: the four cvars above (a cvar host.luau already registered is this file's cvar_t, see
-- collision.Collision_Init). NOT YET PORTED: the other Cvar_RegisterVariable calls (the loader reads those
-- cvars by name), the GAME_NEXUIZ hack and the mod_q1bsp_texture_* records (Q1BSP loader).
function model_brush.Mod_BrushInit()
	for _, d in TRACE_CVAR_DEFS do
		local existing = cvar.Cvar_FindVar(d[1])
		if existing then
			cv[d[1]] = existing
		else
			local c = cvar.static(0, d[1], d[2], d[3])
			cvar.Cvar_RegisterVariable(c)
			cv[d[1]] = c
		end
	end
end

-- port: mathlib.c BoxOnPlaneSide L331-347 @xonotic-v0.8.6
local function BoxOnPlaneSide(emins: { number }, emaxs: { number }, p: mplane_t): number
	if p.type < 3 then
		return (if emaxs[p.type + 1] >= p.dist then 1 else 0) + (if emins[p.type + 1] < p.dist then 2 else 0)
	end
	local n = p.normal
	local s = p.signbits
	-- the corner the normal points at (a) and the opposite one (b); signbits picks mins or maxs per axis
	local a1 = if bit32.band(s, 1) ~= 0 then emins[1] else emaxs[1]
	local a2 = if bit32.band(s, 2) ~= 0 then emins[2] else emaxs[2]
	local a3 = if bit32.band(s, 4) ~= 0 then emins[3] else emaxs[3]
	local b1 = if bit32.band(s, 1) ~= 0 then emaxs[1] else emins[1]
	local b2 = if bit32.band(s, 2) ~= 0 then emaxs[2] else emins[2]
	local b3 = if bit32.band(s, 4) ~= 0 then emaxs[3] else emins[3]
	return (if R(R(R(n[1] * a1) + R(n[2] * a2)) + R(n[3] * a3)) >= p.dist then 1 else 0)
		+ (if R(R(R(n[1] * b1) + R(n[2] * b2)) + R(n[3] * b3)) < p.dist then 2 else 0)
end
model_brush.BoxOnPlaneSide = BoxOnPlaneSide

-- port: model_brush.c Mod_Q3BSP_TraceLineOfSight_RecursiveNodeCheck L6800-6860 @xonotic-v0.8.6
-- (p1, p2, endpos are double[3]: no float rounding)
local function Mod_Q3BSP_TraceLineOfSight_RecursiveNodeCheck(
	node: mnode_t,
	p1: { number },
	p2: { number },
	endpos: { number }
): number
	local t1: number, t2: number
	local side: number
	-- check for empty
	while node.plane do
		-- find the point distances
		local plane = node.plane
		if plane.type < 3 then
			t1 = p1[plane.type + 1] - plane.dist
			t2 = p2[plane.type + 1] - plane.dist
		else
			local n = plane.normal
			t1 = (n[1] * p1[1] + n[2] * p1[2] + n[3] * p1[3]) - plane.dist
			t2 = (n[1] * p2[1] + n[2] * p2[2] + n[3] * p2[3]) - plane.dist
		end

		if t1 < 0 then
			if t2 < 0 then
				node = node.children[2]
				continue
			end
			side = 1
		else
			if t2 >= 0 then
				node = node.children[1]
				continue
			end
			side = 0
		end

		local midf = t1 / (t1 - t2)
		local mid = {
			p1[1] + midf * (p2[1] - p1[1]),
			p1[2] + midf * (p2[2] - p1[2]),
			p1[3] + midf * (p2[3] - p1[3]),
		}

		-- recurse both sides, front side first
		-- return 2 if empty is followed by solid (hit something)
		-- do not return 2 if both are solid or both empty,
		-- or if start is solid and end is empty
		-- as these degenerate cases usually indicate the eye is in solid and
		-- should see the target point anyway
		local ret = Mod_Q3BSP_TraceLineOfSight_RecursiveNodeCheck(node.children[side + 1], p1, mid, endpos)
		if ret ~= 0 then
			return ret
		end
		ret = Mod_Q3BSP_TraceLineOfSight_RecursiveNodeCheck(node.children[bit32.bxor(side, 1) + 1], mid, p2, endpos)
		if ret ~= 1 then
			return ret
		end
		endpos[1], endpos[2], endpos[3] = mid[1], mid[2], mid[3]
		return 2
	end
	return if node.clusterindex < 0 then 1 else 0
end

-- port: model_brush.c Mod_Q3BSP_TraceLineOfSight L6862-6879 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceLineOfSight(
	model: dp_model_t,
	start: { number },
	end_: { number },
	acceptmins: { number },
	acceptmaxs: { number }
): boolean
	if model.brush.submodel ~= 0 or cv.mod_q3bsp_tracelineofsight_brushes.integer ~= 0 then
		local trace = collision.newtrace()
		model.TraceLine(
			model,
			nil,
			nil,
			trace,
			start,
			end_,
			SUPERCONTENTS_VISBLOCKERMASK,
			0,
			MATERIALFLAGMASK_TRANSLUCENT
		)
		local e = trace.endpos
		return trace.fraction == 1
			or (
				e[1] <= acceptmaxs[1]
				and e[1] >= acceptmins[1]
				and e[2] <= acceptmaxs[2]
				and e[2] >= acceptmins[2]
				and e[3] <= acceptmaxs[3]
				and e[3] >= acceptmins[3]
			)
	else
		local tracestart = { start[1], start[2], start[3] }
		local traceend = { end_[1], end_[2], end_[3] }
		local e = { end_[1], end_[2], end_[3] }
		Mod_Q3BSP_TraceLineOfSight_RecursiveNodeCheck(model.brush.data_nodes[1], tracestart, traceend, e)
		return e[1] <= acceptmaxs[1]
			and e[1] >= acceptmins[1]
			and e[2] <= acceptmaxs[2]
			and e[2] >= acceptmins[2]
			and e[3] <= acceptmaxs[3]
			and e[3] >= acceptmins[3]
	end
end

-- int nodestack[1024]; vec_t nodestackline[1024][6]; (C: locals of each BIH trace function. The functions never
-- run nested with a live stack, so one pair is shared.) nodestackline holds entry i at [6 * i + 1 .. 6 * i + 6].
local nodestack: { number } = table.create(1024, 0)
local nodestackline: { number } = table.create(1024 * 6, 0)
-- vec3_t nodestart, nodeend of the BIH_UNORDERED branch
local clipstart: { number } = { 0, 0, 0 }
local clipend: { number } = { 0, 0, 0 }

-- memset(trace, 0, sizeof(*trace)); trace->fraction = 1; and the three masks
local function trace_begin(
	trace: collision.trace_t,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	collision.cleartrace(trace)
	trace.fraction = 1
	trace.hitsupercontentsmask = hitsupercontentsmask
	trace.skipsupercontentsmask = skipsupercontentsmask
	trace.skipmaterialflagsmask = skipmaterialflagsmask
end

-- port: model_brush.c Mod_CollisionBIH_TracePoint L6881-6945 @xonotic-v0.8.6
local function Mod_CollisionBIH_TracePoint(
	model: dp_model_t,
	_frameblend: any,
	_skeleton: any,
	trace: collision.trace_t,
	start: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	local nodestackpos = 0

	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)

	local b: bih.bih_t = model.collision_bih
	if b.nodes[1] == nil then
		return
	end
	local nodes, leafs = b.nodes, b.leafs
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	local s1, s2, s3 = start[1], start[2], start[3]

	nodestackpos += 1
	nodestack[nodestackpos] = b.rootnode
	while nodestackpos > 0 do
		local node = nodes[nodestack[nodestackpos] + 1]
		nodestackpos -= 1
		local nmins, nmaxs = node.mins, node.maxs
		if
			not (
				s1 <= nmaxs[1]
				and s1 >= nmins[1]
				and s2 <= nmaxs[2]
				and s2 >= nmins[2]
				and s3 <= nmaxs[3]
				and s3 >= nmins[3]
			)
		then
			continue
		end
		if node.type <= BIH_SPLITZ and nodestackpos + 2 <= 1024 then
			local axis = node.type - BIH_SPLITX
			if start[axis + 1] >= node.frontmin then
				nodestackpos += 1
				nodestack[nodestackpos] = node.front
			end
			if start[axis + 1] <= node.backmax then
				nodestackpos += 1
				nodestack[nodestackpos] = node.back
			end
		elseif node.type == BIH_UNORDERED then
			local children = node.children
			for axis = 1, BIH_MAXUNORDEREDCHILDREN do
				if children[axis] < 0 then
					break
				end
				local leaf = leafs[children[axis] + 1]
				local lmins, lmaxs = leaf.mins, leaf.maxs
				if
					not (
						s1 <= lmaxs[1]
						and s1 >= lmins[1]
						and s2 <= lmaxs[2]
						and s2 >= lmins[2]
						and s3 <= lmaxs[3]
						and s3 >= lmins[3]
					)
				then
					continue
				end
				if leaf.type == BIH_BRUSH then
					collision.Collision_TracePointBrushFloat(trace, start, brushes[leaf.itemindex + 1].colbrushf)
				end
				-- BIH_COLLISIONTRIANGLE: collision triangle - skipped because they have no volume
				-- BIH_RENDERTRIANGLE: render triangle - skipped because they have no volume
			end
		end
	end
end
model_brush.Mod_CollisionBIH_TracePoint = Mod_CollisionBIH_TracePoint

-- The 16-case switch of the BIH traces (model_brush.c L7007-7025 and L7162-7180), which pushes the back child
-- and then the front child with the part of the line that can reach it:
--   back child:  skipped when d1 < 0 and d2 < 0; start is moved to the split when d1 < 0, end when d2 < 0
--   front child: skipped when d3 < 0 and d4 < 0; start is moved to the split when d3 < 0, end when d4 < 0
-- Returns the new nodestackpos. (f = d / (d - dother); VectorLerp(nodestart, f, nodeend, out), all float.)
local function pushsplit(
	nodestackpos: number,
	child: number,
	da: number,
	db: number,
	ns1: number,
	ns2: number,
	ns3: number,
	ne1: number,
	ne2: number,
	ne3: number
): number
	if da < 0 then
		if db < 0 then
			return nodestackpos
		end
		local f = R(da / R(da - db))
		local o = nodestackpos * 6
		nodestackline[o + 1] = R(ns1 + R(f * R(ne1 - ns1)))
		nodestackline[o + 2] = R(ns2 + R(f * R(ne2 - ns2)))
		nodestackline[o + 3] = R(ns3 + R(f * R(ne3 - ns3)))
		nodestackline[o + 4] = ne1
		nodestackline[o + 5] = ne2
		nodestackline[o + 6] = ne3
	elseif db < 0 then
		local f = R(da / R(da - db))
		local o = nodestackpos * 6
		nodestackline[o + 1] = ns1
		nodestackline[o + 2] = ns2
		nodestackline[o + 3] = ns3
		nodestackline[o + 4] = R(ns1 + R(f * R(ne1 - ns1)))
		nodestackline[o + 5] = R(ns2 + R(f * R(ne2 - ns2)))
		nodestackline[o + 6] = R(ns3 + R(f * R(ne3 - ns3)))
	else
		local o = nodestackpos * 6
		nodestackline[o + 1] = ns1
		nodestackline[o + 2] = ns2
		nodestackline[o + 3] = ns3
		nodestackline[o + 4] = ne1
		nodestackline[o + 5] = ne2
		nodestackline[o + 6] = ne3
	end
	nodestack[nodestackpos + 1] = child
	return nodestackpos + 1
end

-- "clip line to this node bounds" (model_brush.c L7034-7036 and L7189-7191): clips clipstart / clipend to the
-- box; false when the line is entirely outside (the C code `continue`s).
local function clipline(
	bigmins1: number,
	bigmins2: number,
	bigmins3: number,
	bigmaxs1: number,
	bigmaxs2: number,
	bigmaxs3: number
): boolean
	local cs, ce = clipstart, clipend
	for axis = 1, 3 do
		local lo = if axis == 1 then bigmins1 elseif axis == 2 then bigmins2 else bigmins3
		local hi = if axis == 1 then bigmaxs1 elseif axis == 2 then bigmaxs2 else bigmaxs3
		local d1 = R(cs[axis] - lo)
		local d2 = R(ce[axis] - lo)
		if d1 < 0 then
			if d2 < 0 then
				return false
			end
			local f = R(d1 / R(d1 - d2))
			cs[1] = R(cs[1] + R(f * R(ce[1] - cs[1])))
			cs[2] = R(cs[2] + R(f * R(ce[2] - cs[2])))
			cs[3] = R(cs[3] + R(f * R(ce[3] - cs[3])))
		elseif d2 < 0 then
			local f = R(d1 / R(d1 - d2))
			ce[1] = R(cs[1] + R(f * R(ce[1] - cs[1])))
			ce[2] = R(cs[2] + R(f * R(ce[2] - cs[2])))
			ce[3] = R(cs[3] + R(f * R(ce[3] - cs[3])))
		end
		d1 = R(hi - cs[axis])
		d2 = R(hi - ce[axis])
		if d1 < 0 then
			if d2 < 0 then
				return false
			end
			local f = R(d1 / R(d1 - d2))
			cs[1] = R(cs[1] + R(f * R(ce[1] - cs[1])))
			cs[2] = R(cs[2] + R(f * R(ce[2] - cs[2])))
			cs[3] = R(cs[3] + R(f * R(ce[3] - cs[3])))
		elseif d2 < 0 then
			local f = R(d1 / R(d1 - d2))
			ce[1] = R(cs[1] + R(f * R(ce[1] - cs[1])))
			ce[2] = R(cs[2] + R(f * R(ce[2] - cs[2])))
			ce[3] = R(cs[3] + R(f * R(ce[3] - cs[3])))
		end
	end
	return true
end

-- port: model_brush.c Mod_CollisionBIH_TraceLineShared L6947-7072 @xonotic-v0.8.6
local function Mod_CollisionBIH_TraceLineShared(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number,
	b: bih.bih_t
)
	local nodestackpos = 0

	if b.nodes[1] == nil then
		return
	end

	if start[1] == end_[1] and start[2] == end_[2] and start[3] == end_[3] then
		Mod_CollisionBIH_TracePoint(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		return
	end

	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)

	local nodes, leafs = b.nodes, b.leafs
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	local fullrecursion = collision.cv.collision_bih_fullrecursion.integer ~= 0
	local curves_collisions = cv.mod_q3bsp_curves_collisions.integer ~= 0

	-- push first node
	nodestackline[1] = start[1]
	nodestackline[2] = start[2]
	nodestackline[3] = start[3]
	nodestackline[4] = end_[1]
	nodestackline[5] = end_[2]
	nodestackline[6] = end_[3]
	nodestack[1] = b.rootnode
	nodestackpos = 1
	while nodestackpos > 0 do
		nodestackpos -= 1
		local node = nodes[nodestack[nodestackpos + 1] + 1]
		local o = nodestackpos * 6
		local ns1, ns2, ns3 = nodestackline[o + 1], nodestackline[o + 2], nodestackline[o + 3]
		local ne1, ne2, ne3 = nodestackline[o + 4], nodestackline[o + 5], nodestackline[o + 6]
		local nmins, nmaxs = node.mins, node.maxs
		if
			not (
				R(math.min(ns1, ne1) - 1) <= nmaxs[1]
				and R(math.max(ns1, ne1) + 1) >= nmins[1]
				and R(math.min(ns2, ne2) - 1) <= nmaxs[2]
				and R(math.max(ns2, ne2) + 1) >= nmins[2]
				and R(math.min(ns3, ne3) - 1) <= nmaxs[3]
				and R(math.max(ns3, ne3) + 1) >= nmins[3]
			) and not fullrecursion
		then
			continue
		end
		if node.type <= BIH_SPLITZ and nodestackpos + 2 <= 1024 then
			-- recurse children of the split
			local axis = node.type - BIH_SPLITX
			local nsa = if axis == 0 then ns1 elseif axis == 1 then ns2 else ns3
			local nea = if axis == 0 then ne1 elseif axis == 1 then ne2 else ne3
			local d1 = R(node.backmax - nsa)
			local d2 = R(node.backmax - nea)
			local d3 = R(nsa - node.frontmin)
			local d4 = R(nea - node.frontmin)
			if fullrecursion then
				d1, d2, d3, d4 = 1, 1, 1, 1 -- force full recursion
			end
			nodestackpos = pushsplit(nodestackpos, node.back, d1, d2, ns1, ns2, ns3, ne1, ne2, ne3)
			nodestackpos = pushsplit(nodestackpos, node.front, d3, d4, ns1, ns2, ns3, ne1, ne2, ne3)
		elseif node.type == BIH_UNORDERED then
			-- calculate sweep bounds for this node
			-- copy node bounds into local variables
			-- clip line to this node bounds
			clipstart[1], clipstart[2], clipstart[3] = ns1, ns2, ns3
			clipend[1], clipend[2], clipend[3] = ne1, ne2, ne3
			if not clipline(nmins[1], nmins[2], nmins[3], nmaxs[1], nmaxs[2], nmaxs[3]) then
				continue
			end
			-- some of the line intersected the enlarged node box
			-- calculate sweep bounds for this node
			local swmin1 = R(math.min(clipstart[1], clipend[1]) - 1)
			local swmin2 = R(math.min(clipstart[2], clipend[2]) - 1)
			local swmin3 = R(math.min(clipstart[3], clipend[3]) - 1)
			local swmax1 = R(math.max(clipstart[1], clipend[1]) + 1)
			local swmax2 = R(math.max(clipstart[2], clipend[2]) + 1)
			local swmax3 = R(math.max(clipstart[3], clipend[3]) + 1)
			local children = node.children
			for axis = 1, BIH_MAXUNORDEREDCHILDREN do
				if children[axis] < 0 then
					break
				end
				local leaf = leafs[children[axis] + 1]
				local lmins, lmaxs = leaf.mins, leaf.maxs
				if
					not (
						swmin1 <= lmaxs[1]
						and swmax1 >= lmins[1]
						and swmin2 <= lmaxs[2]
						and swmax2 >= lmins[2]
						and swmin3 <= lmaxs[3]
						and swmax3 >= lmins[3]
					)
				then
					continue
				end
				local leaftype = leaf.type
				if leaftype == BIH_BRUSH then
					local brush = brushes[leaf.itemindex + 1].colbrushf
					collision.Collision_TraceLineBrushFloat(trace, start, end_, brush, brush)
				elseif leaftype == BIH_COLLISIONTRIANGLE then
					if not curves_collisions then
						continue
					end
					local element3i: buffer = model.brush.data_collisionelement3i
					local e = 12 * leaf.itemindex
					local texture = model.data_textures[leaf.textureindex + 1]
					collision.Collision_TraceLineTriangleFloat(
						trace,
						start,
						end_,
						model.brush.data_collisionvertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12,
						texture.supercontents,
						texture.surfaceflags,
						texture
					)
				elseif leaftype == BIH_RENDERTRIANGLE then
					local element3i: buffer = model.surfmesh.data_element3i
					local e = 12 * leaf.itemindex
					local texture = model.data_textures[leaf.textureindex + 1]
					collision.Collision_TraceLineTriangleFloat(
						trace,
						start,
						end_,
						model.surfmesh.data_vertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12,
						texture.supercontents,
						texture.surfaceflags,
						texture
					)
				end
			end
		end
	end
end

-- port: model_brush.c Mod_CollisionBIH_TraceLine L7074-7082 @xonotic-v0.8.6
local function Mod_CollisionBIH_TraceLine(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	if start[1] == end_[1] and start[2] == end_[2] and start[3] == end_[3] then
		Mod_CollisionBIH_TracePoint(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		return
	end
	Mod_CollisionBIH_TraceLineShared(
		model,
		frameblend,
		skeleton,
		trace,
		start,
		end_,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		model.collision_bih
	)
end
model_brush.Mod_CollisionBIH_TraceLine = Mod_CollisionBIH_TraceLine

-- port: model_brush.c Mod_CollisionBIH_TraceBrush L7084-7227 @xonotic-v0.8.6
local function Mod_CollisionBIH_TraceBrush(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	thisbrush_start: collision.colbrushf_t,
	thisbrush_end: collision.colbrushf_t,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	local nodestackpos = 0
	local smins, smaxs = thisbrush_start.mins, thisbrush_start.maxs
	local emins, emaxs = thisbrush_end.mins, thisbrush_end.maxs

	if
		cv.mod_q3bsp_optimizedtraceline.integer ~= 0
		and smins[1] == smaxs[1]
		and smins[2] == smaxs[2]
		and smins[3] == smaxs[3]
		and emins[1] == emaxs[1]
		and emins[2] == emaxs[2]
		and emins[3] == emaxs[3]
	then
		if smins[1] == emins[1] and smins[2] == emins[2] and smins[3] == emins[3] then
			Mod_CollisionBIH_TracePoint(
				model,
				frameblend,
				skeleton,
				trace,
				smins,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		else
			Mod_CollisionBIH_TraceLine(
				model,
				frameblend,
				skeleton,
				trace,
				smins,
				emins,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		end
		return
	end

	local b: bih.bih_t = model.collision_bih
	if b.nodes[1] == nil then
		return
	end
	local nodes, leafs = b.nodes, b.leafs
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	local curves_collisions = cv.mod_q3bsp_curves_collisions.integer ~= 0

	-- box trace, performed as brush trace
	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)

	-- calculate tracebox-like parameters for efficient culling
	local start1 = R(R(0.5 * smins[1]) + R(0.5 * smaxs[1]))
	local start2 = R(R(0.5 * smins[2]) + R(0.5 * smaxs[2]))
	local start3 = R(R(0.5 * smins[3]) + R(0.5 * smaxs[3]))
	local end1 = R(R(0.5 * emins[1]) + R(0.5 * emaxs[1]))
	local end2 = R(R(0.5 * emins[2]) + R(0.5 * emaxs[2]))
	local end3 = R(R(0.5 * emins[3]) + R(0.5 * emaxs[3]))
	-- mins = min(startmins, endmins), maxs = max(startmaxs, endmaxs)
	local mins1 = math.min(R(smins[1] - start1), R(emins[1] - end1))
	local mins2 = math.min(R(smins[2] - start2), R(emins[2] - end2))
	local mins3 = math.min(R(smins[3] - start3), R(emins[3] - end3))
	local maxs1 = math.max(R(smaxs[1] - start1), R(emaxs[1] - end1))
	local maxs2 = math.max(R(smaxs[2] - start2), R(emaxs[2] - end2))
	local maxs3 = math.max(R(smaxs[3] - start3), R(emaxs[3] - end3))

	-- push first node
	nodestackline[1] = start1
	nodestackline[2] = start2
	nodestackline[3] = start3
	nodestackline[4] = end1
	nodestackline[5] = end2
	nodestackline[6] = end3
	nodestack[1] = b.rootnode
	nodestackpos = 1
	while nodestackpos > 0 do
		nodestackpos -= 1
		local node = nodes[nodestack[nodestackpos + 1] + 1]
		local o = nodestackpos * 6
		local ns1, ns2, ns3 = nodestackline[o + 1], nodestackline[o + 2], nodestackline[o + 3]
		local ne1, ne2, ne3 = nodestackline[o + 4], nodestackline[o + 5], nodestackline[o + 6]
		local nmins, nmaxs = node.mins, node.maxs
		if
			not (
				R(R(math.min(ns1, ne1) + mins1) - 1) <= nmaxs[1]
				and R(R(math.max(ns1, ne1) + maxs1) + 1) >= nmins[1]
				and R(R(math.min(ns2, ne2) + mins2) - 1) <= nmaxs[2]
				and R(R(math.max(ns2, ne2) + maxs2) + 1) >= nmins[2]
				and R(R(math.min(ns3, ne3) + mins3) - 1) <= nmaxs[3]
				and R(R(math.max(ns3, ne3) + maxs3) + 1) >= nmins[3]
			)
		then
			continue
		end
		if node.type <= BIH_SPLITZ and nodestackpos + 2 <= 1024 then
			-- recurse children of the split
			local axis = node.type - BIH_SPLITX
			local nsa = if axis == 0 then ns1 elseif axis == 1 then ns2 else ns3
			local nea = if axis == 0 then ne1 elseif axis == 1 then ne2 else ne3
			local minsa = if axis == 0 then mins1 elseif axis == 1 then mins2 else mins3
			local maxsa = if axis == 0 then maxs1 elseif axis == 1 then maxs2 else maxs3
			local d1 = R(R(node.backmax - nsa) - minsa)
			local d2 = R(R(node.backmax - nea) - minsa)
			local d3 = R(R(nsa - node.frontmin) + maxsa)
			local d4 = R(R(nea - node.frontmin) + maxsa)
			nodestackpos = pushsplit(nodestackpos, node.back, d1, d2, ns1, ns2, ns3, ne1, ne2, ne3)
			nodestackpos = pushsplit(nodestackpos, node.front, d3, d4, ns1, ns2, ns3, ne1, ne2, ne3)
		elseif node.type == BIH_UNORDERED then
			-- calculate sweep bounds for this node
			-- copy node bounds into local variables and expand to get Minkowski Sum of the two shapes
			-- clip line to this node bounds
			clipstart[1], clipstart[2], clipstart[3] = ns1, ns2, ns3
			clipend[1], clipend[2], clipend[3] = ne1, ne2, ne3
			if
				not clipline(
					R(nmins[1] - maxs1),
					R(nmins[2] - maxs2),
					R(nmins[3] - maxs3),
					R(nmaxs[1] - mins1),
					R(nmaxs[2] - mins2),
					R(nmaxs[3] - mins3)
				)
			then
				continue
			end
			-- some of the line intersected the enlarged node box
			-- calculate sweep bounds for this node
			local swmin1 = R(R(math.min(clipstart[1], clipend[1]) + mins1) - 1)
			local swmin2 = R(R(math.min(clipstart[2], clipend[2]) + mins2) - 1)
			local swmin3 = R(R(math.min(clipstart[3], clipend[3]) + mins3) - 1)
			local swmax1 = R(R(math.max(clipstart[1], clipend[1]) + maxs1) + 1)
			local swmax2 = R(R(math.max(clipstart[2], clipend[2]) + maxs2) + 1)
			local swmax3 = R(R(math.max(clipstart[3], clipend[3]) + maxs3) + 1)
			local children = node.children
			for axis = 1, BIH_MAXUNORDEREDCHILDREN do
				if children[axis] < 0 then
					break
				end
				local leaf = leafs[children[axis] + 1]
				local lmins, lmaxs = leaf.mins, leaf.maxs
				if
					not (
						swmin1 <= lmaxs[1]
						and swmax1 >= lmins[1]
						and swmin2 <= lmaxs[2]
						and swmax2 >= lmins[2]
						and swmin3 <= lmaxs[3]
						and swmax3 >= lmins[3]
					)
				then
					continue
				end
				local leaftype = leaf.type
				if leaftype == BIH_BRUSH then
					local brush = brushes[leaf.itemindex + 1].colbrushf
					collision.Collision_TraceBrushBrushFloat(trace, thisbrush_start, thisbrush_end, brush, brush)
				elseif leaftype == BIH_COLLISIONTRIANGLE then
					if not curves_collisions then
						continue
					end
					local element3i: buffer = model.brush.data_collisionelement3i
					local e = 12 * leaf.itemindex
					local texture = model.data_textures[leaf.textureindex + 1]
					collision.Collision_TraceBrushTriangleFloat(
						trace,
						thisbrush_start,
						thisbrush_end,
						model.brush.data_collisionvertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12,
						texture.supercontents,
						texture.surfaceflags,
						texture
					)
				elseif leaftype == BIH_RENDERTRIANGLE then
					local element3i: buffer = model.surfmesh.data_element3i
					local e = 12 * leaf.itemindex
					local texture = model.data_textures[leaf.textureindex + 1]
					collision.Collision_TraceBrushTriangleFloat(
						trace,
						thisbrush_start,
						thisbrush_end,
						model.surfmesh.data_vertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12,
						texture.supercontents,
						texture.surfaceflags,
						texture
					)
				end
			end
		end
	end
end
model_brush.Mod_CollisionBIH_TraceBrush = Mod_CollisionBIH_TraceBrush

-- port: model_brush.c Mod_CollisionBIH_TraceBox L7229-7242 @xonotic-v0.8.6
local function Mod_CollisionBIH_TraceBox(
	model: dp_model_t,
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
	-- box trace, performed as brush trace
	local boxstartmins = { R(start[1] + boxmins[1]), R(start[2] + boxmins[2]), R(start[3] + boxmins[3]) }
	local boxstartmaxs = { R(start[1] + boxmaxs[1]), R(start[2] + boxmaxs[2]), R(start[3] + boxmaxs[3]) }
	local boxendmins = { R(end_[1] + boxmins[1]), R(end_[2] + boxmins[2]), R(end_[3] + boxmins[3]) }
	local boxendmaxs = { R(end_[1] + boxmaxs[1]), R(end_[2] + boxmaxs[2]), R(end_[3] + boxmaxs[3]) }
	local thisbrush_start = collision.Collision_BrushForBox(boxstartmins, boxstartmaxs, 0, 0, nil)
	local thisbrush_end = collision.Collision_BrushForBox(boxendmins, boxendmaxs, 0, 0, nil)
	Mod_CollisionBIH_TraceBrush(
		model,
		frameblend,
		skeleton,
		trace,
		thisbrush_start,
		thisbrush_end,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask
	)
end
model_brush.Mod_CollisionBIH_TraceBox = Mod_CollisionBIH_TraceBox

-- port: model_brush.c Mod_CollisionBIH_PointSuperContents L7245-7250 @xonotic-v0.8.6
local function Mod_CollisionBIH_PointSuperContents(model: dp_model_t, _frame: number, point: { number }): number
	local trace = collision.newtrace()
	Mod_CollisionBIH_TracePoint(model, nil, nil, trace, point, 0, 0, 0)
	return trace.startsupercontents
end
model_brush.Mod_CollisionBIH_PointSuperContents = Mod_CollisionBIH_PointSuperContents

-- port: model_brush.c Mod_CollisionBIH_TraceLineOfSight L7252-7257 @xonotic-v0.8.6
function model_brush.Mod_CollisionBIH_TraceLineOfSight(
	model: dp_model_t,
	start: { number },
	end_: { number },
	acceptmins: { number },
	acceptmaxs: { number }
): boolean
	local trace = collision.newtrace()
	Mod_CollisionBIH_TraceLine(
		model,
		nil,
		nil,
		trace,
		start,
		end_,
		SUPERCONTENTS_VISBLOCKERMASK,
		0,
		MATERIALFLAGMASK_TRANSLUCENT
	)
	local e = trace.endpos
	return trace.fraction == 1
		or (
			e[1] <= acceptmaxs[1]
			and e[1] >= acceptmins[1]
			and e[2] <= acceptmaxs[2]
			and e[2] >= acceptmins[2]
			and e[3] <= acceptmaxs[3]
			and e[3] >= acceptmins[3]
		)
end

-- port: model_brush.c Mod_CollisionBIH_TracePoint_Mesh L7259-7282 @xonotic-v0.8.6
-- (the C body is #if 0 "broken - needs to be modified to count front faces and backfaces")
function model_brush.Mod_CollisionBIH_TracePoint_Mesh(
	_model: dp_model_t,
	_frameblend: any,
	_skeleton: any,
	trace: collision.trace_t,
	_start: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)
end

-- port: model_brush.c Mod_CollisionBIH_PointSuperContents_Mesh L7284-7301 @xonotic-v0.8.6
function model_brush.Mod_CollisionBIH_PointSuperContents_Mesh(
	_model: dp_model_t,
	_frame: number,
	_start: { number }
): number
	return 0
end

-- port: model_brush.c Mod_Q3BSP_TracePoint_RecursiveBSPNode L7303-7323 @xonotic-v0.8.6
local function Mod_Q3BSP_TracePoint_RecursiveBSPNode(
	trace: collision.trace_t,
	model: dp_model_t,
	node: mnode_t,
	point: { number },
	markframe: number
)
	-- find which leaf the point is in
	while node.plane do
		local plane = node.plane
		local n = plane.normal
		local d = if plane.type < 3
			then point[plane.type + 1]
			else R(R(R(point[1] * n[1]) + R(point[2] * n[2])) + R(point[3] * n[3]))
		node = node.children[if d < plane.dist then 2 else 1]
	end
	-- point trace the brushes
	local leaf = node
	local leafbrushes: buffer = model.brush.data_leafbrushes
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	for i = 0, leaf.numleafbrushes - 1 do
		local brush = brushes[readi32(leafbrushes, (leaf.firstleafbrush + i) * 4) + 1].colbrushf
		if
			brush
			and brush.markframe ~= markframe
			and point[1] <= brush.maxs[1]
			and point[1] >= brush.mins[1]
			and point[2] <= brush.maxs[2]
			and point[2] >= brush.mins[2]
			and point[3] <= brush.maxs[3]
			and point[3] >= brush.mins[3]
		then
			brush.markframe = markframe
			collision.Collision_TracePointBrushFloat(trace, point, brush)
		end
	end
	-- can't do point traces on curves (they have no thickness)
end

-- BoxesOverlap(a, b, c, d) with a / b as three numbers each
local function boxoverlaps(
	a1: number,
	a2: number,
	a3: number,
	b1: number,
	b2: number,
	b3: number,
	c: { number },
	d: { number }
): boolean
	return a1 <= d[1] and b1 >= c[1] and a2 <= d[2] and b2 >= c[2] and a3 <= d[3] and b3 >= c[3]
end

-- port: model_brush.c Mod_Q3BSP_TraceLine_RecursiveBSPNode L7325-7421 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceLine_RecursiveBSPNode(
	trace: collision.trace_t,
	model: dp_model_t,
	node: mnode_t,
	start: { number },
	end_: { number },
	startfrac: number,
	endfrac: number,
	linestart: { number },
	lineend: { number },
	markframe: number,
	segmentmins: { number },
	segmentmaxs: { number }
)
	local dist1: number, dist2: number
	-- walk the tree until we hit a leaf, recursing for any split cases
	while node.plane do
		-- abort if this part of the bsp tree can not be hit by this trace
		--		if (!(node->combinedsupercontents & trace->hitsupercontentsmask))
		--			return;
		local plane = node.plane
		local n = plane.normal
		-- axial planes are much more common than non-axial, so an optimized
		-- axial case pays off here
		if plane.type < 3 then
			dist1 = R(start[plane.type + 1] - plane.dist)
			dist2 = R(end_[plane.type + 1] - plane.dist)
		else
			dist1 = R(R(R(R(start[1] * n[1]) + R(start[2] * n[2])) + R(start[3] * n[3])) - plane.dist)
			dist2 = R(R(R(R(end_[1] * n[1]) + R(end_[2] * n[2])) + R(end_[3] * n[3])) - plane.dist)
		end
		local startside = if dist1 < 0 then 1 else 0
		local endside = if dist2 < 0 then 1 else 0
		if startside == endside then
			-- most of the time the line fragment is on one side of the plane
			node = node.children[startside + 1]
		else
			-- line crosses node plane, split the line
			-- dist1 = PlaneDiff(linestart, plane); dist2 = PlaneDiff(lineend, plane);
			if plane.type < 3 then
				dist1 = R(linestart[plane.type + 1] - plane.dist)
				dist2 = R(lineend[plane.type + 1] - plane.dist)
			else
				dist1 = R(R(R(R(linestart[1] * n[1]) + R(linestart[2] * n[2])) + R(linestart[3] * n[3])) - plane.dist)
				dist2 = R(R(R(R(lineend[1] * n[1]) + R(lineend[2] * n[2])) + R(lineend[3] * n[3])) - plane.dist)
			end
			local midfrac = R(dist1 / R(dist1 - dist2))
			local mid = {
				R(linestart[1] + R(midfrac * R(lineend[1] - linestart[1]))),
				R(linestart[2] + R(midfrac * R(lineend[2] - linestart[2]))),
				R(linestart[3] + R(midfrac * R(lineend[3] - linestart[3]))),
			}
			-- take the near side first
			Mod_Q3BSP_TraceLine_RecursiveBSPNode(
				trace,
				model,
				node.children[startside + 1],
				start,
				mid,
				startfrac,
				midfrac,
				linestart,
				lineend,
				markframe,
				segmentmins,
				segmentmaxs
			)
			-- if we found an impact on the front side, don't waste time
			-- exploring the far side
			if midfrac <= trace.fraction then
				Mod_Q3BSP_TraceLine_RecursiveBSPNode(
					trace,
					model,
					node.children[endside + 1],
					mid,
					end_,
					midfrac,
					endfrac,
					linestart,
					lineend,
					markframe,
					segmentmins,
					segmentmaxs
				)
			end
			return
		end
	end
	-- abort if this part of the bsp tree can not be hit by this trace
	--	if (!(node->combinedsupercontents & trace->hitsupercontentsmask))
	--		return;
	-- hit a leaf
	local nsmin1 = R(math.min(start[1], end_[1]) - 1)
	local nsmin2 = R(math.min(start[2], end_[2]) - 1)
	local nsmin3 = R(math.min(start[3], end_[3]) - 1)
	local nsmax1 = R(math.max(start[1], end_[1]) + 1)
	local nsmax2 = R(math.max(start[2], end_[2]) + 1)
	local nsmax3 = R(math.max(start[3], end_[3]) + 1)
	-- line trace the brushes
	local leaf = node
	local leafbrushes: buffer = model.brush.data_leafbrushes
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	for i = 0, leaf.numleafbrushes - 1 do
		local brush = brushes[readi32(leafbrushes, (leaf.firstleafbrush + i) * 4) + 1].colbrushf
		if
			brush
			and brush.markframe ~= markframe
			and boxoverlaps(nsmin1, nsmin2, nsmin3, nsmax1, nsmax2, nsmax3, brush.mins, brush.maxs)
		then
			brush.markframe = markframe
			collision.Collision_TraceLineBrushFloat(trace, linestart, lineend, brush, brush)
		end
	end
	-- can't do point traces on curves (they have no thickness)
	if
		leaf.containscollisionsurfaces
		and cv.mod_q3bsp_curves_collisions.integer ~= 0
		and not (start[1] == end_[1] and start[2] == end_[2] and start[3] == end_[3])
	then
		-- line trace the curves
		local leafsurfaces: buffer = model.brush.data_leafsurfaces
		for i = 0, leaf.numleafsurfaces - 1 do
			local surface = model.data_surfaces[readi32(leafsurfaces, (leaf.firstleafsurface + i) * 4) + 1]
			if
				surface.num_collisiontriangles ~= 0
				and surface.deprecatedq3collisionmarkframe ~= markframe
				and boxoverlaps(nsmin1, nsmin2, nsmin3, nsmax1, nsmax2, nsmax3, surface.mins, surface.maxs)
			then
				surface.deprecatedq3collisionmarkframe = markframe
				collision.Collision_TraceLineTriangleMeshFloat(
					trace,
					linestart,
					lineend,
					surface.num_collisiontriangles,
					surface.deprecatedq3data_collisionelement3i,
					0,
					surface.deprecatedq3data_collisionvertex3f,
					surface.deprecatedq3num_collisionbboxstride,
					surface.deprecatedq3data_collisionbbox6f,
					surface.texture.supercontents,
					surface.texture.surfaceflags,
					surface.texture,
					segmentmins,
					segmentmaxs
				)
			end
		end
	end
end

-- port: model_brush.c Mod_Q3BSP_TraceBrush_RecursiveBSPNode L7423-7513 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceBrush_RecursiveBSPNode(
	trace: collision.trace_t,
	model: dp_model_t,
	node: mnode_t,
	thisbrush_start: collision.colbrushf_t,
	thisbrush_end: collision.colbrushf_t,
	markframe: number,
	segmentmins: { number },
	segmentmaxs: { number }
)
	local sides: number
	-- walk the tree until we hit a leaf, recursing for any split cases
	while node.plane do
		-- abort if this part of the bsp tree can not be hit by this trace
		--		if (!(node->combinedsupercontents & trace->hitsupercontentsmask))
		--			return;
		local plane = node.plane
		-- axial planes are much more common than non-axial, so an optimized
		-- axial case pays off here
		if plane.type < 3 then
			-- this is an axial plane, compare bounding box directly to it and
			-- recurse sides accordingly
			-- recurse down node sides
			-- use an inlined axial BoxOnPlaneSide to slightly reduce overhead
			sides = (if segmentmaxs[plane.type + 1] >= plane.dist then 1 else 0)
				+ (if segmentmins[plane.type + 1] < plane.dist then 2 else 0)
		else
			-- this is a non-axial plane, so check if the start and end boxes
			-- are both on one side of the plane to handle 'diagonal' cases
			sides = bit32.bor(
				BoxOnPlaneSide(thisbrush_start.mins, thisbrush_start.maxs, plane),
				BoxOnPlaneSide(thisbrush_end.mins, thisbrush_end.maxs, plane)
			)
		end
		if sides == 3 then
			-- segment crosses plane
			Mod_Q3BSP_TraceBrush_RecursiveBSPNode(
				trace,
				model,
				node.children[1],
				thisbrush_start,
				thisbrush_end,
				markframe,
				segmentmins,
				segmentmaxs
			)
			sides = 2
		end
		-- if sides == 0 then the trace itself is bogus (Not A Number values),
		-- in this case we simply pretend the trace hit nothing
		if sides == 0 then
			return -- ERROR: NAN bounding box!
		end
		-- take whichever side the segment box is on
		node = node.children[sides]
	end
	-- abort if this part of the bsp tree can not be hit by this trace
	--	if (!(node->combinedsupercontents & trace->hitsupercontentsmask))
	--		return;
	local nsmin1 = math.max(segmentmins[1], R(node.mins[1] - 1))
	local nsmin2 = math.max(segmentmins[2], R(node.mins[2] - 1))
	local nsmin3 = math.max(segmentmins[3], R(node.mins[3] - 1))
	local nsmax1 = math.min(segmentmaxs[1], R(node.maxs[1] + 1))
	local nsmax2 = math.min(segmentmaxs[2], R(node.maxs[2] + 1))
	local nsmax3 = math.min(segmentmaxs[3], R(node.maxs[3] + 1))
	-- hit a leaf
	local leaf = node
	local leafbrushes: buffer = model.brush.data_leafbrushes
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	for i = 0, leaf.numleafbrushes - 1 do
		local brush = brushes[readi32(leafbrushes, (leaf.firstleafbrush + i) * 4) + 1].colbrushf
		if
			brush
			and brush.markframe ~= markframe
			and boxoverlaps(nsmin1, nsmin2, nsmin3, nsmax1, nsmax2, nsmax3, brush.mins, brush.maxs)
		then
			brush.markframe = markframe
			collision.Collision_TraceBrushBrushFloat(trace, thisbrush_start, thisbrush_end, brush, brush)
		end
	end
	if leaf.containscollisionsurfaces and cv.mod_q3bsp_curves_collisions.integer ~= 0 then
		local leafsurfaces: buffer = model.brush.data_leafsurfaces
		for i = 0, leaf.numleafsurfaces - 1 do
			local surface = model.data_surfaces[readi32(leafsurfaces, (leaf.firstleafsurface + i) * 4) + 1]
			if
				surface.num_collisiontriangles ~= 0
				and surface.deprecatedq3collisionmarkframe ~= markframe
				and boxoverlaps(nsmin1, nsmin2, nsmin3, nsmax1, nsmax2, nsmax3, surface.mins, surface.maxs)
			then
				surface.deprecatedq3collisionmarkframe = markframe
				collision.Collision_TraceBrushTriangleMeshFloat(
					trace,
					thisbrush_start,
					thisbrush_end,
					surface.num_collisiontriangles,
					surface.deprecatedq3data_collisionelement3i,
					0,
					surface.deprecatedq3data_collisionvertex3f,
					surface.deprecatedq3num_collisionbboxstride,
					surface.deprecatedq3data_collisionbbox6f,
					surface.texture.supercontents,
					surface.texture.surfaceflags,
					surface.texture,
					segmentmins,
					segmentmaxs
				)
			end
		end
	end
end

-- model_brush.c L7516: static int markframe = 0;
local markframe = 0

-- port: model_brush.c Mod_Q3BSP_TracePoint L7518-7537 @xonotic-v0.8.6
local function Mod_Q3BSP_TracePoint(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)
	if cv.mod_collision_bih.integer ~= 0 then
		Mod_CollisionBIH_TracePoint(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
	elseif model.brush.submodel ~= 0 then
		local brushes: { q3mbrush_t } = model.brush.data_brushes
		for i = 0, model.nummodelbrushes - 1 do
			local brush = brushes[model.firstmodelbrush + i + 1]
			if brush.colbrushf then
				collision.Collision_TracePointBrushFloat(trace, start, brush.colbrushf)
			end
		end
	else
		markframe += 1
		Mod_Q3BSP_TracePoint_RecursiveBSPNode(trace, model, model.brush.data_nodes[1], start, markframe)
	end
end

-- port: model_brush.c Mod_Q3BSP_TraceLine L7539-7577 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceLine(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	if start[1] == end_[1] and start[2] == end_[2] and start[3] == end_[3] then
		Mod_Q3BSP_TracePoint(
			model,
			frameblend,
			skeleton,
			trace,
			start,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
		return
	end

	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)
	local segmentmins = {
		R(math.min(start[1], end_[1]) - 1),
		R(math.min(start[2], end_[2]) - 1),
		R(math.min(start[3], end_[3]) - 1),
	}
	local segmentmaxs = {
		R(math.max(start[1], end_[1]) + 1),
		R(math.max(start[2], end_[2]) + 1),
		R(math.max(start[3], end_[3]) + 1),
	}
	if cv.mod_collision_bih.integer ~= 0 then
		Mod_CollisionBIH_TraceLine(
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
	elseif model.brush.submodel ~= 0 then
		local brushes: { q3mbrush_t } = model.brush.data_brushes
		for i = 0, model.nummodelbrushes - 1 do
			local cb = brushes[model.firstmodelbrush + i + 1].colbrushf
			if
				cb
				and boxoverlaps(
					segmentmins[1],
					segmentmins[2],
					segmentmins[3],
					segmentmaxs[1],
					segmentmaxs[2],
					segmentmaxs[3],
					cb.mins,
					cb.maxs
				)
			then
				collision.Collision_TraceLineBrushFloat(trace, start, end_, cb, cb)
			end
		end
		if cv.mod_q3bsp_curves_collisions.integer ~= 0 then
			for i = 0, model.nummodelsurfaces - 1 do
				local surface = model.data_surfaces[model.firstmodelsurface + i + 1]
				if
					surface.num_collisiontriangles ~= 0
					and boxoverlaps(
						segmentmins[1],
						segmentmins[2],
						segmentmins[3],
						segmentmaxs[1],
						segmentmaxs[2],
						segmentmaxs[3],
						surface.mins,
						surface.maxs
					)
				then
					collision.Collision_TraceLineTriangleMeshFloat(
						trace,
						start,
						end_,
						surface.num_collisiontriangles,
						surface.deprecatedq3data_collisionelement3i,
						0,
						surface.deprecatedq3data_collisionvertex3f,
						surface.deprecatedq3num_collisionbboxstride,
						surface.deprecatedq3data_collisionbbox6f,
						surface.texture.supercontents,
						surface.texture.surfaceflags,
						surface.texture,
						segmentmins,
						segmentmaxs
					)
				end
			end
		end
	else
		markframe += 1
		Mod_Q3BSP_TraceLine_RecursiveBSPNode(
			trace,
			model,
			model.brush.data_nodes[1],
			start,
			end_,
			0,
			1,
			start,
			end_,
			markframe,
			segmentmins,
			segmentmaxs
		)
	end
end

-- port: model_brush.c Mod_Q3BSP_TraceBrush L7579-7621 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceBrush(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: collision.colbrushf_t,
	end_: collision.colbrushf_t,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	local smins, smaxs = start.mins, start.maxs
	local emins, emaxs = end_.mins, end_.maxs
	if
		cv.mod_q3bsp_optimizedtraceline.integer ~= 0
		and smins[1] == smaxs[1]
		and smins[2] == smaxs[2]
		and smins[3] == smaxs[3]
		and emins[1] == emaxs[1]
		and emins[2] == emaxs[2]
		and emins[3] == emaxs[3]
	then
		if smins[1] == emins[1] and smins[2] == emins[2] and smins[3] == emins[3] then
			Mod_Q3BSP_TracePoint(
				model,
				frameblend,
				skeleton,
				trace,
				smins,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		else
			Mod_Q3BSP_TraceLine(
				model,
				frameblend,
				skeleton,
				trace,
				smins,
				emins,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		end
		return
	end

	-- box trace, performed as brush trace
	trace_begin(trace, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask)
	local segmentmins = {
		R(math.min(smins[1], emins[1]) - 1),
		R(math.min(smins[2], emins[2]) - 1),
		R(math.min(smins[3], emins[3]) - 1),
	}
	local segmentmaxs = {
		R(math.max(smaxs[1], emaxs[1]) + 1),
		R(math.max(smaxs[2], emaxs[2]) + 1),
		R(math.max(smaxs[3], emaxs[3]) + 1),
	}
	if cv.mod_collision_bih.integer ~= 0 then
		Mod_CollisionBIH_TraceBrush(
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
	elseif model.brush.submodel ~= 0 then
		local brushes: { q3mbrush_t } = model.brush.data_brushes
		for i = 0, model.nummodelbrushes - 1 do
			local cb = brushes[model.firstmodelbrush + i + 1].colbrushf
			if
				cb
				and boxoverlaps(
					segmentmins[1],
					segmentmins[2],
					segmentmins[3],
					segmentmaxs[1],
					segmentmaxs[2],
					segmentmaxs[3],
					cb.mins,
					cb.maxs
				)
			then
				collision.Collision_TraceBrushBrushFloat(trace, start, end_, cb, cb)
			end
		end
		if cv.mod_q3bsp_curves_collisions.integer ~= 0 then
			for i = 0, model.nummodelsurfaces - 1 do
				local surface = model.data_surfaces[model.firstmodelsurface + i + 1]
				if
					surface.num_collisiontriangles ~= 0
					and boxoverlaps(
						segmentmins[1],
						segmentmins[2],
						segmentmins[3],
						segmentmaxs[1],
						segmentmaxs[2],
						segmentmaxs[3],
						surface.mins,
						surface.maxs
					)
				then
					collision.Collision_TraceBrushTriangleMeshFloat(
						trace,
						start,
						end_,
						surface.num_collisiontriangles,
						surface.deprecatedq3data_collisionelement3i,
						0,
						surface.deprecatedq3data_collisionvertex3f,
						surface.deprecatedq3num_collisionbboxstride,
						surface.deprecatedq3data_collisionbbox6f,
						surface.texture.supercontents,
						surface.texture.surfaceflags,
						surface.texture,
						segmentmins,
						segmentmaxs
					)
				end
			end
		end
	else
		markframe += 1
		Mod_Q3BSP_TraceBrush_RecursiveBSPNode(
			trace,
			model,
			model.brush.data_nodes[1],
			start,
			end_,
			markframe,
			segmentmins,
			segmentmaxs
		)
	end
end

-- port: model_brush.c Mod_Q3BSP_TraceBox L7623-7636 @xonotic-v0.8.6
local function Mod_Q3BSP_TraceBox(
	model: dp_model_t,
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
	-- box trace, performed as brush trace
	local boxstartmins = { R(start[1] + boxmins[1]), R(start[2] + boxmins[2]), R(start[3] + boxmins[3]) }
	local boxstartmaxs = { R(start[1] + boxmaxs[1]), R(start[2] + boxmaxs[2]), R(start[3] + boxmaxs[3]) }
	local boxendmins = { R(end_[1] + boxmins[1]), R(end_[2] + boxmins[2]), R(end_[3] + boxmins[3]) }
	local boxendmaxs = { R(end_[1] + boxmaxs[1]), R(end_[2] + boxmaxs[2]), R(end_[3] + boxmaxs[3]) }
	local thisbrush_start = collision.Collision_BrushForBox(boxstartmins, boxstartmaxs, 0, 0, nil)
	local thisbrush_end = collision.Collision_BrushForBox(boxendmins, boxendmaxs, 0, 0, nil)
	Mod_Q3BSP_TraceBrush(
		model,
		frameblend,
		skeleton,
		trace,
		thisbrush_start,
		thisbrush_end,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask
	)
end

-- port: model_brush.c Mod_Q3BSP_PointSuperContents L7638-7672 @xonotic-v0.8.6
local function Mod_Q3BSP_PointSuperContents(model: dp_model_t, frame: number, point: { number }): number
	local supercontents = 0
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	if cv.mod_collision_bih.integer ~= 0 then
		supercontents = Mod_CollisionBIH_PointSuperContents(model, frame, point)
	-- test if the point is inside each brush
	elseif model.brush.submodel ~= 0 then
		-- submodels are effectively one leaf
		for i = 0, model.nummodelbrushes - 1 do
			local cb = brushes[model.firstmodelbrush + i + 1].colbrushf
			if cb and collision.Collision_PointInsideBrushFloat(point, cb) then
				supercontents = bit32.bor(supercontents, cb.supercontents)
			end
		end
	else
		local node: mnode_t = model.brush.data_nodes[1]
		-- find which leaf the point is in
		while node.plane do
			local plane = node.plane
			local n = plane.normal
			local d = if plane.type < 3
				then point[plane.type + 1]
				else R(R(R(point[1] * n[1]) + R(point[2] * n[2])) + R(point[3] * n[3]))
			node = node.children[if d < plane.dist then 2 else 1]
		end
		local leaf = node
		-- now check the brushes in the leaf
		local leafbrushes: buffer = model.brush.data_leafbrushes
		for i = 0, leaf.numleafbrushes - 1 do
			local cb = brushes[readi32(leafbrushes, (leaf.firstleafbrush + i) * 4) + 1].colbrushf
			if cb and collision.Collision_PointInsideBrushFloat(point, cb) then
				supercontents = bit32.bor(supercontents, cb.supercontents)
			end
		end
	end
	return supercontents
end

-- The C-static trace functions (reached through the model's function pointers in C), for tests.
model_brush.Mod_Q3BSP_TracePoint = Mod_Q3BSP_TracePoint
model_brush.Mod_Q3BSP_TraceLine = Mod_Q3BSP_TraceLine
model_brush.Mod_Q3BSP_TraceBrush = Mod_Q3BSP_TraceBrush
model_brush.Mod_Q3BSP_TraceBox = Mod_Q3BSP_TraceBox
model_brush.Mod_Q3BSP_PointSuperContents = Mod_Q3BSP_PointSuperContents
model_brush.Mod_Q3BSP_TraceLineOfSight = Mod_Q3BSP_TraceLineOfSight

-- port: model_brush.c Mod_CollisionBIH_TraceLineAgainstSurfaces L7674-7677 @xonotic-v0.8.6
function model_brush.Mod_CollisionBIH_TraceLineAgainstSurfaces(
	model: dp_model_t,
	frameblend: any,
	skeleton: any,
	trace: collision.trace_t,
	start: { number },
	end_: { number },
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
)
	Mod_CollisionBIH_TraceLineShared(
		model,
		frameblend,
		skeleton,
		trace,
		start,
		end_,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		model.render_bih
	)
end

-- bounds of triangle (three vertex indexes at byte offset e of element3i) in vertex3f, each -1 / +1 (float)
local function trianglebounds(vertex3f: buffer, element3i: buffer, e: number): ({ number }, { number })
	local a, b, c = readi32(element3i, e) * 12, readi32(element3i, e + 4) * 12, readi32(element3i, e + 8) * 12
	local mins, maxs = { 0, 0, 0 }, { 0, 0, 0 }
	for k = 0, 2 do
		local x0, x1, x2 = readf32(vertex3f, a + k * 4), readf32(vertex3f, b + k * 4), readf32(vertex3f, c + k * 4)
		mins[k + 1] = R(math.min(x0, math.min(x1, x2)) - 1)
		maxs[k + 1] = R(math.max(x0, math.max(x1, x2)) + 1)
	end
	return mins, maxs
end

-- port: model_brush.c Mod_MakeCollisionBIH L7680-7813 @xonotic-v0.8.6
-- (returns nil when there is nothing to put in the tree, as C returns NULL and leaves *out untouched)
local function Mod_MakeCollisionBIH(model: dp_model_t, userendersurfaces: boolean, out: bih.bih_t): bih.bih_t?
	local bihnumleafs: number
	local bihmaxnodes: number
	local nummodelbrushes: number = model.nummodelbrushes
	local nummodelsurfaces: number = model.nummodelsurfaces
	local surfaces: { any } = model.data_surfaces
	local brushes: { q3mbrush_t } = model.brush.data_brushes
	local function flags(surface: any): number
		return if surface.texture then surface.texture.basematerialflags else 0
	end
	-- find out how many BIH leaf nodes we need
	bihnumleafs = 0
	if userendersurfaces then
		for j = 0, nummodelsurfaces - 1 do
			bihnumleafs += surfaces[model.firstmodelsurface + j + 1].num_triangles
		end
	else
		for brushindex = 0, nummodelbrushes - 1 do
			if brushes[brushindex + model.firstmodelbrush + 1].colbrushf then
				bihnumleafs += 1
			end
		end
		for j = 0, nummodelsurfaces - 1 do
			local surface = surfaces[model.firstmodelsurface + j + 1]
			if bit32.band(flags(surface), MATERIALFLAG_MESHCOLLISIONS) ~= 0 then
				bihnumleafs += surface.num_triangles + surface.num_collisiontriangles
			else
				bihnumleafs += surface.num_collisiontriangles
			end
		end
	end
	if bihnumleafs == 0 then
		return nil
	end
	-- allocate the memory for the BIH leaf nodes
	local bihleafs: { bih.bih_leaf_t } = table.create(bihnumleafs)
	-- now populate the BIH leaf nodes
	local bihleafindex = 0
	-- add render surfaces
	local renderelement3i: buffer = model.surfmesh.data_element3i
	local rendervertex3f: buffer = model.surfmesh.data_vertex3f
	for j = 0, nummodelsurfaces - 1 do
		local surface = surfaces[model.firstmodelsurface + j + 1]
		if not userendersurfaces and bit32.band(flags(surface), MATERIALFLAG_MESHCOLLISIONS) == 0 then
			continue
		end
		for triangleindex = 0, surface.num_triangles - 1 do
			local mins, maxs =
				trianglebounds(rendervertex3f, renderelement3i, (3 * surface.num_firsttriangle + 3 * triangleindex) * 4)
			bihleafindex += 1
			bihleafs[bihleafindex] = {
				type = bih.BIH_RENDERTRIANGLE,
				textureindex = surface.texture.index,
				surfaceindex = surface.index,
				itemindex = triangleindex + surface.num_firsttriangle,
				mins = mins,
				maxs = maxs,
			}
		end
	end
	if not userendersurfaces then
		-- add collision brushes
		for brushindex = 0, nummodelbrushes - 1 do
			local brush = brushes[brushindex + model.firstmodelbrush + 1]
			if not brush.colbrushf then
				continue
			end
			local cb = brush.colbrushf
			bihleafindex += 1
			bihleafs[bihleafindex] = {
				type = bih.BIH_BRUSH,
				textureindex = brush.texture.index,
				surfaceindex = -1,
				itemindex = brushindex + model.firstmodelbrush,
				mins = { cb.mins[1], cb.mins[2], cb.mins[3] },
				maxs = { cb.maxs[1], cb.maxs[2], cb.maxs[3] },
			}
		end
		-- add collision surfaces
		local collisionelement3i: buffer = model.brush.data_collisionelement3i
		local collisionvertex3f: buffer = model.brush.data_collisionvertex3f
		for j = 0, nummodelsurfaces - 1 do
			local surface = surfaces[model.firstmodelsurface + j + 1]
			for triangleindex = 0, surface.num_collisiontriangles - 1 do
				local mins, maxs = trianglebounds(
					collisionvertex3f,
					collisionelement3i,
					(3 * surface.num_firstcollisiontriangle + 3 * triangleindex) * 4
				)
				bihleafindex += 1
				bihleafs[bihleafindex] = {
					type = bih.BIH_COLLISIONTRIANGLE,
					textureindex = surface.texture.index,
					surfaceindex = surface.index,
					itemindex = triangleindex + surface.num_firstcollisiontriangle,
					mins = mins,
					maxs = maxs,
				}
			end
		end
	end
	-- allocate buffers for the produced and temporary data
	bihmaxnodes = bihnumleafs + 1
	-- now build it
	bih.BIH_Build(out, bihnumleafs, bihleafs, bihmaxnodes)
	-- we're done with the temporary data
	out.leafsort = {}
	out.leafsortscratch = {}
	-- resize the BIH nodes array if it over-allocated
	if out.maxnodes > out.numnodes then
		out.maxnodes = out.numnodes
		for k = #out.nodes, out.numnodes + 1, -1 do
			out.nodes[k] = nil
		end
	end
	return out
end
model_brush.Mod_MakeCollisionBIH = Mod_MakeCollisionBIH

-- port: model_brush.c Mod_Q3BSP_RecursiveFindNumLeafs L7875-7886 @xonotic-v0.8.6
local function Mod_Q3BSP_RecursiveFindNumLeafs(node: mnode_t)
	while node.plane do
		Mod_Q3BSP_RecursiveFindNumLeafs(node.children[1])
		node = node.children[2]
	end
	local numleafs = node.index + 1 -- ((mleaf_t *)node - loadmodel->brush.data_leafs) + 1
	if loadmodel.brush.num_leafs < numleafs then
		loadmodel.brush.num_leafs = numleafs
	end
end

-- port: model_brush.c Mod_Q3BSP_Load L7888-8154 @xonotic-v0.8.6
-- buffer / bufferend are the file contents as a string.
local function Mod_Q3BSP_Load(mod: dp_model_t, data: string)
	local filesize = #data

	mod.modeldatatypestring = "Q3BSP"

	mod.type = "mod_brushq3"
	mod.brush.ishlbsp = false
	mod.brush.isbsp2rmqe = false
	mod.brush.isbsp2 = false
	mod.brush.isq2bsp = false
	mod.brush.isq3bsp = true
	mod.brush.skymasking = true
	mod.numframes = 2 -- although alternate textures are not supported it is annoying to complain about no such frame 1
	mod.numskins = 1

	if filesize < SIZEOF_q3dheader_t then
		Host_Error("Mod_Q3BSP_Load: %s is smaller than its header", mod.name)
	end
	local header = buffer.fromstring(data)

	local i = readi32(header, 4)
	if i ~= Q3BSPVERSION and i ~= Q3BSPVERSION_IG and i ~= Q3BSPVERSION_LIVE then
		Host_Error("Mod_Q3BSP_Load: %s has wrong version number (%i, should be %i)", mod.name, i, Q3BSPVERSION)
	end

	mod.soundfromcenter = true
	mod.TraceBox = Mod_Q3BSP_TraceBox
	mod.TraceBrush = Mod_Q3BSP_TraceBrush
	mod.TraceLine = Mod_Q3BSP_TraceLine
	mod.TracePoint = Mod_Q3BSP_TracePoint
	mod.PointSuperContents = Mod_Q3BSP_PointSuperContents
	mod.TraceLineAgainstSurfaces = Mod_CollisionBIH_TraceLine
	mod.brush.TraceLineOfSight = Mod_Q3BSP_TraceLineOfSight
	-- mod->brush.GetPVS ... mod->DrawLight (function pointers): PVS, light point and drawing are NOT YET PORTED
	mod.brush.SuperContentsFromNativeContents = Mod_Q3BSP_SuperContentsFromNativeContents
	mod.brush.NativeContentsFromSuperContents = Mod_Q3BSP_NativeContentsFromSuperContents

	mod_base = header
	loadmodel = mod

	-- swap all the lumps
	local ident = readi32(header, 0)
	local version = readi32(header, 4)
	mod.brushq3.header_ident = ident
	mod.brushq3.header_version = version
	local lumps = if version == Q3BSPVERSION_LIVE then Q3HEADER_LUMPS_LIVE else Q3HEADER_LUMPS
	local hl: { lump_t } = table.create(lumps)
	for li = 0, lumps - 1 do
		local fileofs = readi32(header, 8 + li * 8)
		local j = fileofs
		-- (char *) bufferend < (char *) buffer + j
		if filesize < j then
			Host_Error("Mod_Q3BSP_Load: %s has a lump that starts outside the file!", mod.name)
		end
		local filelen = readi32(header, 8 + li * 8 + 4)
		j += filelen
		if filesize < j then
			Host_Error("Mod_Q3BSP_Load: %s has a lump that ends outside the file!", mod.name)
		end
		hl[li + 1] = { fileofs = fileofs, filelen = filelen }
	end

	mod.brush.qw_md4sum = 0
	mod.brush.qw_md4sum2 = 0
	for li = 0, lumps - 1 do
		if li ~= Q3LUMP_ENTITIES then
			local sum = mdfour.Com_BlockChecksum(
				string.sub(data, hl[li + 1].fileofs + 1, hl[li + 1].fileofs + hl[li + 1].filelen)
			)
			mod.brush.qw_md4sum = bit32.bxor(mod.brush.qw_md4sum, sum)
			if not (li == Q3LUMP_PVS or li == Q3LUMP_LEAFS or li == Q3LUMP_NODES) then
				mod.brush.qw_md4sum2 = bit32.bxor(mod.brush.qw_md4sum2, sum)
			end
			-- all this checksumming can take a while, so let's send keepalives here too
			-- CL_KeepaliveMessage(false)
		end
	end

	Mod_Q3BSP_LoadEntities(hl[Q3LUMP_ENTITIES + 1])
	Mod_Q3BSP_LoadTextures(hl[Q3LUMP_TEXTURES + 1])
	Mod_Q3BSP_LoadPlanes(hl[Q3LUMP_PLANES + 1])
	if version == Q3BSPVERSION_IG then
		Mod_Q3BSP_LoadBrushSides(hl[Q3LUMP_BRUSHSIDES + 1], SIZEOF_q3dbrushside_ig_t)
	else
		Mod_Q3BSP_LoadBrushSides(hl[Q3LUMP_BRUSHSIDES + 1], SIZEOF_q3dbrushside_t)
	end
	Mod_Q3BSP_LoadBrushes(hl[Q3LUMP_BRUSHES + 1])
	Mod_Q3BSP_LoadEffects(hl[Q3LUMP_EFFECTS + 1])
	Mod_Q3BSP_LoadVertices(hl[Q3LUMP_VERTICES + 1])
	Mod_Q3BSP_LoadTriangles(hl[Q3LUMP_TRIANGLES + 1])
	if model_brush.debug_after_triangles then
		model_brush.debug_after_triangles(loadmodel)
	end
	Mod_Q3BSP_LoadLightmaps(hl[Q3LUMP_LIGHTMAPS + 1], hl[Q3LUMP_FACES + 1])
	Mod_Q3BSP_LoadFaces(hl[Q3LUMP_FACES + 1])
	Mod_Q3BSP_LoadModels(hl[Q3LUMP_MODELS + 1])
	Mod_Q3BSP_LoadLeafBrushes(hl[Q3LUMP_LEAFBRUSHES + 1])
	Mod_Q3BSP_LoadLeafFaces(hl[Q3LUMP_LEAFFACES + 1])
	Mod_Q3BSP_LoadLeafs(hl[Q3LUMP_LEAFS + 1])
	Mod_Q3BSP_LoadNodes(hl[Q3LUMP_NODES + 1])
	Mod_Q3BSP_LoadLightGrid(hl[Q3LUMP_LIGHTGRID + 1])
	Mod_Q3BSP_LoadPVS(hl[Q3LUMP_PVS + 1])
	loadmodel.brush.numsubmodels = loadmodel.brushq3.num_models

	-- the MakePortals code works fine on the q3bsp data as well
	if cvar.Cvar_VariableValueOr("mod_bsp_portalize", 1) ~= 0 then
		NOT_YET_PORTED("Mod_Q1BSP_MakePortals (model_brush.c)")
	end

	-- FIXME: shader alpha should replace r_wateralpha support in q3bsp
	loadmodel.brush.supportwateralpha = true

	-- make a single combined shadow mesh to allow optimized shadow volume creation
	NOT_YET_PORTED("Mod_Q1BSP_CreateShadowMesh (model_brush.c)")

	loadmodel.brush.num_leafs = 0
	Mod_Q3BSP_RecursiveFindNumLeafs(loadmodel.brush.data_nodes[1])

	if loadmodel.brush.numsubmodels ~= 0 then
		loadmodel.brush.submodels = table.create(loadmodel.brush.numsubmodels)
	end
	loadmodel.collision_bih = bih.new()
	loadmodel.render_bih = bih.new()

	mod = loadmodel
	for i = 0, loadmodel.brush.numsubmodels - 1 do
		if i > 0 then
			-- duplicate the basic information
			local name = string.sub(string.format("*%i", i), 1, 9) -- dpsnprintf(name, sizeof(name), "*%i", i)
			-- C: mod = Mod_FindName(name, loadmodel->name); *mod = *loadmodel. The model registry
			-- (model_shared.c Mod_FindName) is NOT YET PORTED: the clone is reachable through
			-- loadmodel.brush.submodels only. A C struct copy copies the embedded structs (brush, brushq3,
			-- surfmesh, the two bih_t) by value and shares everything they point to: shallow clones.
			-- copy the base model to this one
			mod = table.clone(loadmodel)
			mod.brush = table.clone(loadmodel.brush)
			mod.brushq3 = table.clone(loadmodel.brushq3)
			mod.surfmesh = table.clone(loadmodel.surfmesh)
			mod.collision_bih = table.clone(loadmodel.collision_bih)
			mod.render_bih = table.clone(loadmodel.render_bih)
			mod.normalmins, mod.normalmaxs = table.clone(loadmodel.normalmins), table.clone(loadmodel.normalmaxs)
			mod.rotatedmins, mod.rotatedmaxs = table.clone(loadmodel.rotatedmins), table.clone(loadmodel.rotatedmaxs)
			mod.yawmins, mod.yawmaxs = table.clone(loadmodel.yawmins), table.clone(loadmodel.yawmaxs)
			-- rename the clone back to its proper name
			mod.name = name
			mod.brush.parentmodel = loadmodel
			-- textures and memory belong to the main model
			mod.texturepool = nil
			mod.mempool = nil
			mod.brush.GetPVS = nil
			mod.brush.FatPVS = nil
			mod.brush.BoxTouchingPVS = nil
			mod.brush.BoxTouchingLeafPVS = nil
			mod.brush.BoxTouchingVisibleLeafs = nil
			mod.brush.FindBoxClusters = nil
			mod.brush.LightPoint = nil
			mod.brush.AmbientSoundLevelsForPoint = nil
		end
		mod.brush.submodel = i
		if loadmodel.brush.submodels then
			loadmodel.brush.submodels[i + 1] = mod
		end

		-- make the model surface list (used by shadowing/lighting)
		local dm: q3dmodel_t = mod.brushq3.data_models[i + 1]
		mod.firstmodelsurface = dm.firstface
		mod.nummodelsurfaces = dm.numfaces
		mod.firstmodelbrush = dm.firstbrush
		mod.nummodelbrushes = dm.numbrushes
		mod.sortedmodelsurfaces = table.create(mod.nummodelsurfaces, 0)
		model_shared.Mod_MakeSortedSurfaces(mod)

		local normalmins = { dm.mins[1], dm.mins[2], dm.mins[3] }
		local normalmaxs = { dm.maxs[1], dm.maxs[2], dm.maxs[3] }
		mod.normalmins, mod.normalmaxs = normalmins, normalmaxs
		-- enlarge the bounding box to enclose all geometry of this model,
		-- because q3map2 sometimes lies (mostly to affect the lightgrid),
		-- which can in turn mess up the farclip (as well as culling when
		-- outside the level - an unimportant concern)
		local vertex3f: buffer = mod.surfmesh.data_vertex3f
		for j = 0, mod.nummodelsurfaces - 1 do
			local surface = mod.data_surfaces[j + mod.firstmodelsurface + 1]
			if surface.num_vertices == 0 then
				continue
			end
			local v = 12 * surface.num_firstvertex
			for _ = 0, surface.num_vertices - 1 do
				local x, y, z = readf32(vertex3f, v), readf32(vertex3f, v + 4), readf32(vertex3f, v + 8)
				normalmins[1] = math.min(normalmins[1], x)
				normalmins[2] = math.min(normalmins[2], y)
				normalmins[3] = math.min(normalmins[3], z)
				normalmaxs[1] = math.max(normalmaxs[1], x)
				normalmaxs[2] = math.max(normalmaxs[2], y)
				normalmaxs[3] = math.max(normalmaxs[3], z)
				v += 12
			end
		end
		local corner = {
			math.max(math.abs(normalmins[1]), math.abs(normalmaxs[1])),
			math.max(math.abs(normalmins[2]), math.abs(normalmaxs[2])),
			math.max(math.abs(normalmins[3]), math.abs(normalmaxs[3])),
		}
		local modelradius =
			R(math.sqrt(R(R(R(corner[1] * corner[1]) + R(corner[2] * corner[2])) + R(corner[3] * corner[3]))))
		local yawradius = R(math.sqrt(R(R(corner[1] * corner[1]) + R(corner[2] * corner[2]))))
		mod.rotatedmins = { -modelradius, -modelradius, -modelradius }
		mod.rotatedmaxs = { modelradius, modelradius, modelradius }
		mod.yawmaxs = { yawradius, yawradius, normalmaxs[3] }
		mod.yawmins = { -yawradius, -yawradius, normalmins[3] }
		mod.radius = modelradius
		mod.radius2 = R(modelradius * modelradius)

		-- this gets altered below if sky or water is used
		-- (C stores the function pointers R_Q1BSP_DrawSky / R_Q1BSP_DrawAddWaterPlanes; here true = set)
		mod.DrawSky = nil
		mod.DrawAddWaterPlanes = nil

		for j = 0, mod.nummodelsurfaces - 1 do
			local texture = mod.data_surfaces[j + mod.firstmodelsurface + 1].texture
			if texture and bit32.band(texture.basematerialflags, MATERIALFLAG_SKY) ~= 0 then
				mod.DrawSky = true
				break
			end
		end

		for j = 0, mod.nummodelsurfaces - 1 do
			local texture = mod.data_surfaces[j + mod.firstmodelsurface + 1].texture
			if
				texture
				and bit32.band(
						texture.basematerialflags,
						MATERIALFLAG_WATERSHADER
							+ MATERIALFLAG_REFRACTION
							+ MATERIALFLAG_REFLECTION
							+ MATERIALFLAG_CAMERA
					)
					~= 0
			then
				mod.DrawAddWaterPlanes = true
				break
			end
		end

		Mod_MakeCollisionBIH(mod, false, mod.collision_bih)
		if model_brush.build_render_bih then
			Mod_MakeCollisionBIH(mod, true, mod.render_bih)
		end

		-- generate VBOs and other shared data before cloning submodels
		-- (i == 0: Mod_BuildVBOs builds OpenGL vertex buffers; nothing to do without a GL backend)
	end

	-- (mod_q3bsp_sRGBlightmaps: loadmodel->lightmapscale *= 2.336f, with the lightmaps; NOT YET PORTED)

	Con_DPrintf(
		'Stats for q3bsp model "%s": %i faces, %i nodes, %i leafs, %i clusters, %i clusterportals, mesh: %i vertices, %i triangles, %i surfaces\n',
		loadmodel.name,
		loadmodel.num_surfaces,
		loadmodel.brush.num_nodes,
		loadmodel.brush.num_leafs,
		mod.brush.num_pvsclusters,
		loadmodel.brush.num_portals or 0,
		0,
		0,
		loadmodel.num_surfaces
	)
end

-- port: model_brush.c Mod_IBSP_Load L8156-8165 @xonotic-v0.8.6
function model_brush.Mod_IBSP_Load(mod: dp_model_t, data: string)
	local i = if #data >= 8 then string.unpack("<i4", data, 5) else 0
	if i == Q3BSPVERSION or i == Q3BSPVERSION_IG or i == Q3BSPVERSION_LIVE then
		Mod_Q3BSP_Load(mod, data)
	elseif i == 38 then -- Q2BSPVERSION
		error("NOT YET PORTED: Mod_Q2BSP_Load (model_brush.c)")
	else
		Host_Error("Mod_IBSP_Load: unknown/unsupported version %i", i)
	end
end

return model_brush
