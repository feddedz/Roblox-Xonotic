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
	brush sides, brushes, effects, vertices, triangles, models, leaf brushes, leaf faces, leafs, nodes, light
	grid and PVS, plus the contents-flag mapping.

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
	only name / surfaceflags / supercontents), Mod_Q3BSP_LoadLightmaps, Mod_Q3BSP_LoadFaces beyond counting the
	surfaces, Mod_Q1BSP_MakePortals, Mod_Q1BSP_CreateShadowMesh, the submodel loop of Mod_Q3BSP_Load
	(bounds, sorted surfaces, Mod_MakeCollisionBIH), all tracing / PVS / light-point functions, the Q1 / Q2 /
	HL BSP and OBJ loaders, Mod_BrushInit (cvar registration: the cvars are read with their defaults).
]]
local collision = require("./collision")
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libc = require("./_port/libc")
local matrixlib = require("./matrixlib")
local mdfour = require("./mdfour")

local model_brush = {}

local R = f32.round
local Con_Printf, Con_DPrintf = console.Con_Printf, console.Con_DPrintf
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
		if surfaces then
			local leafsurfaces: buffer = loadmodel.brush.data_leafsurfaces
			for j = 0, leaf.numleafsurfaces - 1 do
				local surface = surfaces[readi32(leafsurfaces, 4 * (leaf.firstleafsurface + j)) + 1]
				if surface.num_collisiontriangles ~= 0 then
					leaf.containscollisionsurfaces = true
					leaf.combinedsupercontents = bit32.bor(leaf.combinedsupercontents, surface.texture.supercontents)
				end
			end
		else
			NOT_YET_PORTED(
				"Mod_Q1BSP_LoadNodes_RecursiveSetParent: collision surfaces of a leaf (needs Mod_Q3BSP_LoadFaces)"
			)
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

-- model_brush.c Mod_Q3BSP_LoadFaces L5934-6416: only the lump check and the surface count (L5952-5962) so
-- far; the surfaces themselves (meshes, patches, collision triangles) are NOT YET PORTED.
local function Mod_Q3BSP_LoadFaces(l: lump_t)
	if l.filelen % SIZEOF_q3dface_t ~= 0 then
		Host_Error("Mod_Q3BSP_LoadFaces: funny lump size in %s", loadmodel.name)
	end
	local count = l.filelen // SIZEOF_q3dface_t
	loadmodel.num_surfaces = count
	NOT_YET_PORTED("Mod_Q3BSP_LoadFaces (model_brush.c L5934-6416) beyond counting the surfaces")
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
		imins[k] = math.ceil(R(model0.mins[k] * scale[k]))
	end
	for k = 1, 3 do
		imaxs[k] = math.floor(R(model0.maxs[k] * scale[k]))
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

-- port: model_brush.c Mod_Q3BSP_Load L7888-8154 @xonotic-v0.8.6 (PARTIAL: up to the submodel loop)
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
	-- mod->TraceBox ... mod->DrawLight (function pointers): tracing and drawing are NOT YET PORTED
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

	NOT_YET_PORTED("Mod_Q3BSP_Load submodel loop (model_brush.c L8050-8131): bounds, sorted surfaces, collision BIH")

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
