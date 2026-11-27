--!strict
--!native
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

(DarkPlaces model_shared.c / model_shared.h)
]]
--[[
	Port of model_shared.c @xonotic-v0.8.6. PARTIAL (task M3-BSPLOAD): the mesh helpers the Q3 BSP loader calls:
	Mod_BuildTextureVectorsFromNormals, Mod_AllocSurfMesh, Mod_SnapVertices, Mod_RemoveDegenerateTriangles.
	float arrays are f32 buffers and int arrays i32 buffers, passed as (buffer, byte offset) where the C code
	passes a pointer into the middle of an array; every float operation is rounded like C (D-004).
	model_shared.loadmodel is the C global `loadmodel` (set by the loader that is running).
	Q3 shader scripts: Mod_LoadQ3Shaders, Mod_LookupQ3Shader and their helpers; Mod_CreateShaderPass,
	Mod_CreateShaderPassFromQ3ShaderLayer, Mod_LoadTextureFromQ3Shader (end of this file; the renderer calls
	they make on a client are hooks, see R_SkinFrame_LoadMissing below).
	Model registry (task M4-SPAWN): Mod_Init (dedicated part), Mod_UnloadModel, Mod_FindPotentialDeforms,
	Mod_LoadModel (Q3 BSP through model_brush.Mod_IBSP_Load; the other format loaders log NOT YET PORTED and
	leave the 16-unit default box), Mod_ClearUsed, Mod_PurgeUnused, Mod_FindName, Mod_ForName, Mod_Reload.
	NOT YET PORTED: everything else (the alias / sprite / OBJ / Q1BSP loaders, Mod_FrameGroupify, mod_start /
	mod_shutdown / mod_newmap (renderer module), Mod_Print / Mod_Precache / Mod_Decompile_f commands,
	skins, shadow meshes, lightmap allocation, ...).
]]
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local fs = require("./fs")
local libc = require("./_port/libc")
local matrixlib = require("./matrixlib")

local model_shared = {}

local R = f32.round
local Con_Printf, Con_DPrint, Con_DPrintf = console.Con_Printf, console.Con_DPrint, console.Con_DPrintf
local readf32, writef32, readi32, writei32 = buffer.readf32, buffer.writef32, buffer.readi32, buffer.writei32

-- model_shared.c L47: dp_model_t *loadmodel;
model_shared.loadmodel = nil :: any

--[[
	Model registry (model_shared.c L43-46, L156-648).
	`static memexpandablearray_t models` (zone.c Mem_ExpandableArray_*, 16 records per array) is a flat list:
	registry.records[i] is the record at C index i (0-based) and registry.allocflags[i] says whether it is in use.
	AllocRecord takes the first free index (the C arrays are scanned in order, slots in order, so the order is
	the same) and IndexRange is the highest used index + 1, as in zone.c. A record keeps its table across
	FreeRecord / AllocRecord, like the C memory (the pointer of a reused slot is the same), and is zeroed in
	place on allocation.
	The brush loader is reached through hooks model_brush.luau installs when it loads (model_brush requires this
	module): model_shared.Mod_IBSP_Load, model_shared.Mod_BrushInit.
]]
model_shared.Mod_IBSP_Load = nil :: any -- model_brush.c Mod_IBSP_Load (installed by model_brush.luau)
model_shared.Mod_BrushInit = nil :: any -- model_brush.c Mod_BrushInit (installed by model_brush.luau)
-- model_alias.c / model_sprite.c entry points, installed by model_alias.luau / model_sprite.luau when they load
-- (they require this module; ensure_alias_sprite below loads them on first use, after this module is done)
model_shared.Mod_AliasInit = nil :: any
model_shared.Mod_IDP0_Load = nil :: any
model_shared.Mod_IDP2_Load = nil :: any
model_shared.Mod_IDP3_Load = nil :: any
model_shared.Mod_ZYMOTICMODEL_Load = nil :: any
model_shared.Mod_DARKPLACESMODEL_Load = nil :: any
model_shared.Mod_PSKMODEL_Load = nil :: any
model_shared.Mod_INTERQUAKEMODEL_Load = nil :: any
model_shared.Mod_SpriteInit = nil :: any
model_shared.Mod_IDSP_Load = nil :: any
model_shared.Mod_IDS2_Load = nil :: any

-- port support: load model_alias.luau and model_sprite.luau (no require cycle: this runs after model_shared has
-- finished loading, so their require of model_shared gets the finished module)
local function ensure_alias_sprite()
	if model_shared.Mod_AliasInit == nil then
		require("./model_alias")
	end
	if model_shared.Mod_SpriteInit == nil then
		require("./model_sprite")
	end
end

local registry: { records: { [number]: any }, allocflags: { [number]: boolean } } = { records = {}, allocflags = {} }
model_shared.registry = registry

local notported_once: { [string]: boolean } = {}
local function NOT_YET_PORTED(what: string)
	if not notported_once[what] then
		notported_once[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- The fields of a zeroed dp_model_t (memset 0 / Mem_ExpandableArray_AllocRecord) the port reads before a
-- loader sets them; everything else is nil (= 0 / NULL / false). Filled into `mod` in place.
local function zeromodel(mod: any, name: string)
	table.clear(mod)
	mod.name = name
	mod.brush = {}
	mod.brushq3 = {
		num_lightgrid_cellsize = { 0, 0, 0 },
		num_lightgrid_scale = { 0, 0, 0 },
		num_lightgrid_imins = { 0, 0, 0 },
		num_lightgrid_imaxs = { 0, 0, 0 },
		num_lightgrid_isize = { 0, 0, 0 },
		num_lightgrid_indexfromworld = matrixlib.new(),
		num_lightgrid = 0,
		deluxemapping = false,
		deluxemapping_modelspace = false,
	}
	mod.num_surfaces = 0
	mod.lit = false
	mod.used = false
	mod.loaded = false
	mod.crc = 0
end

-- A zeroed dp_model_t outside the registry (port support: loaders tested on their own, model_brush.newmodel).
-- C has no such models; a loader run on one puts its submodels outside the registry too (see
-- Mod_IsRegistered), so standalone loads do not fill the registry with records no Mod_FindName asked for.
function model_shared.Mod_NewModel(name: string): any
	local mod = {}
	zeromodel(mod, name)
	mod.unregistered = true
	return mod
end

-- port support: true for a record of the registry (every model of the engine path), false for Mod_NewModel's
function model_shared.Mod_IsRegistered(mod: any): boolean
	return not mod.unregistered
end

-- port: zone.c Mem_ExpandableArray_AllocRecord L703-740 @xonotic-v0.8.6
local function Mem_ExpandableArray_AllocRecord(): any
	local i = 0
	while registry.allocflags[i] do
		i += 1
	end
	registry.allocflags[i] = true
	local mod = registry.records[i]
	if not mod then
		mod = {}
		registry.records[i] = mod
	end
	zeromodel(mod, "")
	return mod
end

-- port: zone.c Mem_ExpandableArray_FreeRecord L751-769 @xonotic-v0.8.6
local function Mem_ExpandableArray_FreeRecord(record: any)
	for i, r in registry.records do
		if r == record then
			if not registry.allocflags[i] then
				error(string.format("Mem_ExpandableArray_FreeRecord: record %s is already free!", tostring(record)), 0)
			end
			registry.allocflags[i] = false
			return
		end
	end
	error(string.format("Mem_ExpandableArray_FreeRecord: no such record %s", tostring(record)), 0)
end

-- port: zone.c Mem_ExpandableArray_IndexRange L771-786 @xonotic-v0.8.6
local function Mem_ExpandableArray_IndexRange(): number
	local e = 0
	for i, used in registry.allocflags do
		if used and i + 1 > e then
			e = i + 1
		end
	end
	return e
end

-- port: zone.c Mem_ExpandableArray_RecordAtIndex L788-796 @xonotic-v0.8.6
local function Mem_ExpandableArray_RecordAtIndex(index: number): any
	if not registry.allocflags[index] then
		return nil
	end
	return registry.records[index]
end

local function cvarint_ms(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else default
end

-- port: model_shared.c Mod_Init L156-183 @xonotic-v0.8.6
function model_shared.Mod_Init()
	-- mod_mempool = Mem_AllocPool("modelinfo", 0, NULL);
	-- Mem_ExpandableArray_NewArray(&models, mod_mempool, sizeof(dp_model_t), 16);
	registry.records = {}
	registry.allocflags = {}

	model_shared.Mod_BrushInit()
	ensure_alias_sprite()
	model_shared.Mod_AliasInit()
	model_shared.Mod_SpriteInit()

	-- Cvar_RegisterVariable(&r_enableshadowvolumes) ... (&mod_generatelightmaps_gridradius): registered by
	-- engine/host.luau from engine/_port/sv_init_defs.luau, like every cvar of the dedicated init path.
	-- Cmd_AddCommand modellist / modelprecache / modeldecompile / mod_generatelightmaps: registered by host.luau
	-- (NOT YET PORTED stubs: Mod_Print, Mod_Precache, Mod_Decompile_f, Mod_GenerateLightmaps_f).
end

-- port: model_shared.c Mod_UnloadModel L190-224 @xonotic-v0.8.6
function model_shared.Mod_UnloadModel(mod: any)
	if cvarint_ms("developer_loading", 0) ~= 0 then
		Con_Printf("unloading model %s\n", mod.name)
	end

	local name = string.sub(mod.name, 1, 127) -- strlcpy(name, mod->name, sizeof(name)) (MAX_QPATH)
	local parentmodel = mod.brush.parentmodel
	local used = mod.used
	-- (mod->mempool: the GL index / vertex buffers, R_Mesh_DestroyMeshBuffer; no renderer on the server)
	-- free textures/memory attached to the model
	-- R_FreeTexturePool(&mod->texturepool); Mem_FreePool(&mod->mempool);
	-- clear the struct to make it available
	zeromodel(mod, "")
	-- restore the fields we want to preserve
	mod.name = name
	mod.brush.parentmodel = parentmodel
	mod.used = used
	mod.loaded = false
end

local MOD_RADIUS_DEFAULT = 16

-- the text after the last '.' of the last path component, else "" (fs.c's module has no copy yet)
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

-- port: model_shared.c Mod_FindPotentialDeforms L343-368 @xonotic-v0.8.6
-- (texture.deforms[j + 1] nil = Q3DEFORM_NONE; Q3TCGEN_ENVIRONMENT = 2, Q3DEFORM_AUTOSPRITE = 2, model_shared.h)
function model_shared.Mod_FindPotentialDeforms(mod: any)
	mod.wantnormals = false
	mod.wanttangents = false
	for i = 0, (mod.num_textures or 0) - 1 do
		local texture = mod.data_textures[i + 1]
		if texture.materialshaderpass and texture.materialshaderpass.tcgen.tcgen == 2 then
			mod.wantnormals = true
		end
		if texture.materialshaderpass and texture.materialshaderpass.tcgen.tcgen == 2 then
			mod.wantnormals = true
		end
		for j = 0, 4 - 1 do -- Q3MAXDEFORMS
			local d = texture.deforms and texture.deforms[j + 1]
			local deform = if d then d.deform else 0
			if deform == 2 then
				mod.wanttangents = true
				mod.wantnormals = true
				break
			end
			if deform ~= 0 then
				mod.wantnormals = true
			end
		end
	end
end

-- the format loaders of Mod_LoadModel that are not ported: the model keeps what Mod_LoadModel set before the
-- loader call (the 16-unit default box, type mod_invalid), as when the C loader is reached for an unknown type
local function loader_not_ported(loader: string, mod: any)
	NOT_YET_PORTED(
		loader .. " (Mod_LoadModel keeps the default 16-unit box, type mod_invalid; first: " .. mod.name .. ")"
	)
end

-- port: model_shared.c Mod_LoadModel L377-534 @xonotic-v0.8.6
function model_shared.Mod_LoadModel(mod: any, crash: boolean, checkdisk: boolean): any
	local num
	local crc
	local buf: string?

	mod.used = true

	if string.sub(mod.name, 1, 1) == "*" then -- submodel
		return mod
	end

	if mod.name == "null" then
		if mod.loaded then
			return mod
		end

		if mod.loaded or mod.mempool then
			model_shared.Mod_UnloadModel(mod)
		end

		if cvarint_ms("developer_loading", 0) ~= 0 then
			Con_Printf("loading model %s\n", mod.name)
		end

		mod.used = true
		mod.crc = 0xFFFFFFFF -- (unsigned int)-1
		mod.loaded = false

		mod.normalmins = { 0, 0, 0 }
		mod.normalmaxs = { 0, 0, 0 }
		mod.yawmins = { 0, 0, 0 }
		mod.yawmaxs = { 0, 0, 0 }
		mod.rotatedmins = { 0, 0, 0 }
		mod.rotatedmaxs = { 0, 0, 0 }

		mod.modeldatatypestring = "null"
		mod.type = "mod_null"
		mod.Draw = "R_Model_Null_Draw" -- (function pointer; no renderer on the server)
		mod.numframes = 2
		mod.numskins = 1

		-- no fatal errors occurred, so this model is ready to use.
		mod.loaded = true

		return mod
	end

	crc = 0
	buf = nil

	-- even if the model is loaded it still may need reloading...

	-- if it is not loaded or checkdisk is true we need to calculate the crc
	if not mod.loaded or checkdisk then
		if checkdisk and mod.loaded then
			Con_DPrintf("checking model %s\n", mod.name)
		end
		buf = fs.FS_LoadFile(mod.name, false)
		if buf then
			crc = common.CRC_Block(buf)
			-- we need to reload the model if the crc does not match
			if mod.crc ~= crc then
				mod.loaded = false
			end
		end
	end

	-- if the model is already loaded and checks passed, just return
	if mod.loaded then
		return mod
	end

	if cvarint_ms("developer_loading", 0) ~= 0 then
		Con_Printf("loading model %s\n", mod.name)
	end

	-- SCR_PushLoadingScreen(true, mod->name, 1): loading screen (client only)

	-- LordHavoc: unload the existing model in this slot (if there is one)
	if mod.loaded or mod.mempool then
		model_shared.Mod_UnloadModel(mod)
	end

	-- load the model
	mod.used = true
	mod.crc = crc
	-- errors can prevent the corresponding mod->loaded = true;
	mod.loaded = false

	-- default lightmap scale
	mod.lightmapscale = 1

	-- default model radius and bounding box (mainly for missing models)
	mod.radius = MOD_RADIUS_DEFAULT
	local r = mod.radius
	mod.normalmins = { -r, -r, -r }
	mod.normalmaxs = { r, r, r }
	mod.yawmins = { -r, -r, -r }
	mod.yawmaxs = { r, r, r }
	mod.rotatedmins = { -r, -r, -r }
	mod.rotatedmaxs = { r, r, r }

	if not model_shared.Mod_Q3ShadersLoaded() then
		-- load q3 shaders for the first time, or after a level change
		model_shared.Mod_LoadQ3Shaders()
	end

	if buf then
		local data = buf :: string
		-- all models use memory, so allocate a memory pool
		mod.mempool = true -- Mem_AllocPool(mod->name, 0, NULL)

		num = if #data >= 4 then string.unpack("<i4", data) else 0
		local function magic(m: string): boolean
			return string.sub(data, 1, #m) == m
		end
		-- call the apropriate loader
		model_shared.loadmodel = mod
		ensure_alias_sprite()
		if string.lower(FS_FileExtension(mod.name)) == "obj" then
			loader_not_ported("Mod_OBJ_Load (model_brush.c)", mod)
		elseif magic("IDPO") then
			model_shared.Mod_IDP0_Load(mod, data)
		elseif magic("IDP2") then
			model_shared.Mod_IDP2_Load(mod, data)
		elseif magic("IDP3") then
			model_shared.Mod_IDP3_Load(mod, data)
		elseif magic("IDSP") then
			model_shared.Mod_IDSP_Load(mod, data)
		elseif magic("IDS2") then
			model_shared.Mod_IDS2_Load(mod, data)
		elseif magic("IBSP") then
			model_shared.Mod_IBSP_Load(mod, data)
		elseif magic("ZYMOTICMODEL") then
			model_shared.Mod_ZYMOTICMODEL_Load(mod, data)
		elseif magic("DARKPLACESMODEL\0") then
			model_shared.Mod_DARKPLACESMODEL_Load(mod, data)
		elseif magic("ACTRHEAD") then
			model_shared.Mod_PSKMODEL_Load(mod, data)
		elseif magic("INTERQUAKEMODEL\0") then
			model_shared.Mod_INTERQUAKEMODEL_Load(mod, data)
		elseif #mod.name >= 4 and string.sub(mod.name, -4) == ".map" then
			loader_not_ported("Mod_MAP_Load (model_brush.c)", mod)
		elseif num == 29 or num == 30 or magic("BSP2") or magic("2PSB") then -- BSPVERSION 29
			loader_not_ported("Mod_Q1BSP_Load (model_brush.c)", mod)
		else
			Con_Printf('Mod_LoadModel: model "%s" is of unknown/unsupported type\n', mod.name)
		end
		-- Mem_Free(buf);

		model_shared.Mod_FindPotentialDeforms(mod)

		-- va(vabuf, sizeof(vabuf), "%s.framegroups", mod->name): vabuf is char[1024]
		local fg = fs.FS_LoadFile(string.sub(mod.name .. ".framegroups", 1, 1023), false)
		if fg then
			model_shared.Mod_FrameGroupify(mod, fg)
			-- Mem_Free(buf);
		end

		-- Mod_BuildVBOs(): OpenGL vertex buffers (no renderer on the server)
	elseif crash then
		-- LordHavoc: Sys_Error was *ANNOYING*
		Con_Printf("Mod_LoadModel: %s not found\n", mod.name)
	end

	-- no fatal errors occurred, so this model is ready to use.
	mod.loaded = true

	-- SCR_PopLoadingScreen(false)

	return mod
end

-- port: model_shared.c Mod_ClearUsed L536-544 @xonotic-v0.8.6
function model_shared.Mod_ClearUsed()
	local nummodels = Mem_ExpandableArray_IndexRange()
	for i = 0, nummodels - 1 do
		local mod = Mem_ExpandableArray_RecordAtIndex(i)
		if mod and mod.name ~= "" then
			mod.used = false
		end
	end
end

-- port: model_shared.c Mod_PurgeUnused L546-559 @xonotic-v0.8.6
function model_shared.Mod_PurgeUnused()
	local nummodels = Mem_ExpandableArray_IndexRange()
	for i = 0, nummodels - 1 do
		local mod = Mem_ExpandableArray_RecordAtIndex(i)
		if mod and mod.name ~= "" and not mod.used then
			model_shared.Mod_UnloadModel(mod)
			Mem_ExpandableArray_FreeRecord(mod)
		end
	end
end

-- port: model_shared.c Mod_FindName L567-604 @xonotic-v0.8.6
function model_shared.Mod_FindName(name: string, parentname: string?): any
	local pname = parentname or ""

	-- if we're not dedicatd, the renderer calls will crash without video
	-- Host_StartVideo(): does nothing on a dedicated server

	local nummodels = Mem_ExpandableArray_IndexRange()

	if name == "" then
		error("Host_Error: Mod_ForName: empty name", 0)
	end

	-- search the currently loaded models
	for i = 0, nummodels - 1 do
		local mod = Mem_ExpandableArray_RecordAtIndex(i)
		if
			mod
			and mod.name ~= ""
			and mod.name == name
			and (
				(not mod.brush.parentmodel and pname == "")
				or (mod.brush.parentmodel and pname ~= "" and mod.brush.parentmodel.name == pname)
			)
		then
			mod.used = true
			return mod
		end
	end

	-- no match found, create a new one
	local mod = Mem_ExpandableArray_AllocRecord()
	mod.name = string.sub(name, 1, 127) -- strlcpy(mod->name, name, sizeof(mod->name)) (MAX_QPATH)
	if pname ~= "" then
		mod.brush.parentmodel = model_shared.Mod_FindName(pname, nil)
	else
		mod.brush.parentmodel = nil
	end
	mod.loaded = false
	mod.used = true
	return mod
end

-- port: model_shared.c Mod_ForName L613-620 @xonotic-v0.8.6
function model_shared.Mod_ForName(name: string, crash: boolean, checkdisk: boolean, parentname: string?): any
	local model = model_shared.Mod_FindName(name, parentname)
	if not model.loaded or checkdisk then
		model_shared.Mod_LoadModel(model, crash, checkdisk)
	end
	return model
end

-- port: model_shared.c Mod_Reload L629-648 @xonotic-v0.8.6 (the loading screen calls are client only)
function model_shared.Mod_Reload()
	local count
	local nummodels = Mem_ExpandableArray_IndexRange()

	count = 0
	for i = 0, nummodels - 1 do
		local mod = Mem_ExpandableArray_RecordAtIndex(i)
		if mod and mod.name ~= "" and string.sub(mod.name, 1, 1) ~= "*" and mod.used then
			count += 1
		end
	end
	for i = 0, nummodels - 1 do
		local mod = Mem_ExpandableArray_RecordAtIndex(i)
		if mod and mod.name ~= "" and string.sub(mod.name, 1, 1) ~= "*" and mod.used then
			model_shared.Mod_LoadModel(mod, true, true)
		end
	end
end

-- VectorNormalize (mathlib.h L118) on 3 floats at byte offset o of b
local function VectorNormalize_b(b: buffer, o: number)
	local x, y, z = readf32(b, o), readf32(b, o + 4), readf32(b, o + 8)
	local ilength = R(math.sqrt(R(R(R(x * x) + R(y * y)) + R(z * z))))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	writef32(b, o, x * ilength)
	writef32(b, o + 4, y * ilength)
	writef32(b, o + 8, z * ilength)
end

-- port: model_shared.c Mod_BuildTextureVectorsFromNormals L924-1002 @xonotic-v0.8.6
-- (elements: i32 buffer + byte offset; the float arrays are whole buffers, indexed from vertex 0)
function model_shared.Mod_BuildTextureVectorsFromNormals(
	firstvertex: number,
	numvertices: number,
	numtriangles: number,
	vertex3f: buffer,
	texcoord2f: buffer,
	normal3f: buffer,
	elements: buffer,
	eofs: number,
	svector3f: buffer,
	tvector3f: buffer,
	areaweighting: boolean
)
	local sdir = { 0, 0, 0 }
	local tdir = { 0, 0, 0 }
	local normal = { 0, 0, 0 }
	local f: number
	local tangentcross = { 0, 0, 0 }
	local v10 = { 0, 0, 0 }
	local v20 = { 0, 0, 0 }
	local tc10 = { 0, 0 }
	local tc20 = { 0, 0 }
	-- clear the vectors
	buffer.fill(svector3f, 3 * firstvertex * 4, 0, numvertices * 12)
	buffer.fill(tvector3f, 3 * firstvertex * 4, 0, numvertices * 12)
	-- process each vertex of each triangle and accumulate the results
	for tnum = 0, numtriangles - 1 do
		local e = eofs + tnum * 12
		local e0, e1, e2 = readi32(elements, e), readi32(elements, e + 4), readi32(elements, e + 8)
		local v0, v1, v2 = e0 * 12, e1 * 12, e2 * 12
		local tc0, tc1, tc2 = e0 * 8, e1 * 8, e2 * 8
		-- calculate the edge directions and surface normal
		-- 6 multiply, 9 subtract
		for k = 0, 2 do
			local a = readf32(vertex3f, v0 + k * 4)
			v10[k + 1] = R(readf32(vertex3f, v1 + k * 4) - a)
			v20[k + 1] = R(readf32(vertex3f, v2 + k * 4) - a)
		end
		normal[1] = R(R(v20[2] * v10[3]) - R(v20[3] * v10[2]))
		normal[2] = R(R(v20[3] * v10[1]) - R(v20[1] * v10[3]))
		normal[3] = R(R(v20[1] * v10[2]) - R(v20[2] * v10[1]))
		-- calculate the tangents
		-- 12 multiply, 10 subtract
		tc10[2] = R(readf32(texcoord2f, tc1 + 4) - readf32(texcoord2f, tc0 + 4))
		tc20[2] = R(readf32(texcoord2f, tc2 + 4) - readf32(texcoord2f, tc0 + 4))
		sdir[1] = R(R(tc10[2] * v20[1]) - R(tc20[2] * v10[1]))
		sdir[2] = R(R(tc10[2] * v20[2]) - R(tc20[2] * v10[2]))
		sdir[3] = R(R(tc10[2] * v20[3]) - R(tc20[2] * v10[3]))
		tc10[1] = R(readf32(texcoord2f, tc1) - readf32(texcoord2f, tc0))
		tc20[1] = R(readf32(texcoord2f, tc2) - readf32(texcoord2f, tc0))
		tdir[1] = R(R(tc10[1] * v20[1]) - R(tc20[1] * v10[1]))
		tdir[2] = R(R(tc10[1] * v20[2]) - R(tc20[1] * v10[2]))
		tdir[3] = R(R(tc10[1] * v20[3]) - R(tc20[1] * v10[3]))
		-- if texture is mapped the wrong way (counterclockwise), the tangents
		-- have to be flipped, this is detected by calculating a normal from the
		-- two tangents, and seeing if it is opposite the surface normal
		-- 9 multiply, 2 add, 3 subtract, 1 compare, 50% chance of: 6 negates
		tangentcross[1] = R(R(tdir[2] * sdir[3]) - R(tdir[3] * sdir[2]))
		tangentcross[2] = R(R(tdir[3] * sdir[1]) - R(tdir[1] * sdir[3]))
		tangentcross[3] = R(R(tdir[1] * sdir[2]) - R(tdir[2] * sdir[1]))
		if
			R(R(R(tangentcross[1] * normal[1]) + R(tangentcross[2] * normal[2])) + R(tangentcross[3] * normal[3]))
			< 0
		then
			sdir[1], sdir[2], sdir[3] = -sdir[1], -sdir[2], -sdir[3]
			tdir[1], tdir[2], tdir[3] = -tdir[1], -tdir[2], -tdir[3]
		end
		if not areaweighting then
			local il = R(math.sqrt(R(R(R(sdir[1] * sdir[1]) + R(sdir[2] * sdir[2])) + R(sdir[3] * sdir[3]))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			sdir[1], sdir[2], sdir[3] = R(sdir[1] * il), R(sdir[2] * il), R(sdir[3] * il)
			il = R(math.sqrt(R(R(R(tdir[1] * tdir[1]) + R(tdir[2] * tdir[2])) + R(tdir[3] * tdir[3]))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			tdir[1], tdir[2], tdir[3] = R(tdir[1] * il), R(tdir[2] * il), R(tdir[3] * il)
		end
		for i = 0, 2 do
			local o = readi32(elements, e + i * 4) * 12
			writef32(svector3f, o, readf32(svector3f, o) + sdir[1])
			writef32(svector3f, o + 4, readf32(svector3f, o + 4) + sdir[2])
			writef32(svector3f, o + 8, readf32(svector3f, o + 8) + sdir[3])
			writef32(tvector3f, o, readf32(tvector3f, o) + tdir[1])
			writef32(tvector3f, o + 4, readf32(tvector3f, o + 4) + tdir[2])
			writef32(tvector3f, o + 8, readf32(tvector3f, o + 8) + tdir[3])
		end
	end
	-- make the tangents completely perpendicular to the surface normal, and
	-- then normalize them
	-- 16 assignments, 2 divide, 2 sqrt, 2 negates, 14 adds, 24 multiplies
	for i = 0, numvertices - 1 do
		local o = (firstvertex + i) * 12
		local n1, n2, n3 = readf32(normal3f, o), readf32(normal3f, o + 4), readf32(normal3f, o + 8)
		for _, vec in { svector3f, tvector3f } do
			local a, b, c = readf32(vec, o), readf32(vec, o + 4), readf32(vec, o + 8)
			f = -R(R(R(a * n1) + R(b * n2)) + R(c * n3))
			writef32(vec, o, a + R(f * n1))
			writef32(vec, o + 4, b + R(f * n2))
			writef32(vec, o + 8, c + R(f * n3))
			VectorNormalize_b(vec, o)
		end
	end
end

-- port: model_shared.c Mod_AllocSurfMesh L1004-1031 @xonotic-v0.8.6
-- (C carves the arrays out of one allocation; here each array is its own zeroed buffer)
function model_shared.Mod_AllocSurfMesh(
	numvertices: number,
	numtriangles: number,
	lightmapoffsets: boolean,
	vertexcolors: boolean,
	neighbors: boolean
)
	local loadmodel = model_shared.loadmodel
	local surfmesh = loadmodel.surfmesh
	if not surfmesh then
		surfmesh = {}
		loadmodel.surfmesh = surfmesh
	end
	surfmesh.num_vertices = numvertices
	surfmesh.num_triangles = numtriangles
	if surfmesh.num_vertices ~= 0 then
		surfmesh.data_vertex3f = buffer.create(12 * numvertices)
		surfmesh.data_svector3f = buffer.create(12 * numvertices)
		surfmesh.data_tvector3f = buffer.create(12 * numvertices)
		surfmesh.data_normal3f = buffer.create(12 * numvertices)
		surfmesh.data_texcoordtexture2f = buffer.create(8 * numvertices)
		surfmesh.data_texcoordlightmap2f = buffer.create(8 * numvertices)
		if vertexcolors then
			surfmesh.data_lightmapcolor4f = buffer.create(16 * numvertices)
		end
		if lightmapoffsets then
			surfmesh.data_lightmapoffsets = buffer.create(4 * numvertices)
		end
	end
	if surfmesh.num_triangles ~= 0 then
		surfmesh.data_element3i = buffer.create(12 * numtriangles)
		if neighbors then
			surfmesh.data_neighbor3i = buffer.create(12 * numtriangles)
		end
		if surfmesh.num_vertices <= 65536 then
			surfmesh.data_element3s = buffer.create(6 * numtriangles)
		end
	end
end

-- port: model_shared.c Mod_SnapVertices L3001-3007 @xonotic-v0.8.6
function model_shared.Mod_SnapVertices(
	numcomponents: number,
	numvertices: number,
	vertices: buffer,
	vofs: number,
	snap: number
)
	local isnap = 1.0 / snap
	for i = 0, numvertices * numcomponents - 1 do
		local o = vofs + i * 4
		writef32(vertices, o, math.floor(readf32(vertices, o) * isnap) * snap)
	end
end

-- port: model_shared.c Mod_RemoveDegenerateTriangles L3009-3031 @xonotic-v0.8.6
-- (inelement3i and outelement3i may be the same place, as in C; vertex3f is indexed from vertex 0)
function model_shared.Mod_RemoveDegenerateTriangles(
	numtriangles: number,
	inelement3i: buffer,
	inofs: number,
	outelement3i: buffer,
	outofs: number,
	vertex3f: buffer
): number
	local outtriangles = 0
	local limit = R(0.001) -- 0.001f
	-- a degenerate triangle is one with no width (thickness, surface area)
	-- these are characterized by having all 3 points colinear (along a line)
	-- or having two points identical
	-- the simplest check is to calculate the triangle's area
	for i = 0, numtriangles - 1 do
		local ip = inofs + i * 12
		local e0, e1, e2 = readi32(inelement3i, ip), readi32(inelement3i, ip + 4), readi32(inelement3i, ip + 8)
		local a, b, c = e0 * 12, e1 * 12, e2 * 12
		-- calculate first edge
		local ax, ay, az = readf32(vertex3f, a), readf32(vertex3f, a + 4), readf32(vertex3f, a + 8)
		local d1x, d1y, d1z =
			R(readf32(vertex3f, b) - ax), R(readf32(vertex3f, b + 4) - ay), R(readf32(vertex3f, b + 8) - az)
		local d2x, d2y, d2z =
			R(readf32(vertex3f, c) - ax), R(readf32(vertex3f, c + 4) - ay), R(readf32(vertex3f, c + 8) - az)
		local tx = R(R(d1y * d2z) - R(d1z * d2y))
		local ty = R(R(d1z * d2x) - R(d1x * d2z))
		local tz = R(R(d1x * d2y) - R(d1y * d2x))
		if R(R(R(tx * tx) + R(ty * ty)) + R(tz * tz)) < limit then
			continue -- degenerate triangle (no area)
		end
		-- valid triangle (has area)
		local op = outofs + outtriangles * 12
		writei32(outelement3i, op, e0)
		writei32(outelement3i, op + 4, e1)
		writei32(outelement3i, op + 8, e2)
		outtriangles += 1
	end
	return outtriangles
end

-- port: model_shared.c Mod_MakeSortedSurfaces L3055-3086 @xonotic-v0.8.6
-- (mod.sortedmodelsurfaces: 1-based array of surface indexes, C element j at [j + 1])
function model_shared.Mod_MakeSortedSurfaces(mod: any)
	-- make an optimal set of texture-sorted batches to draw...
	local t: number
	if not mod.sortedmodelsurfaces then
		mod.sortedmodelsurfaces = table.create(mod.nummodelsurfaces, 0)
	end
	local sorted: { number } = mod.sortedmodelsurfaces
	local firstsurfacefortexture = table.create(mod.num_textures, 0)
	local numsurfacesfortexture = table.create(mod.num_textures, 0)
	for j = 0, mod.nummodelsurfaces - 1 do
		local surface = mod.data_surfaces[j + mod.firstmodelsurface + 1]
		t = surface.texture.index
		numsurfacesfortexture[t + 1] += 1
	end
	local j = 0
	for ti = 0, mod.num_textures - 1 do
		firstsurfacefortexture[ti + 1] = j
		j += numsurfacesfortexture[ti + 1]
	end
	for k = 0, mod.nummodelsurfaces - 1 do
		local surface = mod.data_surfaces[k + mod.firstmodelsurface + 1]
		t = surface.texture.index
		sorted[firstsurfacefortexture[t + 1] + 1] = k + mod.firstmodelsurface
		firstsurfacefortexture[t + 1] += 1
	end
end

-- ---------------------------------------------------------------------------------------------------------
-- Mesh helpers and skin files the alias / sprite loaders call (task M4-ALIAS)

-- #if 1: fast way, using an edge hash
local TRIANGLEEDGEHASH = 8192
-- port: model_shared.c Mod_BuildTriangleNeighbors L709-777 @xonotic-v0.8.6
-- (neighbors, elements: i32 buffers from triangle 0. The hash chains are Luau arrays walked from the last
-- entry, as the C pushes each entry at the head of its chain.)
function model_shared.Mod_BuildTriangleNeighbors(neighbors: buffer, elements: buffer, numtriangles: number)
	if numtriangles == 0 then
		return
	end
	local edgehash: { [number]: { number } } = {}
	-- entry k (= i * 3 + j) holds triangle i and the edge (e[p], e[j])
	local htri = table.create(numtriangles * 3, 0)
	local he1 = table.create(numtriangles * 3, 0)
	local he2 = table.create(numtriangles * 3, 0)
	-- find neighboring triangles
	for i = 0, numtriangles - 1 do
		local p = 2
		for j = 0, 2 do
			local e1 = readi32(elements, (i * 3 + p) * 4)
			local e2 = readi32(elements, (i * 3 + j) * 4)
			-- this hash index works for both forward and backward edges
			local hashindex = ((e1 + e2) % 4294967296) % TRIANGLEEDGEHASH
			local k = i * 3 + j
			local chain = edgehash[hashindex]
			if not chain then
				chain = {}
				edgehash[hashindex] = chain
			end
			table.insert(chain, k)
			htri[k + 1] = i
			he1[k + 1] = e1
			he2[k + 1] = e2
			p = j
		end
	end
	for i = 0, numtriangles - 1 do
		local p = 2
		for j = 0, 2 do
			local e1 = readi32(elements, (i * 3 + p) * 4)
			local e2 = readi32(elements, (i * 3 + j) * 4)
			-- this hash index works for both forward and backward edges
			local hashindex = ((e1 + e2) % 4294967296) % TRIANGLEEDGEHASH
			local count = 0
			local match = -1
			local chain = edgehash[hashindex]
			for c = #chain, 1, -1 do
				local k = chain[c] + 1
				if he1[k] == e2 and he2[k] == e1 then
					if htri[k] ~= i then
						match = htri[k]
					end
					count += 1
				elseif he1[k] == e1 and he2[k] == e2 then
					count += 1
				end
			end
			-- detect edges shared by three triangles and make them seams
			if count > 2 then
				match = -1
			end
			writei32(neighbors, (i * 3 + p) * 4, match)
			p = j
		end

		-- also send a keepalive here (this can take a while too!)
		-- CL_KeepaliveMessage(false): network keepalive while loading, no effect on the data (not ported)
	end
	-- free the allocated buffer
end

-- port: model_shared.c Mod_ValidateElements L819-834 @xonotic-v0.8.6 (elements: i32 buffer + byte offset)
function model_shared.Mod_ValidateElements(
	elements: buffer,
	eofs: number,
	numtriangles: number,
	firstvertex: number,
	numverts: number,
	filename: string,
	fileline: number
)
	local warned = false
	local endvertex = firstvertex + numverts
	for i = 0, numtriangles * 3 - 1 do
		local o = eofs + i * 4
		local e = readi32(elements, o)
		if e < firstvertex or e >= endvertex then
			if not warned then
				warned = true
				Con_Printf("Mod_ValidateElements: out of bounds elements detected at %s:%d\n", filename, fileline)
			end
			writei32(elements, o, firstvertex)
		end
	end
end

-- warning: this is an expensive function!
-- port: model_shared.c Mod_BuildNormals L837-875 @xonotic-v0.8.6
-- (vertex3f / normal3f: f32 buffers from vertex 0; elements: i32 buffer + byte offset)
function model_shared.Mod_BuildNormals(
	firstvertex: number,
	numvertices: number,
	numtriangles: number,
	vertex3f: buffer,
	elements: buffer,
	eofs: number,
	normal3f: buffer,
	areaweighting: boolean
)
	-- clear the vectors
	buffer.fill(normal3f, 3 * firstvertex * 4, 0, numvertices * 12)
	-- process each vertex of each triangle and accumulate the results
	-- use area-averaging, to make triangles with a big area have a bigger
	-- weighting on the vertex normal than triangles with a small area
	-- to do so, just add the 'normals' together (the bigger the area
	-- the greater the length of the normal is
	for i = 0, numtriangles - 1 do
		local eo = eofs + i * 12
		local a = readi32(elements, eo) * 12
		local b = readi32(elements, eo + 4) * 12
		local c = readi32(elements, eo + 8) * 12
		local a0, a1, a2 = readf32(vertex3f, a), readf32(vertex3f, a + 4), readf32(vertex3f, a + 8)
		local b0, b1, b2 = readf32(vertex3f, b), readf32(vertex3f, b + 4), readf32(vertex3f, b + 8)
		local c0, c1, c2 = readf32(vertex3f, c), readf32(vertex3f, c + 4), readf32(vertex3f, c + 8)
		-- TriangleNormal (mathlib.h L140-144)
		local n0 = R(R(R(a1 - b1) * R(c2 - b2)) - R(R(a2 - b2) * R(c1 - b1)))
		local n1 = R(R(R(a2 - b2) * R(c0 - b0)) - R(R(a0 - b0) * R(c2 - b2)))
		local n2 = R(R(R(a0 - b0) * R(c1 - b1)) - R(R(a1 - b1) * R(c0 - b0)))

		if not areaweighting then
			-- VectorNormalize (mathlib.h)
			local ilength = R(math.sqrt(R(R(R(n0 * n0) + R(n1 * n1)) + R(n2 * n2))))
			if ilength ~= 0 then
				ilength = R(1.0 / ilength)
			end
			n0, n1, n2 = R(n0 * ilength), R(n1 * ilength), R(n2 * ilength)
		end

		for j = 0, 2 do
			local o = readi32(elements, eo + j * 4) * 12
			writef32(normal3f, o, readf32(normal3f, o) + n0)
			writef32(normal3f, o + 4, readf32(normal3f, o + 4) + n1)
			writef32(normal3f, o + 8, readf32(normal3f, o + 8) + n2)
		end
	end
	-- and just normalize the accumulated vertex normal in the end
	for i = 0, numvertices - 1 do
		VectorNormalize_b(normal3f, (firstvertex + i) * 12)
	end
end

--[[
	skinfile_t / skinfileitem_t (model_shared.h): { next: skinfile?, items: skinfileitem? } and
	{ next: skinfileitem?, name: string, replacement: string } (linked lists as in C; nil = NULL).
]]
-- port: model_shared.c Mod_LoadSkinFiles L2873-2976 @xonotic-v0.8.6
function model_shared.Mod_LoadSkinFiles(): any
	local loadmodel = model_shared.loadmodel
	local words: number
	local wordsoverflow: boolean
	local skinfile: any = nil
	local first: any = nil
	-- char word[10][MAX_QPATH], cleared once: a line with fewer words keeps the words of the lines before it
	local word: { string } = { "", "", "", "", "", "", "", "", "", "" }
	local developer_loading = cvarint_ms("developer_loading", 0) ~= 0
	local QC = common.COM_ParseToken_QuakeC

	--[[
sample file:
U_bodyBox,models/players/Legoman/BikerA2.tga
U_RArm,models/players/Legoman/BikerA1.tga
U_LArm,models/players/Legoman/BikerA1.tga
U_armor,common/nodraw
U_sword,common/nodraw
U_shield,common/nodraw
U_homb,common/nodraw
U_backpack,common/nodraw
U_colcha,common/nodraw
tag_head,
tag_weapon,
tag_torso,
]]
	local i = 0
	while i < 256 do
		-- va(vabuf, sizeof(vabuf), "%s_%i.skin", loadmodel->name, i): vabuf is char[1024]
		local text = fs.FS_LoadFile(string.sub(string.format("%s_%d.skin", loadmodel.name, i), 1, 1023), true)
		if not text then
			break
		end
		-- (the C buffer is a C string: it ends at the first NUL)
		local nul = string.find(text, "\0", 1, true)
		if nul then
			text = string.sub(text, 1, nul - 1)
		end
		local data: number? = 1
		-- If it's the first file we parse
		if skinfile == nil then
			skinfile = { next = nil, items = nil }
			first = skinfile
		else
			skinfile.next = { next = nil, items = nil }
			skinfile = skinfile.next
		end
		skinfile.next = nil

		local line = 0
		while true do
			-- parse line
			local ok
			ok, data = QC(text, data, true)
			if not ok then
				break
			end
			if common.com_token == "\n" then
				line += 1
				continue
			end
			words = 0
			wordsoverflow = false
			repeat
				if words < 10 then
					words += 1
					word[words] = string.sub(common.com_token, 1, 127) -- strlcpy(word[words++], com_token, sizeof (word[0]))
				else
					wordsoverflow = true
				end
				ok, data = QC(text, data, true)
			until not (ok and common.com_token ~= "\n")
			if wordsoverflow then
				Con_Printf(
					'Mod_LoadSkinFiles: parsing error in file "%s_%i.skin" on line #%i: line with too many statements, skipping\n',
					loadmodel.name,
					i,
					line
				)
				line += 1
				continue
			end
			-- words is always >= 1
			-- selene: allow(empty_if)
			if word[1] == "replace" then
				if words == 3 then
					if developer_loading then
						Con_Printf('Mod_LoadSkinFiles: parsed mesh "%s" shader replacement "%s"\n', word[2], word[3])
					end
					local skinfileitem = { next = skinfile.items, name = word[2], replacement = word[3] }
					skinfile.items = skinfileitem
				else
					Con_Printf(
						'Mod_LoadSkinFiles: parsing error in file "%s_%i.skin" on line #%i: wrong number of parameters to command "%s", see documentation in DP_GFX_SKINFILES extension in dpextensions.qc\n',
						loadmodel.name,
						i,
						line,
						word[1]
					)
				end
			elseif words >= 2 and string.sub(word[1], 1, 4) == "tag_" then
				-- tag name, like "tag_weapon,"
				-- not used for anything (not even in Quake3)
			elseif words >= 2 and word[2] == "," then
				-- mesh shader name, like "U_RArm,models/players/Legoman/BikerA1.tga"
				if developer_loading then
					Con_Printf('Mod_LoadSkinFiles: parsed mesh "%s" shader replacement "%s"\n', word[1], word[3])
				end
				local skinfileitem = { next = skinfile.items, name = word[1], replacement = word[3] }
				skinfile.items = skinfileitem
			else
				Con_Printf(
					'Mod_LoadSkinFiles: parsing error in file "%s_%i.skin" on line #%i: does not look like tag or mesh specification, or replace command, see documentation in DP_GFX_SKINFILES extension in dpextensions.qc\n',
					loadmodel.name,
					i,
					line
				)
			end
			line += 1
		end
		-- Mem_Free(text);
		i += 1
	end
	if i ~= 0 then
		loadmodel.numskins = i
	end
	return first
end

-- port: model_shared.c Mod_FreeSkinFiles L2978-2992 @xonotic-v0.8.6 (memory only: nothing to do here)
function model_shared.Mod_FreeSkinFiles(_skinfile: any) end

-- port: model_shared.c Mod_CountSkinFiles L2994-2999 @xonotic-v0.8.6
function model_shared.Mod_CountSkinFiles(skinfile: any): number
	local i = 0
	while skinfile do
		skinfile = skinfile.next
		i += 1
	end
	return i
end

-- port: model_shared.c Mod_FrameGroupify_ParseGroups L234-305 @xonotic-v0.8.6
-- (cb: the callback, or nil = NULL; name nil = NULL)
local function Mod_FrameGroupify_ParseGroups(
	buf: string,
	cb: ((number, number, number, number, boolean, string?, any) -> ())?,
	pass: any
): number
	local bufptr: number?
	local start: number
	local len: number
	local fps: number
	local i: number
	local loop: boolean
	local name: string
	local P = common.COM_ParseToken_Simple
	local function tok(): string
		return common.com_token
	end

	bufptr = 1
	i = 0
	while bufptr do
		-- an anim scene!

		-- REQUIRED: fetch start
		bufptr = select(2, P(buf, bufptr, true, false, true))
		if not bufptr then
			break -- end of file
		end
		if tok() == "\n" then
			continue -- empty line
		end
		start = libc.atoi(tok())

		-- REQUIRED: fetch length
		bufptr = select(2, P(buf, bufptr, true, false, true))
		if not bufptr or tok() == "\n" then
			Con_Printf("framegroups file: missing number of frames\n")
			continue
		end
		len = libc.atoi(tok())

		-- OPTIONAL args start
		bufptr = select(2, P(buf, bufptr, true, false, true))

		-- OPTIONAL: fetch fps
		fps = 20
		if bufptr and tok() ~= "\n" then
			fps = R(libc.atof(tok()))
			bufptr = select(2, P(buf, bufptr, true, false, true))
		end

		-- OPTIONAL: fetch loopflag
		loop = true
		if bufptr and tok() ~= "\n" then
			loop = (libc.atoi(tok()) ~= 0)
			bufptr = select(2, P(buf, bufptr, true, false, true))
		end

		-- OPTIONAL: fetch name
		name = ""
		if bufptr and tok() ~= "\n" then
			name = string.sub(tok(), 1, 63) -- strlcpy(name, com_token, sizeof(name))
			bufptr = select(2, P(buf, bufptr, true, false, true))
		end

		-- OPTIONAL: remaining unsupported tokens (eat them)
		while bufptr and tok() ~= "\n" do
			bufptr = select(2, P(buf, bufptr, true, false, true))
		end

		--Con_Printf("data: %d %d %d %f %d (%s)\n", i, start, len, fps, loop, name);

		if cb then
			cb(i, start, len, fps, loop, if name ~= "" then name else nil, pass)
		end
		i += 1
	end

	return i
end

-- port: model_shared.c Mod_FrameGroupify_ParseGroups_Store L307-320 @xonotic-v0.8.6
local function Mod_FrameGroupify_ParseGroups_Store(
	i: number,
	start: number,
	len: number,
	fps: number,
	loop: boolean,
	name: string?,
	pass: any
)
	local mod = pass
	local anim = mod.animscenes[i + 1]
	if name then
		anim.name = string.sub(name, 1, 31) -- strlcpy(anim->name, name, sizeof(anim[i].name))
	else
		anim.name = string.sub(string.format("groupified_%d_anim", i), 1, 31)
	end
	-- bound(0, start, mod->num_poses - 1), bound(1, len, ...), max(1, fps) (mathlib.h ternaries)
	local num_poses = mod.num_poses or 0 -- (0 in a zeroed dp_model_t: sprites do not set it)
	local hi = num_poses - 1
	anim.firstframe = if start >= 0 then (if start < hi then start else hi) else 0
	hi = num_poses - anim.firstframe
	anim.framecount = if len >= 1 then (if len < hi then len else hi) else 1
	anim.framerate = if 1 > fps then 1 else fps
	anim.loop = loop
	--Con_Printf("frame group %d is %d %d %f %d\n", i, start, len, fps, loop);
end

-- port: model_shared.c Mod_FrameGroupify L322-341 @xonotic-v0.8.6
function model_shared.Mod_FrameGroupify(mod: any, buf: string)
	local cnt: number

	-- (the C buffer is a C string: it ends at the first NUL)
	local nul = string.find(buf, "\0", 1, true)
	if nul then
		buf = string.sub(buf, 1, nul - 1)
	end

	-- 0. count
	cnt = Mod_FrameGroupify_ParseGroups(buf, nil, nil)
	if cnt == 0 then
		Con_Printf("no scene found in framegroups file, aborting\n")
		return
	end
	mod.numframes = cnt

	-- 1. reallocate
	-- (we do not free the previous animscenes, but model unloading will free the pool owning them, so it's okay)
	local scenes = table.create(cnt)
	for k = 1, cnt do
		scenes[k] = { name = "", firstframe = 0, framecount = 0, loop = false, framerate = 0 }
	end
	mod.animscenes = scenes

	-- 2. parse
	Mod_FrameGroupify_ParseGroups(buf, Mod_FrameGroupify_ParseGroups_Store, mod)
end

-- ---------------------------------------------------------------------------------------------------------
-- Q3 shader scripts (model_shared.c L48-61, L1552-2413; model_shared.h L257-509)

-- model_shared.h L259-278
model_shared.Q3TEXTUREFLAG_TWOSIDED = 1
model_shared.Q3TEXTUREFLAG_NOPICMIP = 16
model_shared.Q3TEXTUREFLAG_POLYGONOFFSET = 32
model_shared.Q3TEXTUREFLAG_REFRACTION = 256
model_shared.Q3TEXTUREFLAG_REFLECTION = 512
model_shared.Q3TEXTUREFLAG_WATERSHADER = 1024
model_shared.Q3TEXTUREFLAG_CAMERA = 2048
model_shared.Q3TEXTUREFLAG_TRANSPARENTSORT = 4096
local Q3TEXTUREFLAG_TWOSIDED = 1
local Q3TEXTUREFLAG_NOPICMIP = 16
local Q3TEXTUREFLAG_POLYGONOFFSET = 32
local Q3TEXTUREFLAG_REFRACTION = 256
local Q3TEXTUREFLAG_REFLECTION = 512
local Q3TEXTUREFLAG_WATERSHADER = 1024
local Q3TEXTUREFLAG_CAMERA = 2048
local Q3TEXTUREFLAG_TRANSPARENTSORT = 4096
local Q3PATHLENGTH = 64
local TEXTURE_MAXFRAMES = 64
local Q3WAVEPARMS = 4
local Q3DEFORM_MAXPARMS = 3
local Q3SHADER_MAXLAYERS = 8
local Q3RGBGEN_MAXPARMS = 3
local Q3ALPHAGEN_MAXPARMS = 1
local Q3TCGEN_MAXPARMS = 6
local Q3TCMOD_MAXPARMS = 6
local Q3MAXTCMODS = 8
local Q3MAXDEFORMS = 4
model_shared.Q3SHADER_MAXLAYERS = Q3SHADER_MAXLAYERS
model_shared.Q3MAXTCMODS = Q3MAXTCMODS
model_shared.Q3MAXDEFORMS = Q3MAXDEFORMS
model_shared.TEXTURE_MAXFRAMES = TEXTURE_MAXFRAMES

-- q3wavefunc_e L280-294
model_shared.Q3WAVEFUNC_NONE = 0
model_shared.Q3WAVEFUNC_INVERSESAWTOOTH = 1
model_shared.Q3WAVEFUNC_NOISE = 2
model_shared.Q3WAVEFUNC_SAWTOOTH = 3
model_shared.Q3WAVEFUNC_SIN = 4
model_shared.Q3WAVEFUNC_SQUARE = 5
model_shared.Q3WAVEFUNC_TRIANGLE = 6
model_shared.Q3WAVEFUNC_COUNT = 7
model_shared.Q3WAVEFUNC_USER_COUNT = 4
model_shared.Q3WAVEFUNC_USER_SHIFT = 8 -- use 8 bits for wave func type
local Q3WAVEFUNC_USER_SHIFT = 8
-- q3deform_e L296-316
model_shared.Q3DEFORM = {
	NONE = 0,
	PROJECTIONSHADOW = 1,
	AUTOSPRITE = 2,
	AUTOSPRITE2 = 3,
	TEXT0 = 4,
	TEXT1 = 5,
	TEXT2 = 6,
	TEXT3 = 7,
	TEXT4 = 8,
	TEXT5 = 9,
	TEXT6 = 10,
	TEXT7 = 11,
	BULGE = 12,
	WAVE = 13,
	NORMAL = 14,
	MOVE = 15,
	COUNT = 16,
}
-- q3rgbgen_e L318-332
model_shared.Q3RGBGEN = {
	IDENTITY = 0,
	CONST = 1,
	ENTITY = 2,
	EXACTVERTEX = 3,
	IDENTITYLIGHTING = 4,
	LIGHTINGDIFFUSE = 5,
	ONEMINUSENTITY = 6,
	ONEMINUSVERTEX = 7,
	VERTEX = 8,
	WAVE = 9,
	COUNT = 10,
}
local Q3RGBGEN_IDENTITY, Q3RGBGEN_LIGHTINGDIFFUSE, Q3RGBGEN_VERTEX, Q3RGBGEN_WAVE = 0, 5, 8, 9
-- q3alphagen_e L334-347
model_shared.Q3ALPHAGEN = {
	IDENTITY = 0,
	CONST = 1,
	ENTITY = 2,
	LIGHTINGSPECULAR = 3,
	ONEMINUSENTITY = 4,
	ONEMINUSVERTEX = 5,
	PORTAL = 6,
	VERTEX = 7,
	WAVE = 8,
	COUNT = 9,
}
local Q3ALPHAGEN_IDENTITY, Q3ALPHAGEN_VERTEX, Q3ALPHAGEN_WAVE = 0, 7, 8
-- q3tcgen_e L349-358
model_shared.Q3TCGEN = { NONE = 0, TEXTURE = 1, ENVIRONMENT = 2, LIGHTMAP = 3, VECTOR = 4, COUNT = 5 }
local Q3TCGEN_TEXTURE = 1
-- q3tcmod_e L360-373
model_shared.Q3TCMOD = {
	NONE = 0,
	ENTITYTRANSLATE = 1,
	ROTATE = 2,
	SCALE = 3,
	SCROLL = 4,
	STRETCH = 5,
	TRANSFORM = 6,
	TURBULENT = 7,
	PAGE = 8,
	COUNT = 9,
}
local Q3TCMOD_STRETCH = 5
-- dpoffsetmapping_technique_t L434-440, dptransparentsortcategory_t L442-447
model_shared.OFFSETMAPPING_OFF = 0
model_shared.OFFSETMAPPING_DEFAULT = 1
model_shared.OFFSETMAPPING_LINEAR = 2
model_shared.OFFSETMAPPING_RELIEF = 3
model_shared.TRANSPARENTSORT_SKY = 0
model_shared.TRANSPARENTSORT_DISTANCE = 1
model_shared.TRANSPARENTSORT_HUD = 2
local OFFSETMAPPING_OFF, OFFSETMAPPING_DEFAULT, OFFSETMAPPING_LINEAR, OFFSETMAPPING_RELIEF = 0, 1, 2, 3
local TRANSPARENTSORT_SKY, TRANSPARENTSORT_DISTANCE, TRANSPARENTSORT_HUD = 0, 1, 2

-- bspfile.h Q3SURFACEPARM_* (by the name used after `surfaceparm`)
local SURFACEPARMS: { [string]: number } = {
	alphashadow = 1,
	areaportal = 2,
	clusterportal = 4,
	detail = 8,
	donotenter = 16,
	fog = 32,
	lava = 64,
	lightfilter = 128,
	metalsteps = 256,
	nodamage = 512,
	nodlight = 1024,
	nodraw = 2048,
	nodrop = 4096,
	noimpact = 8192,
	nolightmap = 16384,
	nomarks = 32768,
	nomipmaps = 65536,
	nonsolid = 131072,
	origin = 262144,
	playerclip = 524288,
	sky = 1048576,
	slick = 2097152,
	slime = 4194304,
	structural = 8388608,
	trans = 16777216,
	water = 33554432,
	pointlight = 67108864,
	hint = 134217728,
	dust = 268435456,
	botclip = 536870912,
	lightgrid = 1073741824,
	antiportal = 2147483648,
}
model_shared.Q3SURFACEPARM = SURFACEPARMS
local Q3SURFACEPARM_NOMIPMAPS = 65536
local Q3SURFACEPARM_SKY = 1048576

-- glquake.h blend factors
local GL_ZERO, GL_ONE = 0x0, 0x1
local GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR = 0x0300, 0x0301
local GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA = 0x0302, 0x0303
local GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA = 0x0304, 0x0305
local GL_DST_COLOR, GL_ONE_MINUS_DST_COLOR = 0x0306, 0x0307
local BLENDFACTORS: { [string]: number } = {
	gl_one = GL_ONE,
	gl_zero = GL_ZERO,
	gl_src_color = GL_SRC_COLOR,
	gl_src_alpha = GL_SRC_ALPHA,
	gl_dst_color = GL_DST_COLOR,
	gl_dst_alpha = GL_DST_ALPHA,
	gl_one_minus_src_color = GL_ONE_MINUS_SRC_COLOR,
	gl_one_minus_src_alpha = GL_ONE_MINUS_SRC_ALPHA,
	gl_one_minus_dst_color = GL_ONE_MINUS_DST_COLOR,
	gl_one_minus_dst_alpha = GL_ONE_MINUS_DST_ALPHA,
}
-- r_textures.h TEXF_*
local TEXF_ALPHA = 0x00000001
local TEXF_MIPMAP = 0x00000002
local TEXF_CLAMP = 0x00000020
local TEXF_PICMIP = 0x00000100
local TEXF_COMPRESS = 0x00000200

local RGBGENS: { [string]: number } = {
	identity = 0,
	const = 1,
	entity = 2,
	exactvertex = 3,
	identitylighting = 4,
	lightingdiffuse = 5,
	oneminusentity = 6,
	oneminusvertex = 7,
	vertex = 8,
}
local ALPHAGENS: { [string]: number } = {
	identity = 0,
	const = 1,
	entity = 2,
	lightingspecular = 3,
	oneminusentity = 4,
	oneminusvertex = 5,
	portal = 6,
	vertex = 7,
}
local TCGENS: { [string]: number } = { base = 1, texture = 1, environment = 2, lightmap = 3, vector = 4 }
local TCMODS: { [string]: number } = {
	entitytranslate = 1,
	rotate = 2,
	scale = 3,
	scroll = 4,
	page = 8,
	transform = 6,
	turb = 7,
}
local DEFORMS: { [string]: number } = {
	projectionshadow = 1,
	autosprite = 2,
	autosprite2 = 3,
	text0 = 4,
	text1 = 5,
	text2 = 6,
	text3 = 7,
	text4 = 8,
	text5 = 9,
	text6 = 10,
	text7 = 11,
	bulge = 12,
	normal = 14,
}

--[[
	q3shaderinfo_t (model_shared.h L449-509) as a table with the C field names. Arrays that C zero-fills hold only
	the used entries here; a missing entry is a zeroed one:
	  * layers[1 .. numlayers] (C layers[0 .. numlayers - 1]); a killed shader (numlayers = 0) keeps its parsed
	    layers in the table, as the C struct does.
	  * layer.tcmods[i], shader.deforms[i]: nil means tcmod / deform 0 (Q3TCMOD_NONE / Q3DEFORM_NONE).
	  * layer.texturename: nil (NULL) or a list of numframes names.
	surfaceparms is kept as an unsigned 32-bit value (Q3SURFACEPARM_ANTIPORTAL is bit 31).
]]
export type q3shaderinfo_t = { [string]: any }
export type q3shaderinfo_layer_t = { [string]: any }

-- a zeroed q3shaderinfo_layer_t
local function newlayer(): q3shaderinfo_layer_t
	return {
		alphatest = false,
		clampmap = false,
		framerate = 0,
		numframes = 0,
		dptexflags = 0,
		texturename = nil,
		blendfunc = { 0, 0 },
		rgbgen = { rgbgen = 0, parms = { 0, 0, 0 }, wavefunc = 0, waveparms = { 0, 0, 0, 0 } },
		alphagen = { alphagen = 0, parms = { 0 }, wavefunc = 0, waveparms = { 0, 0, 0, 0 } },
		tcgen = { tcgen = 0, parms = { 0, 0, 0, 0, 0, 0 } },
		tcmods = {},
	}
end

-- a zeroed q3shaderinfo_t (memset(&shader, 0, sizeof(shader)))
local function newshader(): q3shaderinfo_t
	return {
		name = "",
		surfaceparms = 0,
		surfaceflags = 0,
		textureflags = 0,
		numlayers = 0,
		lighting = false,
		vertexalpha = false,
		textureblendalpha = false,
		layers = {},
		skyboxname = "",
		deforms = {},
		dpnortlight = false,
		dpshadow = false,
		dpnoshadow = false,
		dpmeshcollisions = false,
		dpshaderkill = false,
		dpreflectcube = "",
		reflectmin = 0,
		reflectmax = 0,
		refractfactor = 0,
		refractcolor4f = { 0, 0, 0, 0 },
		reflectfactor = 0,
		reflectcolor4f = { 0, 0, 0, 0 },
		r_water_wateralpha = 0,
		r_water_waterscroll = { 0, 0 },
		offsetmapping = 0,
		offsetscale = 0,
		offsetbias = 0,
		biaspolygonoffset = 0,
		biaspolygonfactor = 0,
		transparentsort = 0,
		specularscalemod = 0,
		specularpowermod = 0,
		rtlightambient = 0,
	}
end

-- model_shared.c L48-61: static mempool_t* q3shaders_mem; static q3shader_data_t* q3shader_data;
-- hash[i] is the head entry of bucket i ({ shader, chain }); C has all 1021 heads zeroed, here a head is made
-- (zeroed) when it is first looked at. `loaded` stands for q3shaders_mem != NULL.
local Q3SHADER_HASH_SIZE = 1021
local q3shaders_loaded = false
local q3shader_data: { hash: { [number]: any } } = { hash = {} }
-- q3shaders_mem != NULL (read by Mod_LoadModel, which is above this point in the file)
function model_shared.Mod_Q3ShadersLoaded(): boolean
	return q3shaders_loaded
end

local function hashhead(index: number): any
	local entry = q3shader_data.hash[index]
	if not entry then
		entry = { shader = newshader(), chain = nil }
		q3shader_data.hash[index] = entry
	end
	return entry
end

local function lower(s: string): string
	return string.lower(s)
end

-- port: model_shared.c Mod_LoadQ3Shaders_EnumerateWaveFunc L1552-1572 @xonotic-v0.8.6
local function Mod_LoadQ3Shaders_EnumerateWaveFunc(s: string): number
	local offset = 0
	if lower(string.sub(s, 1, 4)) == "user" then -- parse stuff like "user1sin", always user<n>func
		offset = math.clamp((string.byte(s, 5) or 0) - 48, 0, 9)
		offset = bit32.lshift(offset + 1, Q3WAVEFUNC_USER_SHIFT)
		s = string.sub(s, 5)
		if s ~= "" then
			s = string.sub(s, 2)
		end
	end
	local l = lower(s)
	if l == "sin" then
		return bit32.bor(offset, 4)
	elseif l == "square" then
		return bit32.bor(offset, 5)
	elseif l == "triangle" then
		return bit32.bor(offset, 6)
	elseif l == "sawtooth" then
		return bit32.bor(offset, 3)
	elseif l == "inversesawtooth" then
		return bit32.bor(offset, 1)
	elseif l == "noise" then
		return bit32.bor(offset, 2)
	elseif l == "none" then
		return bit32.bor(offset, 0)
	end
	Con_DPrintf("Mod_LoadQ3Shaders: unknown wavefunc %s\n", s)
	return bit32.bor(offset, 0)
end

-- port: model_shared.c Mod_FreeQ3Shaders L1574-1577 @xonotic-v0.8.6
function model_shared.Mod_FreeQ3Shaders()
	q3shaders_loaded = false
	q3shader_data = { hash = {} }
end

-- memcmp of the Q3SHADERINFO_COMPARE_START .. COMPARE_END range of two shaders: true when it differs. A layer's
-- texturename is a pointer in C, so two layers with texture names never compare equal.
local function shaderdiffers(a: any, b: any): boolean
	local function differ(x: any, y: any): boolean
		if type(x) ~= type(y) then
			return true
		end
		if type(x) ~= "table" then
			return x ~= y
		end
		for k, v in x do
			if k == "texturename" then
				return true
			end
			if differ(v, y[k]) then
				return true
			end
		end
		for k in y do
			if x[k] == nil then
				return true
			end
		end
		return false
	end
	for k, v in a do
		if k ~= "name" and differ(v, b[k]) then
			return true
		end
	end
	return false
end

-- port: model_shared.c Q3Shader_AddToHash L1579-1635 @xonotic-v0.8.6
local function Q3Shader_AddToHash(shader: q3shaderinfo_t)
	local hash = common.CRC_Block_CaseInsensitive(shader.name)
	local entry: any = hashhead(hash % Q3SHADER_HASH_SIZE)
	local lastEntry: any = nil
	repeat
		if lower(entry.shader.name) == lower(shader.name) then
			-- redeclaration
			if shader.dpshaderkill then
				-- killed shader is a redeclarion? we can safely ignore it
				return
			elseif entry.shader.dpshaderkill then
				-- replace the old shader!
				-- this will skip the entry allocating part
				-- below and just replace the shader
				break
			else
				if shaderdiffers(shader, entry.shader) then
					Con_DPrintf("Shader '%s' already defined, ignoring mismatching redeclaration\n", shader.name)
				else
					Con_DPrintf("Shader '%s' already defined\n", shader.name)
				end
				return
			end
		end
		lastEntry = entry
		entry = entry.chain
	until entry == nil
	if entry == nil then
		if lastEntry.shader.name ~= "" then
			-- Add to chain
			local newEntry = { shader = nil, chain = nil }
			while lastEntry.chain ~= nil do
				lastEntry = lastEntry.chain
			end
			lastEntry.chain = newEntry
			lastEntry = newEntry
		end
		-- else: head of chain, in hash entry array
		entry = lastEntry
	end
	entry.shader = shader -- memcpy (&entry->shader, shader, sizeof (q3shaderinfo_t));
end

-- The low 32 bits (unsigned) of the 64-bit long strtol(s, NULL, 0) returns (glibc: clamped to LONG_MAX /
-- LONG_MIN on overflow): all the caller keeps of it (custsurfaceflags[] is ORed into an int). The value is
-- tracked as two exact 32-bit halves, so digits past 2^53 are not rounded away.
local function strtol0(s: string): number
	local i = 1
	while string.find(string.sub(s, i, i), "^%s") do
		i += 1
	end
	local neg = false
	local c = string.sub(s, i, i)
	if c == "+" or c == "-" then
		neg = c == "-"
		i += 1
	end
	local base = 10
	if string.sub(s, i, i) == "0" then
		local x = string.sub(s, i + 1, i + 1)
		if (x == "x" or x == "X") and string.find(string.sub(s, i + 2, i + 2), "^%x") then
			base = 16
			i += 2
		else
			base = 8
		end
	end
	local lo, hi = 0, 0 -- magnitude = hi * 2^32 + lo; hi stops growing past 2^31 (overflow either way)
	while true do
		local d = tonumber(string.sub(s, i, i), 36)
		if not d or d >= base then
			break
		end
		local t = lo * base + d
		lo = t % 4294967296
		hi = math.min(hi * base + (t - lo) / 4294967296, 4294967296)
		i += 1
	end
	if not neg then
		return if hi >= 2147483648 then 4294967295 else lo -- LONG_MAX
	end
	if hi > 2147483648 or (hi == 2147483648 and lo > 0) then
		return 0 -- LONG_MIN
	end
	return (4294967296 - lo) % 4294967296
end

-- the value of a static cvar_t of model_brush.c / host.c (registered by host.luau), or its default
local function cvarvalue(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.value else default
end

-- port: model_shared.c Mod_LoadQ3Shaders L1645-2396 @xonotic-v0.8.6
function model_shared.Mod_LoadQ3Shaders()
	local numparameters = 0
	-- char parameter[TEXTURE_MAXFRAMES + 4][Q3PATHLENGTH]: C never clears it, so a keyword that reads more
	-- parameters than its line has sees what an earlier line left there. Kept (C index k is parameter[k + 1]).
	local parameter: { string } = table.create(TEXTURE_MAXFRAMES + 4, "")
	local custsurfaceparmnames: { string } = {}
	local custsurfaceflags: { number } = {}
	local numcustsurfaceflags = 0
	local dpshaderkill = false
	local text = ""
	local pos: number? = nil
	local QC = common.COM_ParseToken_QuakeC

	model_shared.Mod_FreeQ3Shaders()

	q3shaders_loaded = true
	q3shader_data = { hash = {} }

	-- parse custinfoparms.txt
	numcustsurfaceflags = 0
	local f = fs.FS_LoadFile("scripts/custinfoparms.txt", false)
	if f then
		text, pos = f, 1
		local ok: boolean
		ok, pos = QC(text, pos, false)
		if not ok or common.com_token ~= "{" then
			Con_DPrintf(
				'scripts/custinfoparms.txt: contentflags section parsing error - expected "{", found "%s"\n',
				common.com_token
			)
		else
			while true do
				ok, pos = QC(text, pos, false)
				if not ok or common.com_token == "}" then
					break
				end
			end
			-- custom surfaceflags section
			ok, pos = QC(text, pos, false)
			if not ok or common.com_token ~= "{" then
				Con_DPrintf(
					'scripts/custinfoparms.txt: surfaceflags section parsing error - expected "{", found "%s"\n',
					common.com_token
				)
			else
				while true do
					ok, pos = QC(text, pos, false)
					if not ok then
						break
					end
					if common.com_token == "}" then
						break
					end
					-- register surfaceflag
					if numcustsurfaceflags >= 256 then
						Con_Printf(
							"scripts/custinfoparms.txt: surfaceflags section parsing error - max 256 surfaceflags exceeded\n"
						)
						break
					end
					-- name
					custsurfaceparmnames[numcustsurfaceflags + 1] = common.com_token
					-- value
					ok, pos = QC(text, pos, false)
					if ok then
						custsurfaceflags[numcustsurfaceflags + 1] = strtol0(common.com_token)
					else
						custsurfaceflags[numcustsurfaceflags + 1] = 0
					end
					numcustsurfaceflags += 1
				end
			end
		end
	end

	-- the "for (j = 0; strcasecmp(com_token, "\n") && strcasecmp(com_token, "}"); j++)" loop of both parameter
	-- readers: com_token holds the first token on entry and the token that ended the line on exit ("" at the end
	-- of the file)
	local function readparameters()
		numparameters = 0
		local j = 0
		local tok = common.com_token
		while tok ~= "\n" and tok ~= "}" do
			if j < TEXTURE_MAXFRAMES + 4 then
				-- remap dp_water to dpwater, dp_reflect to dpreflect, etc.
				if j == 0 and lower(string.sub(tok, 1, 3)) == "dp_" then
					parameter[j + 1] = string.sub("dp" .. string.sub(tok, 4), 1, Q3PATHLENGTH - 1)
				else
					parameter[j + 1] = string.sub(tok, 1, Q3PATHLENGTH - 1)
				end
				numparameters = j + 1
			end
			local ok: boolean
			ok, pos = QC(text, pos, true)
			if not ok then
				break
			end
			tok = common.com_token
			j += 1
		end
	end
	local function P(k: number): string
		return parameter[k + 1]
	end
	local function PL(k: number): string
		return lower(parameter[k + 1])
	end
	local function atof(k: number): number
		return libc.atof(parameter[k + 1])
	end

	-- the cvar_t fields the parser reads (model_brush.c L55-61, host.c developer_insane)
	local default_offsetmapping = cvarvalue("mod_q3shader_default_offsetmapping", 1)
	local default_offsetmapping_scale = cvarvalue("mod_q3shader_default_offsetmapping_scale", 1)
	local default_offsetmapping_bias = cvarvalue("mod_q3shader_default_offsetmapping_bias", 0)
	local default_polygonoffset = cvarvalue("mod_q3shader_default_polygonoffset", -2)
	local default_polygonfactor = cvarvalue("mod_q3shader_default_polygonfactor", 0)
	local force_addalpha = cvarvalue("mod_q3shader_force_addalpha", 0) ~= 0
	local force_terrain_alphaflag = cvarvalue("mod_q3shader_force_terrain_alphaflag", 0) ~= 0
	local developer_insane = cvarvalue("developer_insane", 0) ~= 0

	-- parse shaders
	local search = fs.FS_Search("scripts/*.shader", true, false)
	if not search then
		return
	end
	for fileindex = 0, #search - 1 do
		local filename = search[fileindex + 1]
		local filetext = fs.FS_LoadFile(filename, false)
		if not filetext then
			continue
		end
		text, pos = filetext, 1
		while true do
			local ok: boolean
			ok, pos = QC(text, pos, false)
			if not ok then
				break
			end
			local shader = newshader()
			shader.reflectmin = 0
			shader.reflectmax = 1
			shader.refractfactor = 1
			shader.refractcolor4f = { 1, 1, 1, 1 }
			shader.reflectfactor = 1
			shader.reflectcolor4f = { 1, 1, 1, 1 }
			shader.r_water_wateralpha = 1
			shader.r_water_waterscroll[1] = 0
			shader.r_water_waterscroll[2] = 0
			shader.offsetmapping = if default_offsetmapping ~= 0 then OFFSETMAPPING_DEFAULT else OFFSETMAPPING_OFF
			shader.offsetscale = default_offsetmapping_scale
			shader.offsetbias = default_offsetmapping_bias
			shader.biaspolygonoffset = default_polygonoffset
			shader.biaspolygonfactor = default_polygonfactor
			shader.transparentsort = TRANSPARENTSORT_DISTANCE
			shader.specularscalemod = 1
			shader.specularpowermod = 1
			shader.rtlightambient = 0
			-- WHEN ADDING DEFAULTS HERE, REMEMBER TO PUT DEFAULTS IN ALL LOADERS
			-- JUST GREP FOR "specularscalemod = 1".

			shader.name = string.sub(common.com_token, 1, Q3PATHLENGTH - 1)
			ok, pos = QC(text, pos, false)
			if not ok or common.com_token ~= "{" then
				Con_DPrintf('%s parsing error - expected "{", found "%s"\n', filename, common.com_token)
				break
			end
			while true do
				ok, pos = QC(text, pos, false)
				if not ok then
					break
				end
				if common.com_token == "}" then
					break
				end
				if common.com_token == "{" then
					local layer: q3shaderinfo_layer_t
					if shader.numlayers < Q3SHADER_MAXLAYERS then
						layer = newlayer()
						shader.numlayers += 1
						shader.layers[shader.numlayers] = layer
					else
						-- parse and process it anyway, just don't store it (so a map $lightmap or such stuff still is found)
						layer = newlayer()
					end
					layer.rgbgen.rgbgen = Q3RGBGEN_IDENTITY
					layer.alphagen.alphagen = Q3ALPHAGEN_IDENTITY
					layer.tcgen.tcgen = Q3TCGEN_TEXTURE
					layer.blendfunc[1] = GL_ONE
					layer.blendfunc[2] = GL_ZERO
					while true do
						ok, pos = QC(text, pos, false)
						if not ok then
							break
						end
						if common.com_token == "}" then
							break
						end
						if common.com_token == "\n" then
							continue
						end
						readparameters()
						if developer_insane then
							Con_DPrintf("%s %i: ", shader.name, shader.numlayers - 1)
							for j = 0, numparameters - 1 do
								Con_DPrintf(" %s", P(j))
							end
							Con_DPrint("\n")
						end
						local p0 = PL(0)
						if numparameters >= 2 and p0 == "blendfunc" then
							if numparameters == 2 then
								local p1 = PL(1)
								if p1 == "add" then
									layer.blendfunc[1] = GL_ONE
									layer.blendfunc[2] = GL_ONE
								elseif p1 == "addalpha" then
									layer.blendfunc[1] = GL_SRC_ALPHA
									layer.blendfunc[2] = GL_ONE
								elseif p1 == "filter" then
									layer.blendfunc[1] = GL_DST_COLOR
									layer.blendfunc[2] = GL_ZERO
								elseif p1 == "blend" then
									layer.blendfunc[1] = GL_SRC_ALPHA
									layer.blendfunc[2] = GL_ONE_MINUS_SRC_ALPHA
								end
							elseif numparameters == 3 then
								for k = 0, 1 do
									-- GL_ONE: default in case of parsing error
									layer.blendfunc[k + 1] = BLENDFACTORS[PL(k + 1)] or GL_ONE
								end
							end
						end
						if numparameters >= 2 and p0 == "alphafunc" then
							layer.alphatest = true
						end
						if numparameters >= 2 and (p0 == "map" or p0 == "clampmap") then
							if p0 == "clampmap" then
								layer.clampmap = true
							end
							layer.numframes = 1
							layer.framerate = 1
							layer.texturename = { P(1) }
							if PL(1) == "$lightmap" then
								shader.lighting = true
							end
						elseif numparameters >= 3 and (p0 == "animmap" or p0 == "animclampmap") then
							layer.numframes = math.min(numparameters - 2, TEXTURE_MAXFRAMES)
							layer.framerate = R(atof(1))
							local names = table.create(layer.numframes)
							for i = 0, layer.numframes - 1 do
								names[i + 1] = P(i + 2)
							end
							layer.texturename = names
						elseif numparameters >= 2 and p0 == "rgbgen" then
							local i = 0
							while i < numparameters - 2 and i < Q3RGBGEN_MAXPARMS do
								layer.rgbgen.parms[i + 1] = R(atof(i + 2))
								i += 1
							end
							local p1 = PL(1)
							local gen = RGBGENS[p1]
							if gen then
								layer.rgbgen.rgbgen = gen
							elseif p1 == "wave" then
								layer.rgbgen.rgbgen = Q3RGBGEN_WAVE
								layer.rgbgen.wavefunc = Mod_LoadQ3Shaders_EnumerateWaveFunc(P(2))
								i = 0
								while i < numparameters - 3 and i < Q3WAVEPARMS do
									layer.rgbgen.waveparms[i + 1] = R(atof(i + 3))
									i += 1
								end
							else
								Con_DPrintf("%s parsing warning: unknown rgbgen %s\n", filename, P(1))
							end
						elseif numparameters >= 2 and p0 == "alphagen" then
							local i = 0
							while i < numparameters - 2 and i < Q3ALPHAGEN_MAXPARMS do
								layer.alphagen.parms[i + 1] = R(atof(i + 2))
								i += 1
							end
							local p1 = PL(1)
							local gen = ALPHAGENS[p1]
							if gen then
								layer.alphagen.alphagen = gen
							elseif p1 == "wave" then
								layer.alphagen.alphagen = Q3ALPHAGEN_WAVE
								layer.alphagen.wavefunc = Mod_LoadQ3Shaders_EnumerateWaveFunc(P(2))
								i = 0
								while i < numparameters - 3 and i < Q3WAVEPARMS do
									layer.alphagen.waveparms[i + 1] = R(atof(i + 3))
									i += 1
								end
							else
								Con_DPrintf("%s parsing warning: unknown alphagen %s\n", filename, P(1))
							end
						elseif numparameters >= 2 and (p0 == "texgen" or p0 == "tcgen") then
							-- observed values: tcgen environment
							-- no other values have been observed in real shaders
							local i = 0
							while i < numparameters - 2 and i < Q3TCGEN_MAXPARMS do
								layer.tcgen.parms[i + 1] = R(atof(i + 2))
								i += 1
							end
							local gen = TCGENS[PL(1)]
							if gen then
								layer.tcgen.tcgen = gen
							else
								Con_DPrintf("%s parsing warning: unknown tcgen mode %s\n", filename, P(1))
							end
						elseif numparameters >= 2 and p0 == "tcmod" then
							-- observed values:
							-- tcmod rotate #
							-- tcmod scale # #
							-- tcmod scroll # #
							-- tcmod stretch sin # # # #
							-- tcmod stretch triangle # # # #
							-- tcmod transform # # # # # #
							-- tcmod turb # # # #
							-- tcmod turb sin # # # #  (this is bogus)
							-- no other values have been observed in real shaders
							local tcmodindex = 0
							while tcmodindex < Q3MAXTCMODS do
								local m = layer.tcmods[tcmodindex + 1]
								if not m or m.tcmod == 0 then
									break
								end
								tcmodindex += 1
							end
							if tcmodindex < Q3MAXTCMODS then
								local m = layer.tcmods[tcmodindex + 1]
								if not m then
									-- (a zeroed entry; the entries before it exist, they were found non-zero)
									m = {
										tcmod = 0,
										parms = { 0, 0, 0, 0, 0, 0 },
										wavefunc = 0,
										waveparms = { 0, 0, 0, 0 },
									}
									layer.tcmods[tcmodindex + 1] = m
								end
								local i = 0
								while i < numparameters - 2 and i < Q3TCMOD_MAXPARMS do
									m.parms[i + 1] = R(atof(i + 2))
									i += 1
								end
								local p1 = PL(1)
								local mode = TCMODS[p1]
								if mode then
									m.tcmod = mode
								elseif p1 == "stretch" then
									m.tcmod = Q3TCMOD_STRETCH
									m.wavefunc = Mod_LoadQ3Shaders_EnumerateWaveFunc(P(2))
									i = 0
									while i < numparameters - 3 and i < Q3WAVEPARMS do
										m.waveparms[i + 1] = R(atof(i + 3))
										i += 1
									end
								else
									Con_DPrintf("%s parsing warning: unknown tcmod mode %s\n", filename, P(1))
								end
							else
								Con_DPrintf("%s parsing warning: too many tcmods on one layer\n", filename)
							end
						end
						-- break out a level if it was a closing brace (not using the character here to not confuse vim)
						if common.com_token == "}" then
							break
						end
					end
					if layer.rgbgen.rgbgen == Q3RGBGEN_LIGHTINGDIFFUSE or layer.rgbgen.rgbgen == Q3RGBGEN_VERTEX then
						shader.lighting = true
					end
					if layer.alphagen.alphagen == Q3ALPHAGEN_VERTEX then
						if layer == shader.layers[1] then
							-- vertex controlled transparency
							shader.vertexalpha = true
						else
							-- multilayer terrain shader or similar
							shader.textureblendalpha = true
							if force_terrain_alphaflag then
								shader.layers[1].dptexflags = bit32.bor(shader.layers[1].dptexflags, TEXF_ALPHA)
							end
						end
					end

					if force_addalpha then
						-- for a long while, DP treated GL_ONE GL_ONE as GL_SRC_ALPHA GL_ONE
						-- this cvar brings back this behaviour
						if layer.blendfunc[1] == GL_ONE and layer.blendfunc[2] == GL_ONE then
							layer.blendfunc[1] = GL_SRC_ALPHA
						end
					end

					layer.dptexflags = 0
					if layer.alphatest then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_ALPHA)
					end
					if layer.blendfunc[1] == GL_SRC_ALPHA or layer.blendfunc[1] == GL_ONE_MINUS_SRC_ALPHA then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_ALPHA)
					end
					if layer.blendfunc[2] == GL_SRC_ALPHA or layer.blendfunc[2] == GL_ONE_MINUS_SRC_ALPHA then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_ALPHA)
					end
					if bit32.band(shader.surfaceparms, Q3SURFACEPARM_NOMIPMAPS) == 0 then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_MIPMAP)
					end
					if bit32.band(shader.textureflags, Q3TEXTUREFLAG_NOPICMIP) == 0 then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_PICMIP + TEXF_COMPRESS)
					end
					if layer.clampmap then
						layer.dptexflags = bit32.bor(layer.dptexflags, TEXF_CLAMP)
					end
					continue
				end
				readparameters()
				if fileindex == 0 and common.com_token == "}" then
					break
				end
				if developer_insane then
					Con_DPrintf("%s: ", shader.name)
					for j = 0, numparameters - 1 do
						Con_DPrintf(" %s", P(j))
					end
					Con_DPrint("\n")
				end
				if numparameters < 1 then
					continue
				end
				local p0 = PL(0)
				-- (the two dpshaderkill conditions assign the local even when their branch is not taken, as in C)
				local iskillzero = p0 == "dpshaderkillifcvarzero"
				local iskill = p0 == "dpshaderkillifcvar"
				if p0 == "surfaceparm" and numparameters >= 2 then
					local p1 = PL(1)
					local parm = SURFACEPARMS[p1]
					if parm then
						shader.surfaceparms = bit32.bor(shader.surfaceparms, parm)
					elseif p1 ~= "skip" then
						-- ("skip": shader.surfaceparms |= Q3SURFACEPARM_SKIP; FIXME we don't have enough #defines for
						-- this any more, and the engine doesn't need this one anyway)
						-- try custom surfaceparms
						local found = false
						for j = 1, numcustsurfaceflags do
							if lower(custsurfaceparmnames[j]) == p1 then
								shader.surfaceflags = bit32.bor(shader.surfaceflags, custsurfaceflags[j] % 4294967296)
								found = true
								break
							end
						end
						-- failed all
						if not found then
							Con_DPrintf('%s parsing warning: unknown surfaceparm "%s"\n', filename, P(1))
						end
					end
				elseif p0 == "dpshadow" then
					shader.dpshadow = true
				elseif p0 == "dpnoshadow" then
					shader.dpnoshadow = true
				elseif p0 == "dpnortlight" then
					shader.dpnortlight = true
				elseif p0 == "dpreflectcube" then
					shader.dpreflectcube = P(1)
				elseif p0 == "dpmeshcollisions" then
					shader.dpmeshcollisions = true
				-- this sets dpshaderkill to true if dpshaderkillifcvarzero was used, and to false if dpnoshaderkillifcvarzero was used
				elseif (iskillzero or p0 == "dpnoshaderkillifcvarzero") and numparameters >= 2 then
					dpshaderkill = iskillzero
					if cvar.Cvar_VariableValue(P(1)) == 0 then
						shader.dpshaderkill = dpshaderkill
					end
				-- this sets dpshaderkill to true if dpshaderkillifcvar was used, and to false if dpnoshaderkillifcvar was used
				elseif (iskill or p0 == "dpnoshaderkillifcvar") and numparameters >= 2 then
					dpshaderkill = iskill
					local op: string? = nil
					if numparameters >= 3 then
						op = P(2)
					end
					local value = cvar.Cvar_VariableValue(P(1))
					if not op then
						if value ~= 0 then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == "==" then
						if value == atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == "!=" then
						if value ~= atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == ">" then
						if value > atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == "<" then
						if value < atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == ">=" then
						if value >= atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					elseif numparameters >= 4 and op == "<=" then
						if value <= atof(3) then
							shader.dpshaderkill = dpshaderkill
						end
					else
						Con_DPrintf(
							'%s parsing warning: unknown dpshaderkillifcvar op "%s", or not enough arguments\n',
							filename,
							op
						)
					end
				elseif p0 == "sky" and numparameters >= 2 then
					-- some q3 skies don't have the sky parm set
					shader.surfaceparms = bit32.bor(shader.surfaceparms, Q3SURFACEPARM_SKY)
					shader.skyboxname = P(1)
				elseif p0 == "skyparms" and numparameters >= 2 then
					-- some q3 skies don't have the sky parm set
					shader.surfaceparms = bit32.bor(shader.surfaceparms, Q3SURFACEPARM_SKY)
					if libc.atoi(P(1)) == 0 and PL(1) ~= "-" then
						shader.skyboxname = P(1)
					end
				elseif p0 == "cull" and numparameters >= 2 then
					local p1 = PL(1)
					if p1 == "disable" or p1 == "none" or p1 == "twosided" then
						shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_TWOSIDED)
					end
				elseif p0 == "nomipmaps" then
					shader.surfaceparms = bit32.bor(shader.surfaceparms, Q3SURFACEPARM_NOMIPMAPS)
				elseif p0 == "nopicmip" then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_NOPICMIP)
				elseif p0 == "polygonoffset" then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_POLYGONOFFSET)
				elseif p0 == "dppolygonoffset" then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_POLYGONOFFSET)
					if numparameters >= 2 then
						shader.biaspolygonfactor = R(atof(1))
						if numparameters >= 3 then
							shader.biaspolygonoffset = R(atof(2))
						else
							shader.biaspolygonoffset = 0
						end
					end
				elseif p0 == "dptransparentsort" and numparameters >= 2 then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_TRANSPARENTSORT)
					local p1 = PL(1)
					if p1 == "sky" then
						shader.transparentsort = TRANSPARENTSORT_SKY
					elseif p1 == "distance" then
						shader.transparentsort = TRANSPARENTSORT_DISTANCE
					elseif p1 == "hud" then
						shader.transparentsort = TRANSPARENTSORT_HUD
					else
						Con_DPrintf(
							'%s parsing warning: unknown dptransparentsort category "%s", or not enough arguments\n',
							filename,
							P(1)
						)
					end
				elseif p0 == "dprefract" and numparameters >= 5 then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_REFRACTION)
					shader.refractfactor = R(atof(1))
					shader.refractcolor4f = { R(atof(2)), R(atof(3)), R(atof(4)), 1 }
				elseif p0 == "dpreflect" and numparameters >= 6 then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_REFLECTION)
					shader.reflectfactor = R(atof(1))
					shader.reflectcolor4f = { R(atof(2)), R(atof(3)), R(atof(4)), R(atof(5)) }
				elseif p0 == "dpcamera" then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_CAMERA)
				elseif p0 == "dpwater" and numparameters >= 12 then
					shader.textureflags = bit32.bor(shader.textureflags, Q3TEXTUREFLAG_WATERSHADER)
					shader.reflectmin = R(atof(1))
					shader.reflectmax = R(atof(2))
					shader.refractfactor = R(atof(3))
					shader.reflectfactor = R(atof(4))
					shader.refractcolor4f = { R(atof(5)), R(atof(6)), R(atof(7)), 1 }
					shader.reflectcolor4f = { R(atof(8)), R(atof(9)), R(atof(10)), 1 }
					shader.r_water_wateralpha = R(atof(11))
				elseif p0 == "dpwaterscroll" and numparameters >= 3 then
					shader.r_water_waterscroll[1] = R(1 / atof(1))
					shader.r_water_waterscroll[2] = R(1 / atof(2))
				elseif p0 == "dpglossintensitymod" and numparameters >= 2 then
					shader.specularscalemod = R(atof(1))
				elseif p0 == "dpglossexponentmod" and numparameters >= 2 then
					shader.specularpowermod = R(atof(1))
				elseif p0 == "dprtlightambient" and numparameters >= 2 then
					shader.rtlightambient = R(atof(1))
				elseif p0 == "dpoffsetmapping" and numparameters >= 2 then
					local p1 = PL(1)
					if p1 == "disable" or p1 == "none" or p1 == "off" then
						shader.offsetmapping = OFFSETMAPPING_OFF
					elseif p1 == "default" or p1 == "normal" then
						shader.offsetmapping = OFFSETMAPPING_DEFAULT
					elseif p1 == "linear" then
						shader.offsetmapping = OFFSETMAPPING_LINEAR
					elseif p1 == "relief" then
						shader.offsetmapping = OFFSETMAPPING_RELIEF
					end
					if numparameters >= 3 then
						shader.offsetscale = R(atof(2))
					end
					if numparameters >= 5 then
						local p3 = PL(3)
						if p3 == "bias" then
							shader.offsetbias = R(atof(4))
						elseif p3 == "match" then
							shader.offsetbias = R(1.0 - atof(4))
						elseif p3 == "match8" then
							shader.offsetbias = R(1.0 - atof(4) / 255.0)
						elseif p3 == "match16" then
							shader.offsetbias = R(1.0 - atof(4) / 65535.0)
						end
					end
				elseif p0 == "deformvertexes" and numparameters >= 2 then
					local deformindex = 0
					while deformindex < Q3MAXDEFORMS do
						local d = shader.deforms[deformindex + 1]
						if not d or d.deform == 0 then
							break
						end
						deformindex += 1
					end
					if deformindex < Q3MAXDEFORMS then
						local d = shader.deforms[deformindex + 1]
						if not d then
							d = { deform = 0, parms = { 0, 0, 0 }, wavefunc = 0, waveparms = { 0, 0, 0, 0 } }
							shader.deforms[deformindex + 1] = d
						end
						local i = 0
						while i < numparameters - 2 and i < Q3DEFORM_MAXPARMS do
							d.parms[i + 1] = R(atof(i + 2))
							i += 1
						end
						local p1 = PL(1)
						local mode = DEFORMS[p1]
						if mode then
							d.deform = mode
						elseif p1 == "wave" then
							d.deform = 13 -- Q3DEFORM_WAVE
							d.wavefunc = Mod_LoadQ3Shaders_EnumerateWaveFunc(P(3))
							i = 0
							while i < numparameters - 4 and i < Q3WAVEPARMS do
								d.waveparms[i + 1] = R(atof(i + 4))
								i += 1
							end
						elseif p1 == "move" then
							d.deform = 15 -- Q3DEFORM_MOVE
							d.wavefunc = Mod_LoadQ3Shaders_EnumerateWaveFunc(P(5))
							i = 0
							while i < numparameters - 6 and i < Q3WAVEPARMS do
								d.waveparms[i + 1] = R(atof(i + 6))
								i += 1
							end
						end
					end
				end
			end
			-- hide this shader if a cvar said it should be killed
			if shader.dpshaderkill then
				shader.numlayers = 0
			end
			-- fix up multiple reflection types
			if bit32.band(shader.textureflags, Q3TEXTUREFLAG_WATERSHADER) ~= 0 then
				shader.textureflags = bit32.band(
					shader.textureflags,
					bit32.bnot(Q3TEXTUREFLAG_REFRACTION + Q3TEXTUREFLAG_REFLECTION + Q3TEXTUREFLAG_CAMERA)
				)
			end

			Q3Shader_AddToHash(shader)
		end
	end
end

-- port: model_shared.c Mod_LookupQ3Shader L2398-2413 @xonotic-v0.8.6
function model_shared.Mod_LookupQ3Shader(name: string): q3shaderinfo_t?
	if not q3shaders_loaded then
		model_shared.Mod_LoadQ3Shaders()
	end
	local hash = common.CRC_Block_CaseInsensitive(name)
	local entry: any = hashhead(hash % Q3SHADER_HASH_SIZE)
	local lname = lower(name)
	while entry ~= nil do
		if lower(entry.shader.name) == lname then
			return entry.shader
		end
		entry = entry.chain
	end
	return nil
end

-- Port support (tests, tools): every shader in the hash, in bucket then chain order. A head entry with an empty
-- name is unused (Q3Shader_AddToHash never stores "" there); a chained entry is always a shader, also one named
-- "" (it is chained when its bucket head is taken).
function model_shared.q3shaders(): { q3shaderinfo_t }
	local out = {}
	for i = 0, Q3SHADER_HASH_SIZE - 1 do
		local entry = q3shader_data.hash[i]
		if entry and entry.shader.name ~= "" then
			table.insert(out, entry.shader)
		end
		entry = if entry then entry.chain else nil
		while entry do
			table.insert(out, entry.shader)
			entry = entry.chain
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------------------
-- Textures from Q3 shaders (model_shared.c L2415-2838)

-- model_brush.h MATERIALFLAG_* L73-131
model_shared.MATERIALFLAG_MESHCOLLISIONS = 0x00000001
model_shared.MATERIALFLAG_ALPHA = 0x00000002
model_shared.MATERIALFLAG_ADD = 0x00000004
model_shared.MATERIALFLAG_NODEPTHTEST = 0x00000008
model_shared.MATERIALFLAG_WATERALPHA = 0x00000010
model_shared.MATERIALFLAG_FULLBRIGHT = 0x00000020
model_shared.MATERIALFLAG_WALL = 0x00000040
model_shared.MATERIALFLAG_SKY = 0x00000080
model_shared.MATERIALFLAG_WATERSCROLL = 0x00000100
model_shared.MATERIALFLAG_NODRAW = 0x00000200
model_shared.MATERIALFLAG_LIGHTBOTHSIDES = 0x00000400
model_shared.MATERIALFLAG_ALPHATEST = 0x00000800
model_shared.MATERIALFLAG_BLENDED = 0x00001000
model_shared.MATERIALFLAG_CUSTOMBLEND = 0x00002000
model_shared.MATERIALFLAG_NOSHADOW = 0x00004000
model_shared.MATERIALFLAG_VERTEXTEXTUREBLEND = 0x00008000
model_shared.MATERIALFLAG_NOCULLFACE = 0x00010000
model_shared.MATERIALFLAG_SHORTDEPTHRANGE = 0x00020000
model_shared.MATERIALFLAG_WATERSHADER = 0x00040000
model_shared.MATERIALFLAG_REFRACTION = 0x00080000
model_shared.MATERIALFLAG_REFLECTION = 0x00100000
model_shared.MATERIALFLAG_MODELLIGHT = 0x00200000
model_shared.MATERIALFLAG_CUSTOMSURFACE = 0x00800000
model_shared.MATERIALFLAG_TRANSDEPTH = 0x01000000
model_shared.MATERIALFLAG_CAMERA = 0x02000000
model_shared.MATERIALFLAG_NORTLIGHT = 0x04000000
model_shared.MATERIALFLAG_ALPHAGEN_VERTEX = 0x08000000
model_shared.MATERIALFLAG_OCCLUDE = 0x10000000
local MATERIALFLAG_MESHCOLLISIONS = 0x00000001
local MATERIALFLAG_ALPHA = 0x00000002
local MATERIALFLAG_ADD = 0x00000004
local MATERIALFLAG_FULLBRIGHT = 0x00000020
local MATERIALFLAG_WALL = 0x00000040
local MATERIALFLAG_SKY = 0x00000080
local MATERIALFLAG_NODRAW = 0x00000200
local MATERIALFLAG_ALPHATEST = 0x00000800
local MATERIALFLAG_BLENDED = 0x00001000
local MATERIALFLAG_CUSTOMBLEND = 0x00002000
local MATERIALFLAG_NOSHADOW = 0x00004000
local MATERIALFLAG_NOCULLFACE = 0x00010000
local MATERIALFLAG_WATERSHADER = 0x00040000
local MATERIALFLAG_REFRACTION = 0x00080000
local MATERIALFLAG_REFLECTION = 0x00100000
local MATERIALFLAG_CAMERA = 0x02000000
local MATERIALFLAG_NORTLIGHT = 0x04000000
local MATERIALFLAG_ALPHAGEN_VERTEX = 0x08000000

-- bspfile.h Q3SURFACEFLAG_* L298-318 and SUPERCONTENTS_* L232-247 (the ones used here)
local Q3SURFACEFLAG_NODAMAGE = 1
local Q3SURFACEFLAG_SLICK = 2
local Q3SURFACEFLAG_SKY = 4
local Q3SURFACEFLAG_NOIMPACT = 16
local Q3SURFACEFLAG_NOMARKS = 32
local Q3SURFACEFLAG_NODRAW = 128
local Q3SURFACEFLAG_HINT = 256
local Q3SURFACEFLAG_NOLIGHTMAP = 1024
local Q3SURFACEFLAG_POINTLIGHT = 2048
local Q3SURFACEFLAG_METALSTEPS = 4096
local Q3SURFACEFLAG_NONSOLID = 16384
local Q3SURFACEFLAG_LIGHTFILTER = 32768
local Q3SURFACEFLAG_ALPHASHADOW = 65536
local Q3SURFACEFLAG_NODLIGHT = 131072
local Q3SURFACEFLAG_DUST = 262144
local SUPERCONTENTS_SOLID = 0x00000001
local SUPERCONTENTS_WATER = 0x00000002
local SUPERCONTENTS_SLIME = 0x00000004
local SUPERCONTENTS_LAVA = 0x00000008
local SUPERCONTENTS_SKY = 0x00000010
local SUPERCONTENTS_NODROP = 0x00000080
local SUPERCONTENTS_PLAYERCLIP = 0x00000100
local SUPERCONTENTS_MONSTERCLIP = 0x00000200
local SUPERCONTENTS_DONOTENTER = 0x00000400
local SUPERCONTENTS_BOTCLIP = 0x00000800
local SUPERCONTENTS_OPAQUE = 0x00001000
local TEXF_ISWORLD = 0x00004000
local TEXF_ISSPRITE = 0x00008000

-- Renderer functions this file calls (gl_rmain.c; the renderer is not ported yet). On a dedicated server
-- R_SkinFrame_LoadMissing returns NULL and R_SkinFrame_LoadExternal is not called; a client backend replaces
-- these.
local renderer_notported: { [string]: boolean } = {}
local function renderer_missing(what: string)
	if not renderer_notported[what] then
		renderer_notported[what] = true
		print("NOT YET PORTED: " .. what .. " (gl_rmain.c)")
	end
end
model_shared.R_SkinFrame_LoadMissing = function(): any
	if cvar.cls_state_dedicated then
		return nil
	end
	renderer_missing("R_SkinFrame_LoadMissing")
	return nil
end
model_shared.R_SkinFrame_LoadExternal = function(_name: string, _textureflags: number, _complain: boolean): any
	renderer_missing("R_SkinFrame_LoadExternal")
	return nil
end
model_shared.R_GetCubemap = function(_basename: string): any
	renderer_missing("R_GetCubemap")
	return nil
end
-- model_brush.c Mod_Q2BSP_SuperContentsFromNativeContents, set by model_brush when the Q2 loader is ported
model_shared.Mod_Q2BSP_SuperContentsFromNativeContents = nil :: ((number) -> number)?

-- a copy of a wave / gen struct ({ kind, parms, wavefunc?, waveparms? }), as a C struct assignment copies it
local function copygen(g: any): any
	local c = table.clone(g)
	c.parms = table.clone(g.parms)
	if g.waveparms then
		c.waveparms = table.clone(g.waveparms)
	end
	return c
end

-- texture_shaderpass_t (model_shared.h L511-544) as a table: skinframes[1 .. numframes] (nil = NULL), tcmods as in
-- q3shaderinfo_layer_t (only the used entries)
-- port: model_shared.c Mod_CreateShaderPass L2415-2428 @xonotic-v0.8.6
function model_shared.Mod_CreateShaderPass(skinframe: any): any
	return {
		alphatest = false,
		framerate = 0.0,
		numframes = 1,
		skinframes = { skinframe },
		blendfunc = { GL_ONE, GL_ZERO },
		rgbgen = { rgbgen = Q3RGBGEN_IDENTITY, parms = { 0, 0, 0 }, wavefunc = 0, waveparms = { 0, 0, 0, 0 } },
		alphagen = { alphagen = Q3ALPHAGEN_IDENTITY, parms = { 0 }, wavefunc = 0, waveparms = { 0, 0, 0, 0 } },
		tcgen = { tcgen = Q3TCGEN_TEXTURE, parms = { 0, 0, 0, 0, 0, 0 } },
		tcmods = {},
	}
end

-- port: model_shared.c Mod_CreateShaderPassFromQ3ShaderLayer L2430-2457 @xonotic-v0.8.6
function model_shared.Mod_CreateShaderPassFromQ3ShaderLayer(
	layer: q3shaderinfo_layer_t,
	layerindex: number,
	texflags: number,
	texturename: string
): any
	local shaderpass = {
		alphatest = layer.alphatest,
		framerate = layer.framerate,
		numframes = layer.numframes,
		skinframes = {} :: { any },
		blendfunc = { layer.blendfunc[1], layer.blendfunc[2] },
		rgbgen = copygen(layer.rgbgen),
		alphagen = copygen(layer.alphagen),
		tcgen = copygen(layer.tcgen),
		tcmods = {} :: { any },
	}
	for j = 1, Q3MAXTCMODS do
		local m = layer.tcmods[j]
		if not m or m.tcmod == 0 then
			break
		end
		shaderpass.tcmods[j] = copygen(m)
	end
	for j = 0, layer.numframes - 1 do
		if cvar.cls_state_dedicated then
			shaderpass.skinframes[j + 1] = nil
		else
			local frame = model_shared.R_SkinFrame_LoadExternal(layer.texturename[j + 1], texflags, false)
			if not frame then
				Con_Printf(
					'^1%s:^7 could not load texture ^3"%s"^7 (frame %i) for layer %i of shader ^2"%s"\n',
					model_shared.loadmodel.name,
					layer.texturename[j + 1],
					j,
					layerindex,
					texturename
				)
				frame = model_shared.R_SkinFrame_LoadMissing()
			end
			shaderpass.skinframes[j + 1] = frame
		end
	end
	return shaderpass
end

-- port: model_shared.c Mod_LoadTextureFromQ3Shader L2459-2838 @xonotic-v0.8.6
-- texture: a texture_t table; fields the C code reads before writing them are taken as 0 / NULL when missing
-- (C: the caller's zeroed struct). shaderpasses[1 ..] hold C shaderpasses[0 ..]; the start/end pass indexes keep
-- their C (0-based) values.
function model_shared.Mod_LoadTextureFromQ3Shader(
	texture: any,
	name: string?,
	warnmissing: boolean,
	fallback: boolean,
	defaulttexflags: number
): boolean
	local loadmodel = model_shared.loadmodel
	local success = true
	local shadername = name or ""
	texture.name = string.sub(shadername, 1, 63)
	texture.basealpha = 1.0
	texture.basematerialflags = texture.basematerialflags or 0
	texture.surfaceflags = texture.surfaceflags or 0
	texture.supercontents = texture.supercontents or 0
	texture.biaspolygonoffset = texture.biaspolygonoffset or 0
	texture.biaspolygonfactor = texture.biaspolygonfactor or 0
	texture.shaderpasses = texture.shaderpasses or {}
	texture.startpreshaderpass = texture.startpreshaderpass or 0
	texture.endpreshaderpass = texture.endpreshaderpass or 0
	texture.startpostshaderpass = texture.startpostshaderpass or 0
	texture.endpostshaderpass = texture.endpostshaderpass or 0
	local shader: q3shaderinfo_t? = if shadername ~= "" then model_shared.Mod_LookupQ3Shader(shadername) else nil

	-- allow disabling of picmip or compression by defaulttexflags
	local texflagsmask = 0xFFFFFFFF
	if bit32.band(defaulttexflags, TEXF_PICMIP) == 0 then
		texflagsmask = bit32.band(texflagsmask, bit32.bnot(TEXF_PICMIP))
	end
	if bit32.band(defaulttexflags, TEXF_COMPRESS) == 0 then
		texflagsmask = bit32.band(texflagsmask, bit32.bnot(TEXF_COMPRESS))
	end
	local texflagsor = 0
	if bit32.band(defaulttexflags, TEXF_ISWORLD) ~= 0 then
		texflagsor = bit32.bor(texflagsor, TEXF_ISWORLD)
	end
	if bit32.band(defaulttexflags, TEXF_ISSPRITE) ~= 0 then
		texflagsor = bit32.bor(texflagsor, TEXF_ISSPRITE)
	end
	-- unless later loaded from the shader
	texture.offsetmapping = if cvarvalue("mod_noshader_default_offsetmapping", 1) ~= 0
		then OFFSETMAPPING_DEFAULT
		else OFFSETMAPPING_OFF
	texture.offsetscale = 1
	texture.offsetbias = 0
	texture.specularscalemod = 1
	texture.specularpowermod = 1
	texture.rtlightambient = 0
	texture.transparentsort = TRANSPARENTSORT_DISTANCE
	-- WHEN ADDING DEFAULTS HERE, REMEMBER TO PUT DEFAULTS IN ALL LOADERS
	-- JUST GREP FOR "specularscalemod = 1".

	local developer_extra = cvarvalue("developer_extra", 0) ~= 0
	if shader then
		if cvarvalue("developer_loading", 0) ~= 0 then
			Con_Printf("%s: loaded shader for %s\n", loadmodel.name, shadername)
		end

		if bit32.band(shader.surfaceparms, Q3SURFACEPARM_SKY) ~= 0 then
			texture.basematerialflags = MATERIALFLAG_SKY
			if shader.skyboxname ~= "" then
				-- quake3 seems to append a _ to the skybox name, so this must do so as well
				loadmodel.brush.skybox = string.sub(shader.skyboxname .. "_", 1, 127)
			end
		elseif bit32.band(texture.surfaceflags, Q3SURFACEFLAG_NODRAW) ~= 0 or shader.numlayers == 0 then
			texture.basematerialflags = MATERIALFLAG_NODRAW + MATERIALFLAG_NOSHADOW
		else
			texture.basematerialflags = MATERIALFLAG_WALL
		end

		-- (C reads layers[0] whatever numlayers is: a killed shader keeps its parsed layers)
		local layer0 = shader.layers[1]
		if layer0 and layer0.alphatest then
			texture.basematerialflags =
				bit32.bor(texture.basematerialflags, MATERIALFLAG_ALPHATEST + MATERIALFLAG_NOSHADOW)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_TWOSIDED) ~= 0 then
			texture.basematerialflags =
				bit32.bor(texture.basematerialflags, MATERIALFLAG_NOSHADOW + MATERIALFLAG_NOCULLFACE)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_POLYGONOFFSET) ~= 0 then
			texture.biaspolygonoffset = R(texture.biaspolygonoffset + shader.biaspolygonoffset)
			texture.biaspolygonfactor = R(texture.biaspolygonfactor + shader.biaspolygonfactor)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_REFRACTION) ~= 0 then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_REFRACTION)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_REFLECTION) ~= 0 then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_REFLECTION)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_WATERSHADER) ~= 0 then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_WATERSHADER)
		end
		if bit32.band(shader.textureflags, Q3TEXTUREFLAG_CAMERA) ~= 0 then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_CAMERA)
		end
		texture.customblendfunc = { GL_ONE, GL_ZERO }
		texture.transparentsort = shader.transparentsort
		if shader.numlayers > 0 then
			local b0, b1 = shader.layers[1].blendfunc[1], shader.layers[1].blendfunc[2]
			texture.customblendfunc[1] = b0
			texture.customblendfunc[2] = b1
			-- (the table of Q3 shader blendfuncs used in the game is in the C source, L2535-2554)
			-- if not opaque, figure out what blendfunc to use
			if b0 ~= GL_ONE or b1 ~= GL_ZERO then
				-- (GL_ONE GL_ONE and GL_SRC_ALPHA GL_ONE: two branches with the same body in C)
				if (b0 == GL_ONE and b1 == GL_ONE) or (b0 == GL_SRC_ALPHA and b1 == GL_ONE) then
					texture.basematerialflags = bit32.bor(
						texture.basematerialflags,
						MATERIALFLAG_ADD + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW
					)
				elseif b0 == GL_SRC_ALPHA and b1 == GL_ONE_MINUS_SRC_ALPHA then
					texture.basematerialflags = bit32.bor(
						texture.basematerialflags,
						MATERIALFLAG_ALPHA + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW
					)
				else
					texture.basematerialflags = bit32.bor(
						texture.basematerialflags,
						MATERIALFLAG_CUSTOMBLEND
							+ MATERIALFLAG_FULLBRIGHT
							+ MATERIALFLAG_BLENDED
							+ MATERIALFLAG_NOSHADOW
					)
				end
			end
		end
		if not shader.lighting then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_FULLBRIGHT)
		end

		-- here be dragons: convert quake3 shaders to material
		if shader.numlayers > 0 then
			local layers = shader.layers -- C layers[i] is layers[i + 1]
			local terrainbackgroundlayer = -1
			local lightmaplayer = -1
			local alphagenspecularlayer = -1
			local rgbgenvertexlayer = -1
			local rgbgendiffuselayer = -1
			local materiallayer = -1
			local endofprelayers = 0
			local firstpostlayer = 0
			local shaderpassindex = 0
			for i = 0, shader.numlayers - 1 do
				local l = layers[i + 1]
				if l.texturename ~= nil and lower(l.texturename[1]) == "$lightmap" then
					lightmaplayer = i
				end
				if l.rgbgen.rgbgen == Q3RGBGEN_VERTEX then
					rgbgenvertexlayer = i
				end
				if l.rgbgen.rgbgen == Q3RGBGEN_LIGHTINGDIFFUSE then
					rgbgendiffuselayer = i
				end
				if l.alphagen.alphagen == 3 then -- Q3ALPHAGEN_LIGHTINGSPECULAR
					alphagenspecularlayer = i
				end
			end
			local l0, l1 = layers[1], layers[2]
			if
				shader.numlayers >= 2
				and l1.alphagen.alphagen == Q3ALPHAGEN_VERTEX
				and (l0.blendfunc[1] == GL_ONE and l0.blendfunc[2] == GL_ZERO and not l0.alphatest)
				and (
					(l1.blendfunc[1] == GL_SRC_ALPHA and l1.blendfunc[2] == GL_ONE_MINUS_SRC_ALPHA)
					or (l1.blendfunc[1] == GL_ONE and l1.blendfunc[2] == GL_ZERO and l1.alphatest)
				)
			then
				-- terrain blend or certain other effects involving alphatest over a regular layer
				terrainbackgroundlayer = 0
				materiallayer = 1
				-- terrain may be vertex lit (in which case both layers are rgbGen vertex) or lightmapped (in which ase the third layer is lightmap)
				firstpostlayer = if lightmaplayer >= 0 then lightmaplayer + 1 else materiallayer + 1
			elseif lightmaplayer == 0 then
				-- ordinary texture but with $lightmap before diffuse
				materiallayer = 1
				firstpostlayer = lightmaplayer + 2
			elseif lightmaplayer >= 1 then
				-- ordinary texture - we don't properly apply lighting to the prelayers, but oh well...
				endofprelayers = lightmaplayer - 1
				materiallayer = lightmaplayer - 1
				firstpostlayer = lightmaplayer + 1
			elseif rgbgenvertexlayer >= 0 then
				-- map models with baked lighting
				materiallayer = rgbgenvertexlayer
				endofprelayers = rgbgenvertexlayer
				firstpostlayer = rgbgenvertexlayer + 1
			elseif rgbgendiffuselayer >= 0 then
				-- entity models with dynamic lighting
				materiallayer = rgbgendiffuselayer
				endofprelayers = rgbgendiffuselayer
				firstpostlayer = rgbgendiffuselayer + 1
				-- player models often have specular as a pass after diffuse - we don't currently make use of that specular texture (would need to meld it into the skinframe)...
				if alphagenspecularlayer >= 0 then
					firstpostlayer = alphagenspecularlayer + 1
				end
			else
				-- special effects shaders - treat first as primary layer and do everything else as post
				endofprelayers = 0
				materiallayer = 0
				firstpostlayer = 1
			end
			-- (C indexes shader->layers[] with these numbers without checking them against numlayers: a layer
			-- past the parsed ones is a zeroed layer of the struct)
			local function pass(i: number): any
				local l = layers[i + 1] or newlayer()
				return model_shared.Mod_CreateShaderPassFromQ3ShaderLayer(
					l,
					i,
					bit32.bor(bit32.band(l.dptexflags, texflagsmask), texflagsor),
					texture.name
				)
			end
			-- texture->shaderpasses[shaderpassindex++] = p. C does not check the index against the
			-- Q3SHADER_MAXLAYERS entries of shaderpasses[] (pre and post layers can overlap: a shader with
			-- rgbgen lightingdiffuse after alphagen lightingspecular converts some layers twice), and indexes 8
			-- and 9 land on the next fields of texture_t, materialshaderpass and backgroundshaderpass
			-- (model_shared.h L595-597; checked against the C build, tests/unit/q3shaders_ref.test.luau). Index 10
			-- and up would overwrite the pass range bytes and colormapping with a pointer value: not reproducible.
			local function storepass(p: any)
				if shaderpassindex < Q3SHADER_MAXLAYERS then
					texture.shaderpasses[shaderpassindex + 1] = p
				elseif shaderpassindex == Q3SHADER_MAXLAYERS then
					texture.materialshaderpass = p
				elseif shaderpassindex == Q3SHADER_MAXLAYERS + 1 then
					texture.backgroundshaderpass = p
				else
					print(
						"NOT YET PORTED: shader pass "
							.. shaderpassindex
							.. " of "
							.. texture.name
							.. " (C writes it past texture_t.backgroundshaderpass)"
					)
				end
				shaderpassindex += 1
			end
			-- convert the main material layer
			-- FIXME: if alphagenspecularlayer is used, we should pass a specular texture name to R_SkinFrame_LoadExternal and have it load that texture instead of the assumed name for _gloss texture
			if materiallayer >= 0 then
				local p = pass(materiallayer)
				texture.materialshaderpass = p
				storepass(p)
			end
			-- convert the terrain background blend layer (if any)
			if terrainbackgroundlayer >= 0 then
				local p = pass(terrainbackgroundlayer)
				texture.backgroundshaderpass = p
				storepass(p)
			end
			-- convert the prepass layers (if any)
			texture.startpreshaderpass = shaderpassindex
			for i = 0, endofprelayers - 1 do
				storepass(pass(i))
			end
			texture.endpreshaderpass = shaderpassindex
			texture.startpostshaderpass = shaderpassindex
			-- convert the postpass layers (if any)
			for i = firstpostlayer, shader.numlayers - 1 do
				storepass(pass(i))
			end
			-- (as in C: startpostshaderpass is assigned again here, endpostshaderpass never)
			texture.startpostshaderpass = shaderpassindex
		end

		if shader.dpshadow then
			texture.basematerialflags = bit32.band(texture.basematerialflags, bit32.bnot(MATERIALFLAG_NOSHADOW))
		end
		if shader.dpnoshadow then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_NOSHADOW)
		end
		if shader.dpnortlight then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_NORTLIGHT)
		end
		if shader.vertexalpha then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_ALPHAGEN_VERTEX)
		end
		-- memcpy(texture->deforms, shader->deforms, sizeof(texture->deforms));
		texture.deforms = {}
		for i, d in shader.deforms do
			texture.deforms[i] = copygen(d)
		end
		texture.reflectmin = shader.reflectmin
		texture.reflectmax = shader.reflectmax
		texture.refractfactor = shader.refractfactor
		texture.refractcolor4f = table.clone(shader.refractcolor4f)
		texture.reflectfactor = shader.reflectfactor
		texture.reflectcolor4f = table.clone(shader.reflectcolor4f)
		texture.r_water_wateralpha = shader.r_water_wateralpha
		texture.r_water_waterscroll = table.clone(shader.r_water_waterscroll)
		texture.offsetmapping = shader.offsetmapping
		texture.offsetscale = shader.offsetscale
		texture.offsetbias = shader.offsetbias
		texture.specularscalemod = shader.specularscalemod
		texture.specularpowermod = shader.specularpowermod
		texture.rtlightambient = shader.rtlightambient
		if shader.dpreflectcube ~= "" then
			texture.reflectcubetexture = model_shared.R_GetCubemap(shader.dpreflectcube)
		end

		-- set up default supercontents (on q3bsp this is overridden by the q3bsp loader)
		local sp = shader.surfaceparms
		local function has(parm: number): boolean
			return bit32.band(sp, parm) ~= 0
		end
		local sc = SUPERCONTENTS_SOLID + SUPERCONTENTS_OPAQUE
		if has(SURFACEPARMS.lava) then
			sc = SUPERCONTENTS_LAVA
		end
		if has(SURFACEPARMS.slime) then
			sc = SUPERCONTENTS_SLIME
		end
		if has(SURFACEPARMS.water) then
			sc = SUPERCONTENTS_WATER
		end
		if has(SURFACEPARMS.nonsolid) then
			sc = 0
		end
		if has(SURFACEPARMS.playerclip) then
			sc = SUPERCONTENTS_PLAYERCLIP
		end
		if has(SURFACEPARMS.botclip) then
			sc = SUPERCONTENTS_MONSTERCLIP
		end
		if has(SURFACEPARMS.sky) then
			sc = SUPERCONTENTS_SKY
		end

		if has(SURFACEPARMS.donotenter) then
			sc = bit32.bor(sc, SUPERCONTENTS_DONOTENTER)
		end
		if has(SURFACEPARMS.lava) then
			sc = bit32.bor(sc, SUPERCONTENTS_LAVA)
		end
		if has(SURFACEPARMS.nodrop) then
			sc = bit32.bor(sc, SUPERCONTENTS_NODROP)
		end
		if has(SURFACEPARMS.nonsolid) then
			sc = bit32.band(sc, bit32.bnot(SUPERCONTENTS_SOLID))
		end
		if has(SURFACEPARMS.playerclip) then
			sc = bit32.bor(sc, SUPERCONTENTS_PLAYERCLIP)
		end
		if has(SURFACEPARMS.sky) then
			sc = bit32.bor(sc, SUPERCONTENTS_SKY)
		end
		if has(SURFACEPARMS.slime) then
			sc = bit32.bor(sc, SUPERCONTENTS_SLIME)
		end
		if has(SURFACEPARMS.water) then
			sc = bit32.bor(sc, SUPERCONTENTS_WATER)
		end
		if has(SURFACEPARMS.botclip) then
			sc = bit32.bor(sc, SUPERCONTENTS_BOTCLIP + SUPERCONTENTS_MONSTERCLIP)
		end
		texture.supercontents = sc

		local sf = shader.surfaceflags
		if has(SURFACEPARMS.alphashadow) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_ALPHASHADOW)
		end
		if has(SURFACEPARMS.lightfilter) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_LIGHTFILTER)
		end
		if has(SURFACEPARMS.metalsteps) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_METALSTEPS)
		end
		if has(SURFACEPARMS.nodamage) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NODAMAGE)
		end
		if has(SURFACEPARMS.nodlight) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NODLIGHT)
		end
		if has(SURFACEPARMS.nodraw) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NODRAW)
		end
		if has(SURFACEPARMS.noimpact) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NOIMPACT)
		end
		if has(SURFACEPARMS.nolightmap) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NOLIGHTMAP)
		end
		if has(SURFACEPARMS.nomarks) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NOMARKS)
		end
		if has(SURFACEPARMS.nonsolid) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_NONSOLID)
		end
		if has(SURFACEPARMS.sky) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_SKY)
		end
		if has(SURFACEPARMS.slick) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_SLICK)
		end
		if has(SURFACEPARMS.pointlight) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_POINTLIGHT)
		end
		if has(SURFACEPARMS.hint) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_HINT)
		end
		if has(SURFACEPARMS.dust) then
			sf = bit32.bor(sf, Q3SURFACEFLAG_DUST)
		end
		texture.surfaceflags = sf

		if shader.dpmeshcollisions then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_MESHCOLLISIONS)
		end
		if shader.dpshaderkill and developer_extra then
			Con_DPrintf('^1%s:^7 killing shader ^3"%s" because of cvar\n', loadmodel.name, shadername)
		end
	elseif texture.name == "noshader" or texture.name == "" then
		if developer_extra then
			Con_DPrintf('^1%s:^7 using fallback noshader material for ^3"%s"\n', loadmodel.name, shadername)
		end
		texture.supercontents = SUPERCONTENTS_SOLID + SUPERCONTENTS_OPAQUE
	elseif texture.name == "common/nodraw" or texture.name == "textures/common/nodraw" then
		if developer_extra then
			Con_DPrintf('^1%s:^7 using fallback nodraw material for ^3"%s"\n', loadmodel.name, shadername)
		end
		texture.basematerialflags = MATERIALFLAG_NODRAW + MATERIALFLAG_NOSHADOW
		texture.supercontents = SUPERCONTENTS_SOLID
	else
		if developer_extra then
			Con_DPrintf('^1%s:^7 No shader found for texture ^3"%s"\n', loadmodel.name, texture.name)
		end
		if bit32.band(texture.surfaceflags, Q3SURFACEFLAG_NODRAW) ~= 0 then
			texture.basematerialflags =
				bit32.bor(texture.basematerialflags, MATERIALFLAG_NODRAW + MATERIALFLAG_NOSHADOW)
			texture.supercontents = SUPERCONTENTS_SOLID
		elseif bit32.band(texture.surfaceflags, Q3SURFACEFLAG_SKY) ~= 0 then
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_SKY)
			texture.supercontents = SUPERCONTENTS_SKY
		else
			texture.basematerialflags = bit32.bor(texture.basematerialflags, MATERIALFLAG_WALL)
			texture.supercontents = SUPERCONTENTS_SOLID + SUPERCONTENTS_OPAQUE
		end
		if cvar.cls_state_dedicated then
			texture.materialshaderpass = nil
			success = false
		else
			if fallback then
				texture.shaderpasses[1] = model_shared.Mod_CreateShaderPass(
					model_shared.R_SkinFrame_LoadExternal(texture.name, defaulttexflags, false)
				)
				texture.materialshaderpass = texture.shaderpasses[1]
				local frame = texture.materialshaderpass.skinframes[1]
				if frame then
					if frame.hasalpha then
						texture.basematerialflags = bit32.bor(
							texture.basematerialflags,
							MATERIALFLAG_ALPHA + MATERIALFLAG_BLENDED + MATERIALFLAG_NOSHADOW
						)
					end
					if (texture.q2contents or 0) ~= 0 and model_shared.Mod_Q2BSP_SuperContentsFromNativeContents then
						texture.supercontents =
							model_shared.Mod_Q2BSP_SuperContentsFromNativeContents(texture.q2contents)
					end
				else
					success = false
				end
			else
				success = false
			end
			if not success and warnmissing then
				Con_Printf('^1%s:^7 could not load texture ^3"%s"\n', loadmodel.name, texture.name)
			end
		end
	end
	-- init the animation variables
	texture.currentframe = texture
	if not texture.materialshaderpass then
		texture.shaderpasses[1] = model_shared.Mod_CreateShaderPass(model_shared.R_SkinFrame_LoadMissing())
		texture.materialshaderpass = texture.shaderpasses[1]
	end
	if not texture.materialshaderpass.skinframes[1] then
		texture.materialshaderpass.skinframes[1] = model_shared.R_SkinFrame_LoadMissing()
	end
	texture.currentskinframe = if texture.materialshaderpass then texture.materialshaderpass.skinframes[1] else nil
	texture.backgroundcurrentskinframe = if texture.backgroundshaderpass
		then texture.backgroundshaderpass.skinframes[1]
		else nil
	return success
end

return model_shared
