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

]]
-- sv_phys.c
--[[
	Port of sv_phys.c @xonotic-v0.8.6: line testing and entity linking (SV_GetPitchSign .. SV_LinkEdict,
	sv_phys.c L47-890; the COLLISIONPARANOID variants are not compiled in the release), then the movers and
	SV_Physics (L892-3232, see the block comment before SV_TestEntityPosition). SV_NudgeOutOfSolid comes
	before SV_NudgeOutOfSolid_PivotIsKnownGood here (it was ported first); everything else is in C order.

	Representation (as in engine/world.luau):
	  * an edict is its number; NULL is nil, prog->edicts (the world) is 0. trace.ent is an edict number or nil.
	  * SVVM_prog is cvar.prvm_prog_list[0] (PRVM_PROG_SERVER); sv is server.sv (engine/server.luau).
	  * PRVM_serveredict{float,vector,edict,function}(ed, f) read the 4-byte slot at
	    (ed * entityfields + FieldOfs(f)) * 4 of prog.edictsfields (f32, or i32 for edict / function / string);
	    PRVM_serverglobal*(g) the slot GlobalOfs(g) * 4 of prog.globals. PRVM_EDICT_TO_PROG(ed) is ed.
	  * C arrays (touchedicts) are 1-based tables with C element i at [i + 1]. The static touchedicts arrays are
	    one module-level table per C function, as in C (a nested call of the same function reuses it).
	vec_t / prvm_vec_t are float (qtypes.h, PRVM_64 and VEC_64 off): every float result is rounded (D-004);
	trace_t.fraction / endpos are double (collision.h) and expressions mixing them are evaluated in double.
	The frame blend / skeleton calls are engine/prvm_cmds.luau (per-edict data there), SV_StartSound is
	engine/sv_main.luau (sv_main.c in 0.8.6), SV_ClientThink engine/sv_user.luau.
	NOT YET PORTED: World_Physics_Frame (world.c, ODE).
]]
local collision = require("./collision")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libm = require("./_port/libm")
local libc = require("./_port/libc")
local matrixlib = require("./matrixlib")
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local server = require("./server")
local sv_main = require("./sv_main")
local world = require("./world")

local sv_phys = {}

local R = f32.round
local toint = libc.toint
local Con_Printf, Con_DPrintf = console.Con_Printf, console.Con_DPrintf
local FieldOfs = prvm_edict.FieldOfs
local GlobalOfs = prvm_cmds.GlobalOfs
local SV_GetModelByIndex, SV_GetModelFromEdict = sv_main.SV_GetModelByIndex, sv_main.SV_GetModelFromEdict

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- world.h L27-31
local MOVE_NORMAL, MOVE_NOMONSTERS, MOVE_MISSILE, MOVE_WORLDONLY, MOVE_HITMODEL = 0, 1, 2, 3, 4
sv_phys.MOVE_NORMAL = MOVE_NORMAL
sv_phys.MOVE_NOMONSTERS = MOVE_NOMONSTERS
sv_phys.MOVE_MISSILE = MOVE_MISSILE
sv_phys.MOVE_WORLDONLY = MOVE_WORLDONLY
sv_phys.MOVE_HITMODEL = MOVE_HITMODEL
-- server.h L336, L342-348, L372, L375
local MOVETYPE_PHYSICS = 32
local SOLID_NOT, SOLID_TRIGGER, SOLID_BBOX, SOLID_SLIDEBOX, SOLID_BSP, SOLID_CORPSE = 0, 1, 2, 3, 4, 5
sv_phys.SOLID_NOT = SOLID_NOT
sv_phys.SOLID_TRIGGER = SOLID_TRIGGER
sv_phys.SOLID_BBOX = SOLID_BBOX
sv_phys.SOLID_SLIDEBOX = SOLID_SLIDEBOX
sv_phys.SOLID_BSP = SOLID_BSP
sv_phys.SOLID_CORPSE = SOLID_CORPSE
sv_phys.MOVETYPE_PHYSICS = MOVETYPE_PHYSICS
local FL_MONSTER, FL_ITEM = 32, 256
sv_phys.FL_MONSTER = FL_MONSTER
sv_phys.FL_ITEM = FL_ITEM
-- bspfile.h L191-200 (the non-Q1 values)
local SUPERCONTENTS_SOLID = 0x00000001
local SUPERCONTENTS_BODY = 0x00000020
local SUPERCONTENTS_CORPSE = 0x00000040
local SUPERCONTENTS_PLAYERCLIP = 0x00000100
local SUPERCONTENTS_MONSTERCLIP = 0x00000200
local PFLAGS_FULLDYNAMIC = 128 -- protocol.h L84
local MAX_EDICTS = 32768 -- quakedef.h L139
local MAX_MODELS = server.MAX_MODELS
local PITCH, YAW, ROLL = 1, 2, 3 -- mathlib.h PITCH 0 / YAW 1 / ROLL 2, as Luau indices

-- cvars of sv_main.c (registered values, else the defaults sv_main.c registers them with)
local function cvarint(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else default
end

-- edict field and global slots (see the header)
local function EF(prog: any, ed: number, f: string): number -- PRVM_serveredictfloat
	return buffer.readf32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4)
end
local function EI(prog: any, ed: number, f: string): number -- PRVM_serveredictedict / function / string
	return buffer.readi32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4)
end
local function EV(prog: any, ed: number, f: string): { number } -- a copy of PRVM_serveredictvector
	local b, o = prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4
	return { buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8) }
end
local function SET_EV(prog: any, ed: number, f: string, v: { number }) -- VectorCopy(v, PRVM_serveredictvector)
	local b, o = prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4
	buffer.writef32(b, o, v[1])
	buffer.writef32(b, o + 4, v[2])
	buffer.writef32(b, o + 8, v[3])
end
local function GI(prog: any, g: string): number -- PRVM_serverglobaledict / string
	return buffer.readi32(prog.globals, GlobalOfs(prog, g) * 4)
end
local function SET_GI(prog: any, g: string, v: number)
	buffer.writei32(prog.globals, GlobalOfs(prog, g) * 4, v)
end
local function SET_GF(prog: any, g: string, v: number) -- PRVM_serverglobalfloat = v (stored as float)
	buffer.writef32(prog.globals, GlobalOfs(prog, g) * 4, v)
end
local function SET_GV(prog: any, g: string, x: number, y: number, z: number)
	local o = GlobalOfs(prog, g) * 4
	buffer.writef32(prog.globals, o, x)
	buffer.writef32(prog.globals, o + 4, y)
	buffer.writef32(prog.globals, o + 8, z)
end

-- VM_GenerateFrameGroupBlend + VM_FrameBlendFromFrameGroupBlend(..., sv.time) + VM_UpdateEdictSkeleton
-- (engine/prvm_cmds.luau) on ent's priv.server frame blend data, as the C does before each clip against an
-- entity and in SV_LinkEdict; returns ent->priv.server->frameblend and &ent->priv.server->skeleton
local function frameblend_update(prog: any, ent: number, model: any): (any, any)
	local framegroupblend, frameblend, skeleton = prvm_cmds.EdictFrameBlend(prog, ent)
	prvm_cmds.VM_GenerateFrameGroupBlend(prog, framegroupblend, ent)
	prvm_cmds.VM_FrameBlendFromFrameGroupBlend(frameblend, framegroupblend, model, server.sv.time)
	prvm_cmds.VM_UpdateEdictSkeleton(prog, ent, model, frameblend)
	return frameblend, skeleton
end

-- port: sv_phys.c SV_GetPitchSign L47-63 @xonotic-v0.8.6 (gamemode is GAME_XONOTIC, not GAME_TENEBRAE)
function sv_phys.SV_GetPitchSign(prog: any, ent: number): number
	local model = SV_GetModelFromEdict(ent)
	local alias
	if model then
		alias = model.type == "mod_alias"
	else
		-- (unsigned char) of the float: cvttss2si then the low 8 bits, as gcc does on x86-64
		alias = bit32.band(bit32.band(toint(EF(prog, ent, "pflags")), 255), PFLAGS_FULLDYNAMIC) ~= 0
		-- || ((gamemode == GAME_TENEBRAE) && ...): false
	end
	if alias then
		return -1
	end
	return 1
end
local SV_GetPitchSign = sv_phys.SV_GetPitchSign

--[[
===============================================================================

LINE TESTING IN HULLS

===============================================================================
]]

-- port: sv_phys.c SV_GenericHitSuperContentsMask L73-97 @xonotic-v0.8.6 (passedict: edict number or nil)
function sv_phys.SV_GenericHitSuperContentsMask(passedict: number?): number
	local prog = cvar.prvm_prog_list[0]
	if passedict then
		local dphitcontentsmask = toint(EF(prog, passedict, "dphitcontentsmask"))
		if dphitcontentsmask ~= 0 then
			return dphitcontentsmask
		elseif EF(prog, passedict, "solid") == SOLID_SLIDEBOX then
			if bit32.band(toint(EF(prog, passedict, "flags")), FL_MONSTER) ~= 0 then
				return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY, SUPERCONTENTS_MONSTERCLIP)
			else
				return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY, SUPERCONTENTS_PLAYERCLIP)
			end
		elseif EF(prog, passedict, "solid") == SOLID_CORPSE then
			return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY)
		elseif EF(prog, passedict, "solid") == SOLID_TRIGGER then
			return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY)
		else
			return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY, SUPERCONTENTS_CORPSE)
		end
	else
		return bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY, SUPERCONTENTS_CORPSE)
	end
end

-- C min / max macros (mathlib.h L54-55): the second operand when the comparison is false
local function cmin(a: number, b: number): number
	return if a < b then a else b
end
local function cmax(a: number, b: number): number
	return if a > b then a else b
end

local function VectorCompare(a: { number }, b: { number }): boolean
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

local touchedicts_TracePoint: { number } = {}
local touchedicts_TraceLine: { number } = {}
local touchedicts_TraceBox: { number } = {}
local touchedicts_PointSuperContents: { number } = {}
local touchedicts_TouchAreaGrid: { number } = {}

--[[
==================
SV_TracePoint
==================
]]
-- port: sv_phys.c SV_TracePoint L104-243 @xonotic-v0.8.6 (returns a new trace_t; passedict: edict number or nil)
function sv_phys.SV_TracePoint(
	start: { number },
	type: number,
	passedict: number?,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number
): collision.trace_t
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local pitchsign = 1
	local trace = collision.newtrace()
	-- bounding box of entire move area
	local clipboxmins, clipboxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	-- trace results
	local cliptrace = collision.newtrace()
	-- matrices to transform into/out of other entity's space
	local matrix, imatrix = matrixlib.new(), matrixlib.new()
	local touchedicts = touchedicts_TracePoint

	--return SV_TraceBox(start, vec3_origin, vec3_origin, end, type, passedict, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask);

	-- start and end origin of move
	local clipstart = { start[1], start[2], start[3] }
	-- size when clipping against monsters
	local clipmins2 = { 0, 0, 0 }
	local clipmaxs2 = { 0, 0, 0 }

	-- clip to world
	collision.Collision_ClipPointToWorld(
		cliptrace,
		sv.worldmodel,
		clipstart,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask
	)
	cliptrace.bmodelstartsolid = cliptrace.startsolid
	cliptrace.worldstartsolid = cliptrace.bmodelstartsolid
	if cliptrace.startsolid or cliptrace.fraction < 1 then
		cliptrace.ent = 0
	end
	if type == MOVE_WORLDONLY then
		return cliptrace -- goto finished
	end

	if type == MOVE_MISSILE then
		-- LordHavoc: modified this, was = -15, now -= 15
		for i = 1, 3 do
			clipmins2[i] = R(clipmins2[i] - 15)
			clipmaxs2[i] = R(clipmaxs2[i] + 15)
		end
	end

	-- create the bounding box of the entire move (min(float, double) + float - 1 in double, stored as float)
	for i = 1, 3 do
		clipboxmins[i] = R(cmin(clipstart[i], cliptrace.endpos[i]) + clipmins2[i] - 1)
		clipboxmaxs[i] = R(cmax(clipstart[i], cliptrace.endpos[i]) + clipmaxs2[i] + 1)
	end

	-- debug override to test against everything
	if cvarint("sv_debugmove", 0) ~= 0 then
		local lo, hi = R(-999999999), R(999999999)
		clipboxmins[1], clipboxmins[2], clipboxmins[3] = lo, lo, lo
		clipboxmaxs[1], clipboxmaxs[2], clipboxmaxs[3] = hi, hi, hi
	end

	-- if the passedict is world, make it NULL (to avoid two checks each time)
	if passedict == 0 then
		passedict = nil
	end
	-- precalculate prog value for passedict for comparisons
	-- (C: PRVM_EDICT_TO_PROG(NULL) is a meaningless pointer difference; it is only compared when passedict is set)
	local passedictprog = passedict
	-- precalculate passedict's owner edict pointer for comparisons
	local traceowner = if passedict then EI(prog, passedict, "owner") else nil

	-- clip to entities
	-- because this uses World_EntitiestoBox, we know all entity boxes overlap
	-- the clip region, so we can skip culling checks in the loop below
	local numtouchedicts = sv_phys.SV_EntitiesInBox(clipboxmins, clipboxmaxs, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	for i = 0, numtouchedicts - 1 do
		local touch = touchedicts[i + 1]

		if EF(prog, touch, "solid") < SOLID_BBOX then
			continue
		end
		if type == MOVE_NOMONSTERS and EF(prog, touch, "solid") ~= SOLID_BSP then
			continue
		end

		if passedict then
			-- don't clip against self
			if passedict == touch then
				continue
			end
			-- don't clip owned entities against owner
			if traceowner == touch then
				continue
			end
			-- don't clip owner against owned entities
			if passedictprog == EI(prog, touch, "owner") then
				continue
			end
			-- don't clip points against points (they can't collide)
			if
				VectorCompare(EV(prog, touch, "mins"), EV(prog, touch, "maxs"))
				and (type ~= MOVE_MISSILE or not (bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0))
			then
				continue
			end
		end

		local bodysupercontents = if EF(prog, touch, "solid") == SOLID_CORPSE
			then SUPERCONTENTS_CORPSE
			else SUPERCONTENTS_BODY

		-- might interact, so do an exact clip
		local model = nil
		if toint(EF(prog, touch, "solid")) == SOLID_BSP or type == MOVE_HITMODEL then
			model = SV_GetModelFromEdict(touch)
			pitchsign = SV_GetPitchSign(prog, touch)
		end
		local origin, angles = EV(prog, touch, "origin"), EV(prog, touch, "angles")
		if model then
			matrixlib.Matrix4x4_CreateFromQuakeEntity(
				matrix,
				origin[1],
				origin[2],
				origin[3],
				R(pitchsign * angles[1]),
				angles[2],
				angles[3],
				1
			)
		else
			matrixlib.Matrix4x4_CreateTranslate(matrix, origin[1], origin[2], origin[3])
		end
		matrixlib.Matrix4x4_Invert_Simple(imatrix, matrix)
		local touchframeblend, touchskeleton = frameblend_update(prog, touch, model)
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				clipmins2,
				clipmaxs2,
				clipstart,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				0.0
			)
		else
			collision.Collision_ClipPointToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		end

		collision.Collision_CombineTraces(cliptrace, trace, touch, EF(prog, touch, "solid") == SOLID_BSP)
	end

	-- finished:
	return cliptrace
end

--[[
==================
SV_TraceLine
==================
]]
-- port: sv_phys.c SV_TraceLine L250-392 @xonotic-v0.8.6 (returns a new trace_t; passedict: edict number or nil)
function sv_phys.SV_TraceLine(
	start: { number },
	end_: { number },
	type: number,
	passedict: number?,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number,
	extend: number
): collision.trace_t
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local pitchsign = 1
	if VectorCompare(start, end_) then
		return sv_phys.SV_TracePoint(
			start,
			type,
			passedict,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask
		)
	end
	local trace = collision.newtrace()
	-- bounding box of entire move area
	local clipboxmins, clipboxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	-- trace results
	local cliptrace = collision.newtrace()
	-- matrices to transform into/out of other entity's space
	local matrix, imatrix = matrixlib.new(), matrixlib.new()
	local touchedicts = touchedicts_TraceLine

	--return SV_TraceBox(start, vec3_origin, vec3_origin, end, type, passedict, hitsupercontentsmask);

	-- start and end origin of move
	local clipstart = { start[1], start[2], start[3] }
	local clipend = { end_[1], end_[2], end_[3] }
	-- size when clipping against monsters
	local clipmins2 = { 0, 0, 0 }
	local clipmaxs2 = { 0, 0, 0 }

	-- clip to world
	collision.Collision_ClipLineToWorld(
		cliptrace,
		sv.worldmodel,
		clipstart,
		clipend,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		extend,
		false
	)
	cliptrace.bmodelstartsolid = cliptrace.startsolid
	cliptrace.worldstartsolid = cliptrace.bmodelstartsolid
	if cliptrace.startsolid or cliptrace.fraction < 1 then
		cliptrace.ent = 0
	end
	if type == MOVE_WORLDONLY then
		return cliptrace -- goto finished
	end

	if type == MOVE_MISSILE then
		-- LordHavoc: modified this, was = -15, now -= 15
		for i = 1, 3 do
			clipmins2[i] = R(clipmins2[i] - 15)
			clipmaxs2[i] = R(clipmaxs2[i] + 15)
		end
	end

	-- create the bounding box of the entire move (min(float, double) + float - 1 in double, stored as float)
	for i = 1, 3 do
		clipboxmins[i] = R(cmin(clipstart[i], cliptrace.endpos[i]) + clipmins2[i] - 1)
		clipboxmaxs[i] = R(cmax(clipstart[i], cliptrace.endpos[i]) + clipmaxs2[i] + 1)
	end

	-- debug override to test against everything
	if cvarint("sv_debugmove", 0) ~= 0 then
		local lo, hi = R(-999999999), R(999999999)
		clipboxmins[1], clipboxmins[2], clipboxmins[3] = lo, lo, lo
		clipboxmaxs[1], clipboxmaxs[2], clipboxmaxs[3] = hi, hi, hi
	end

	-- if the passedict is world, make it NULL (to avoid two checks each time)
	if passedict == 0 then
		passedict = nil
	end
	-- precalculate prog value for passedict for comparisons
	local passedictprog = passedict
	-- precalculate passedict's owner edict pointer for comparisons
	local traceowner = if passedict then EI(prog, passedict, "owner") else nil

	-- clip to entities
	-- because this uses World_EntitiestoBox, we know all entity boxes overlap
	-- the clip region, so we can skip culling checks in the loop below
	local numtouchedicts = sv_phys.SV_EntitiesInBox(clipboxmins, clipboxmaxs, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	for i = 0, numtouchedicts - 1 do
		local touch = touchedicts[i + 1]

		if EF(prog, touch, "solid") < SOLID_BBOX then
			continue
		end
		if type == MOVE_NOMONSTERS and EF(prog, touch, "solid") ~= SOLID_BSP then
			continue
		end

		if passedict then
			-- don't clip against self
			if passedict == touch then
				continue
			end
			-- don't clip owned entities against owner
			if traceowner == touch then
				continue
			end
			-- don't clip owner against owned entities
			if passedictprog == EI(prog, touch, "owner") then
				continue
			end
			-- don't clip points against points (they can't collide)
			if
				VectorCompare(EV(prog, touch, "mins"), EV(prog, touch, "maxs"))
				and (type ~= MOVE_MISSILE or not (bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0))
			then
				continue
			end
		end

		local bodysupercontents = if EF(prog, touch, "solid") == SOLID_CORPSE
			then SUPERCONTENTS_CORPSE
			else SUPERCONTENTS_BODY

		-- might interact, so do an exact clip
		local model = nil
		if toint(EF(prog, touch, "solid")) == SOLID_BSP or type == MOVE_HITMODEL then
			model = SV_GetModelFromEdict(touch)
			pitchsign = SV_GetPitchSign(prog, touch)
		end
		local origin, angles = EV(prog, touch, "origin"), EV(prog, touch, "angles")
		if model then
			matrixlib.Matrix4x4_CreateFromQuakeEntity(
				matrix,
				origin[1],
				origin[2],
				origin[3],
				R(pitchsign * angles[1]),
				angles[2],
				angles[3],
				1
			)
		else
			matrixlib.Matrix4x4_CreateTranslate(matrix, origin[1], origin[2], origin[3])
		end
		matrixlib.Matrix4x4_Invert_Simple(imatrix, matrix)
		local touchframeblend, touchskeleton = frameblend_update(prog, touch, model)
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				clipmins2,
				clipmaxs2,
				clipend,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				extend
			)
		else
			collision.Collision_ClipLineToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				clipend,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				extend,
				false
			)
		end

		collision.Collision_CombineTraces(cliptrace, trace, touch, EF(prog, touch, "solid") == SOLID_BSP)
	end

	-- finished:
	return cliptrace
end

--[[
==================
SV_Move
==================
]]
-- port: sv_phys.c SV_TraceBox L402-570 @xonotic-v0.8.6 (COLLISIONPARANOID is 0 in the release; returns a new
-- trace_t; passedict: edict number or nil)
function sv_phys.SV_TraceBox(
	start: { number },
	mins: { number },
	maxs: { number },
	end_: { number },
	type: number,
	passedict: number?,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number,
	extend: number
): collision.trace_t
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local hullmins, hullmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local pitchsign = 1
	if VectorCompare(mins, maxs) then
		local shiftstart = { R(start[1] + mins[1]), R(start[2] + mins[2]), R(start[3] + mins[3]) }
		local shiftend = { R(end_[1] + mins[1]), R(end_[2] + mins[2]), R(end_[3] + mins[3]) }
		local trace
		if VectorCompare(start, end_) then
			trace = sv_phys.SV_TracePoint(
				shiftstart,
				type,
				passedict,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask
			)
		else
			trace = sv_phys.SV_TraceLine(
				shiftstart,
				shiftend,
				type,
				passedict,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				extend
			)
		end
		-- VectorSubtract(trace.endpos, mins, trace.endpos): double - float, stored as double
		trace.endpos[1] = trace.endpos[1] - mins[1]
		trace.endpos[2] = trace.endpos[2] - mins[2]
		trace.endpos[3] = trace.endpos[3] - mins[3]
		return trace
	end
	local trace = collision.newtrace()
	-- bounding box of entire move area
	local clipboxmins, clipboxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	-- trace results
	local cliptrace = collision.newtrace()
	-- matrices to transform into/out of other entity's space
	local matrix, imatrix = matrixlib.new(), matrixlib.new()
	local touchedicts = touchedicts_TraceBox

	-- start and end origin of move
	local clipstart = { start[1], start[2], start[3] }
	local clipend = { end_[1], end_[2], end_[3] }
	-- size of the moving object
	local clipmins = { mins[1], mins[2], mins[3] }
	local clipmaxs = { maxs[1], maxs[2], maxs[3] }
	-- size when clipping against monsters
	local clipmins2 = { mins[1], mins[2], mins[3] }
	local clipmaxs2 = { maxs[1], maxs[2], maxs[3] }

	-- clip to world
	collision.Collision_ClipToWorld(
		cliptrace,
		sv.worldmodel,
		clipstart,
		clipmins,
		clipmaxs,
		clipend,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		extend
	)
	cliptrace.bmodelstartsolid = cliptrace.startsolid
	cliptrace.worldstartsolid = cliptrace.bmodelstartsolid
	if cliptrace.startsolid or cliptrace.fraction < 1 then
		cliptrace.ent = 0
	end
	if type == MOVE_WORLDONLY then
		return cliptrace -- goto finished
	end

	if type == MOVE_MISSILE then
		-- LordHavoc: modified this, was = -15, now -= 15
		for i = 1, 3 do
			clipmins2[i] = R(clipmins2[i] - 15)
			clipmaxs2[i] = R(clipmaxs2[i] + 15)
		end
	end

	-- get adjusted box for bmodel collisions if the world is q1bsp or hlbsp
	if sv.worldmodel and sv.worldmodel.brush.RoundUpToHullSize then
		sv.worldmodel.brush.RoundUpToHullSize(sv.worldmodel, clipmins, clipmaxs, hullmins, hullmaxs)
	else
		hullmins[1], hullmins[2], hullmins[3] = clipmins[1], clipmins[2], clipmins[3]
		hullmaxs[1], hullmaxs[2], hullmaxs[3] = clipmaxs[1], clipmaxs[2], clipmaxs[3]
	end

	-- create the bounding box of the entire move (min(float, double) + float - 1 in double, stored as float)
	for i = 1, 3 do
		clipboxmins[i] = R(cmin(clipstart[i], cliptrace.endpos[i]) + cmin(hullmins[i], clipmins2[i]) - 1)
		clipboxmaxs[i] = R(cmax(clipstart[i], cliptrace.endpos[i]) + cmax(hullmaxs[i], clipmaxs2[i]) + 1)
	end

	-- debug override to test against everything
	if cvarint("sv_debugmove", 0) ~= 0 then
		local lo, hi = R(-999999999), R(999999999)
		clipboxmins[1], clipboxmins[2], clipboxmins[3] = lo, lo, lo
		clipboxmaxs[1], clipboxmaxs[2], clipboxmaxs[3] = hi, hi, hi
	end

	-- if the passedict is world, make it NULL (to avoid two checks each time)
	if passedict == 0 then
		passedict = nil
	end
	-- precalculate prog value for passedict for comparisons
	local passedictprog = passedict
	-- figure out whether this is a point trace for comparisons
	local pointtrace = VectorCompare(clipmins, clipmaxs)
	-- precalculate passedict's owner edict pointer for comparisons
	local traceowner = if passedict then EI(prog, passedict, "owner") else nil

	-- clip to entities
	-- because this uses World_EntitiestoBox, we know all entity boxes overlap
	-- the clip region, so we can skip culling checks in the loop below
	local numtouchedicts = sv_phys.SV_EntitiesInBox(clipboxmins, clipboxmaxs, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	for i = 0, numtouchedicts - 1 do
		local touch = touchedicts[i + 1]

		if EF(prog, touch, "solid") < SOLID_BBOX then
			continue
		end
		if type == MOVE_NOMONSTERS and EF(prog, touch, "solid") ~= SOLID_BSP then
			continue
		end

		if passedict then
			-- don't clip against self
			if passedict == touch then
				continue
			end
			-- don't clip owned entities against owner
			if traceowner == touch then
				continue
			end
			-- don't clip owner against owned entities
			if passedictprog == EI(prog, touch, "owner") then
				continue
			end
			-- don't clip points against points (they can't collide)
			if
				pointtrace
				and VectorCompare(EV(prog, touch, "mins"), EV(prog, touch, "maxs"))
				and (type ~= MOVE_MISSILE or not (bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0))
			then
				continue
			end
		end

		local bodysupercontents = if EF(prog, touch, "solid") == SOLID_CORPSE
			then SUPERCONTENTS_CORPSE
			else SUPERCONTENTS_BODY

		-- might interact, so do an exact clip
		local model = nil
		if toint(EF(prog, touch, "solid")) == SOLID_BSP or type == MOVE_HITMODEL then
			model = SV_GetModelFromEdict(touch)
			pitchsign = SV_GetPitchSign(prog, touch)
		end
		local origin, angles = EV(prog, touch, "origin"), EV(prog, touch, "angles")
		if model then
			matrixlib.Matrix4x4_CreateFromQuakeEntity(
				matrix,
				origin[1],
				origin[2],
				origin[3],
				R(pitchsign * angles[1]),
				angles[2],
				angles[3],
				1
			)
		else
			matrixlib.Matrix4x4_CreateTranslate(matrix, origin[1], origin[2], origin[3])
		end
		matrixlib.Matrix4x4_Invert_Simple(imatrix, matrix)
		local touchframeblend, touchskeleton = frameblend_update(prog, touch, model)
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				clipmins2,
				clipmaxs2,
				clipend,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				extend
			)
		else
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				touchframeblend,
				touchskeleton,
				touchmins,
				touchmaxs,
				bodysupercontents,
				matrix,
				imatrix,
				clipstart,
				clipmins,
				clipmaxs,
				clipend,
				hitsupercontentsmask,
				skipsupercontentsmask,
				skipmaterialflagsmask,
				extend
			)
		end

		collision.Collision_CombineTraces(cliptrace, trace, touch, EF(prog, touch, "solid") == SOLID_BSP)
	end

	-- finished:
	return cliptrace
end

-- port: sv_phys.c SV_PointSuperContents L593-645 @xonotic-v0.8.6
function sv_phys.SV_PointSuperContents(point: { number }): number
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local supercontents = 0
	local transformed = { 0, 0, 0 }
	-- matrices to transform into/out of other entity's space
	local matrix, imatrix = matrixlib.new(), matrixlib.new()
	local touchedicts = touchedicts_PointSuperContents

	-- get world supercontents at this point
	if sv.worldmodel and sv.worldmodel.PointSuperContents then
		supercontents = sv.worldmodel.PointSuperContents(sv.worldmodel, 0, point)
	end

	-- if sv_gameplayfix_swiminbmodels is off we're done
	if cvarint("sv_gameplayfix_swiminbmodels", 1) == 0 then
		return supercontents
	end

	-- get list of entities at this point
	local numtouchedicts = sv_phys.SV_EntitiesInBox(point, point, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	for i = 0, numtouchedicts - 1 do
		local touch = touchedicts[i + 1]

		-- we only care about SOLID_BSP for pointcontents
		if EF(prog, touch, "solid") ~= SOLID_BSP then
			continue
		end

		-- might interact, so do an exact clip
		local model = SV_GetModelFromEdict(touch)
		if not model or not model.PointSuperContents then
			continue
		end
		local origin, angles = EV(prog, touch, "origin"), EV(prog, touch, "angles")
		matrixlib.Matrix4x4_CreateFromQuakeEntity(
			matrix,
			origin[1],
			origin[2],
			origin[3],
			angles[1],
			angles[2],
			angles[3],
			1
		)
		matrixlib.Matrix4x4_Invert_Simple(imatrix, matrix)
		matrixlib.Matrix4x4_Transform(imatrix, point, transformed)
		local frame = toint(EF(prog, touch, "frame"))
		-- bound(0, frame, (model->numframes - 1))
		local maxframe = model.numframes - 1
		local boundframe = if frame >= 0 then (if frame < maxframe then frame else maxframe) else 0
		supercontents = bit32.bor(supercontents, model.PointSuperContents(model, boundframe, transformed))
	end

	return supercontents
end

--[[
===============================================================================

Linking entities into the world culling system

===============================================================================
]]

-- port: sv_phys.c SV_EntitiesInBox L655-685 @xonotic-v0.8.6
-- (resultedicts: edict numbers at [1 .. min(n, maxedicts)]; returns n)
function sv_phys.SV_EntitiesInBox(
	mins: { number },
	maxs: { number },
	maxedicts: number,
	resultedicts: { number }?
): number
	local prog = cvar.prvm_prog_list[0]
	if maxedicts < 1 or resultedicts == nil then
		return 0
	end
	-- LordHavoc: discovered this actually causes its own bugs (dm6 teleporters being too close to info_teleport_destination)
	--VectorSet(paddedmins, mins[0] - 10, mins[1] - 10, mins[2] - 1);
	--VectorSet(paddedmaxs, maxs[0] + 10, maxs[1] + 10, maxs[2] + 1);
	local paddedmins = { mins[1], mins[2], mins[3] }
	local paddedmaxs = { maxs[1], maxs[2], maxs[3] }
	if cvarint("sv_areadebug", 0) ~= 0 then
		local numresultedicts = 0
		for edictindex = 1, prog.num_edicts - 1 do
			local ed = edictindex
			if not prog.ed_free[ed] then
				local absmin, absmax = EV(prog, ed, "absmin"), EV(prog, ed, "absmax")
				-- BoxesOverlap(absmin, absmax, paddedmins, paddedmaxs)
				if
					absmin[1] <= paddedmaxs[1]
					and absmax[1] >= paddedmins[1]
					and absmin[2] <= paddedmaxs[2]
					and absmax[2] >= paddedmins[2]
					and absmin[3] <= paddedmaxs[3]
					and absmax[3] >= paddedmins[3]
				then
					resultedicts[numresultedicts + 1] = ed
					numresultedicts += 1
					if numresultedicts == maxedicts then
						break
					end
				end
			end
		end
		return numresultedicts
	else
		return world.World_EntitiesInBox(server.sv.world, paddedmins, paddedmaxs, maxedicts, resultedicts)
	end
end

-- port: sv_phys.c SV_LinkEdict_TouchAreaGrid_Call L687-707 @xonotic-v0.8.6 (touch, ent: edict numbers)
function sv_phys.SV_LinkEdict_TouchAreaGrid_Call(touch: number, ent: number)
	local prog = cvar.prvm_prog_list[0]
	SET_GI(prog, "self", touch)
	SET_GI(prog, "other", ent)
	SET_GF(prog, "time", server.sv.time) -- double sv.time stored into a float global
	SET_GF(prog, "trace_allsolid", 0)
	SET_GF(prog, "trace_startsolid", 0)
	SET_GF(prog, "trace_fraction", 1)
	SET_GF(prog, "trace_inwater", 0)
	SET_GF(prog, "trace_inopen", 1)
	local origin = EV(prog, touch, "origin")
	SET_GV(prog, "trace_endpos", origin[1], origin[2], origin[3])
	SET_GV(prog, "trace_plane_normal", 0, 0, 1)
	SET_GF(prog, "trace_plane_dist", 0)
	SET_GI(prog, "trace_ent", ent)
	SET_GF(prog, "trace_dpstartcontents", 0)
	SET_GF(prog, "trace_dphitcontents", 0)
	SET_GF(prog, "trace_dphitq3surfaceflags", 0)
	SET_GI(prog, "trace_dphittexturename", 0)
	prvm_edict.ExecuteProgram(prog, EI(prog, touch, "touch"), "QC function self.touch is missing")
end

-- port: sv_phys.c SV_LinkEdict_TouchAreaGrid L709-747 @xonotic-v0.8.6 (ent: edict number)
function sv_phys.SV_LinkEdict_TouchAreaGrid(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local touchedicts = touchedicts_TouchAreaGrid

	if ent == 0 then
		return -- don't add the world
	end

	if prog.ed_free[ent] then
		return
	end

	if EF(prog, ent, "solid") == SOLID_NOT then
		return
	end

	-- build a list of edicts to touch, because the link loop can be corrupted
	-- by IncreaseEdicts called during touch functions
	local area = world.edictarea(prog, ent)
	local numtouchedicts = sv_phys.SV_EntitiesInBox(area.areamins, area.areamaxs, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end

	local old_self = GI(prog, "self")
	local old_other = GI(prog, "other")
	for i = 0, numtouchedicts - 1 do
		local touch = touchedicts[i + 1]
		if touch ~= ent and toint(EF(prog, touch, "solid")) == SOLID_TRIGGER and EI(prog, touch, "touch") ~= 0 then
			sv_phys.SV_LinkEdict_TouchAreaGrid_Call(touch, ent)
		end
	end
	SET_GI(prog, "self", old_self)
	SET_GI(prog, "other", old_other)
end

-- port: sv_phys.c RotateBBox L749-778 @xonotic-v0.8.6
local function RotateBBox(
	mins: { number },
	maxs: { number },
	angles: { number },
	rotatedmins: { number },
	rotatedmaxs: { number }
)
	local v, u = { 0, 0, 0 }, { 0, 0, 0 }
	local m = matrixlib.new()
	matrixlib.Matrix4x4_CreateFromQuakeEntity(m, 0, 0, 0, angles[PITCH], angles[YAW], angles[ROLL], 1.0)

	v[1] = mins[1]
	v[2] = mins[2]
	v[3] = mins[3]
	matrixlib.Matrix4x4_Transform(m, v, u)
	rotatedmins[1], rotatedmins[2], rotatedmins[3] = u[1], u[2], u[3]
	rotatedmaxs[1], rotatedmaxs[2], rotatedmaxs[3] = u[1], u[2], u[3]
	-- the remaining seven corners, in the C order
	local corners = {
		{ maxs[1], mins[2], mins[3] },
		{ mins[1], maxs[2], mins[3] },
		{ maxs[1], maxs[2], mins[3] },
		{ mins[1], mins[2], maxs[3] },
		{ maxs[1], mins[2], maxs[3] },
		{ mins[1], maxs[2], maxs[3] },
		{ maxs[1], maxs[2], maxs[3] },
	}
	for _, c in corners do
		v[1] = c[1]
		v[2] = c[2]
		v[3] = c[3]
		matrixlib.Matrix4x4_Transform(m, v, u)
		if rotatedmins[1] > u[1] then
			rotatedmins[1] = u[1]
		end
		if rotatedmins[2] > u[2] then
			rotatedmins[2] = u[2]
		end
		if rotatedmins[3] > u[3] then
			rotatedmins[3] = u[3]
		end
		if rotatedmaxs[1] < u[1] then
			rotatedmaxs[1] = u[1]
		end
		if rotatedmaxs[2] < u[2] then
			rotatedmaxs[2] = u[2]
		end
		if rotatedmaxs[3] < u[3] then
			rotatedmaxs[3] = u[3]
		end
	end
end

--[[
===============
SV_LinkEdict

===============
]]
-- port: sv_phys.c SV_LinkEdict L786-890 @xonotic-v0.8.6 (ent: edict number)
function sv_phys.SV_LinkEdict(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local mins, maxs = { 0, 0, 0 }, { 0, 0, 0 }

	if ent == 0 then
		return -- don't add the world
	end

	if prog.ed_free[ent] then
		return
	end

	local modelindex = toint(EF(prog, ent, "modelindex"))
	if modelindex < 0 or modelindex >= MAX_MODELS then
		Con_Printf("edict %i: SOLID_BSP with invalid modelindex!\n", ent)
		modelindex = 0
	end
	local model = SV_GetModelByIndex(modelindex)

	frameblend_update(prog, ent, model)

	-- set the abs box

	local origin = EV(prog, ent, "origin")
	if EF(prog, ent, "movetype") == MOVETYPE_PHYSICS then
		-- TODO maybe should do this for rotating SOLID_BSP too? Would behave better with rotating doors
		-- TODO special handling for spheres?
		local entmins = EV(prog, ent, "mins")
		local entmaxs = EV(prog, ent, "maxs")
		local entangles = EV(prog, ent, "angles")
		RotateBBox(entmins, entmaxs, entangles, mins, maxs)
		mins[1], mins[2], mins[3] = R(origin[1] + mins[1]), R(origin[2] + mins[2]), R(origin[3] + mins[3])
		maxs[1], maxs[2], maxs[3] = R(origin[1] + maxs[1]), R(origin[2] + maxs[2]), R(origin[3] + maxs[3])
	elseif EF(prog, ent, "solid") == SOLID_BSP then
		if model ~= nil then
			if not model.TraceBox then
				Con_DPrintf("edict %i: SOLID_BSP with non-collidable model\n", ent)
			end

			local angles, avelocity = EV(prog, ent, "angles"), EV(prog, ent, "avelocity")
			local bmins, bmaxs
			if angles[1] ~= 0 or angles[3] ~= 0 or avelocity[1] ~= 0 or avelocity[3] ~= 0 then
				bmins, bmaxs = model.rotatedmins, model.rotatedmaxs
			elseif angles[2] ~= 0 or avelocity[2] ~= 0 then
				bmins, bmaxs = model.yawmins, model.yawmaxs
			else
				bmins, bmaxs = model.normalmins, model.normalmaxs
			end
			mins[1], mins[2], mins[3] = R(origin[1] + bmins[1]), R(origin[2] + bmins[2]), R(origin[3] + bmins[3])
			maxs[1], maxs[2], maxs[3] = R(origin[1] + bmaxs[1]), R(origin[2] + bmaxs[2]), R(origin[3] + bmaxs[3])
		else
			-- SOLID_BSP with no model is valid, mainly because some QC setup code does so temporarily
			local emins, emaxs = EV(prog, ent, "mins"), EV(prog, ent, "maxs")
			mins[1], mins[2], mins[3] = R(origin[1] + emins[1]), R(origin[2] + emins[2]), R(origin[3] + emins[3])
			maxs[1], maxs[2], maxs[3] = R(origin[1] + emaxs[1]), R(origin[2] + emaxs[2]), R(origin[3] + emaxs[3])
		end
	else
		local emins, emaxs = EV(prog, ent, "mins"), EV(prog, ent, "maxs")
		mins[1], mins[2], mins[3] = R(origin[1] + emins[1]), R(origin[2] + emins[2]), R(origin[3] + emins[3])
		maxs[1], maxs[2], maxs[3] = R(origin[1] + emaxs[1]), R(origin[2] + emaxs[2]), R(origin[3] + emaxs[3])
	end

	if cvarint("sv_legacy_bbox_expand", 1) ~= 0 then
		if bit32.band(toint(EF(prog, ent, "flags")), FL_ITEM) ~= 0 then
			-- to make items easier to pick up and allow them to be grabbed off
			-- of shelves, the abs sizes are expanded
			mins[1] = R(mins[1] - 15)
			mins[2] = R(mins[2] - 15)
			mins[3] = R(mins[3] - 1)
			maxs[1] = R(maxs[1] + 15)
			maxs[2] = R(maxs[2] + 15)
			maxs[3] = R(maxs[3] + 1)
		else
			-- because movement is clipped an epsilon away from an actual edge,
			-- we must fully check even when bounding boxes don't quite touch
			mins[1] = R(mins[1] - 1)
			mins[2] = R(mins[2] - 1)
			mins[3] = R(mins[3] - 1)
			maxs[1] = R(maxs[1] + 1)
			maxs[2] = R(maxs[2] + 1)
			maxs[3] = R(maxs[3] + 1)
		end
	end

	SET_EV(prog, ent, "absmin", mins)
	SET_EV(prog, ent, "absmax", maxs)

	world.World_LinkEdict(server.sv.world, ent, mins, maxs)
end

-- port: sv_phys.c SV_NudgeOutOfSolid L1525-1563 @xonotic-v0.8.6 (ent: edict number)
function sv_phys.SV_NudgeOutOfSolid(ent: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local sepvar = cvar.Cvar_FindVar("sv_gameplayfix_nudgeoutofsolid_separation")
	local separation = if sepvar then sepvar.value else R(0.03125)
	if sv.worldmodel and sv.worldmodel.brushq1 and (sv.worldmodel.brushq1.numclipnodes or 0) ~= 0 then
		separation = 0.0 -- when using hulls, it can not be enlarged
	end
	local stuckmins = EV(prog, ent, "mins")
	local stuckmaxs = EV(prog, ent, "maxs")
	for k = 1, 3 do
		stuckmins[k] = R(stuckmins[k] - separation)
		stuckmaxs[k] = R(stuckmaxs[k] + separation)
	end
	-- first pass we try to get it out of brush entities
	-- second pass we try to get it out of world only (can't win them all)
	for pass = 0, 1 do
		local stuckorigin = EV(prog, ent, "origin")
		for _ = 0, 9 do
			local stucktrace = sv_phys.SV_TraceBox(
				stuckorigin,
				stuckmins,
				stuckmaxs,
				stuckorigin,
				if pass ~= 0 then MOVE_WORLDONLY else MOVE_NOMONSTERS,
				ent,
				sv_phys.SV_GenericHitSuperContentsMask(ent),
				0,
				0,
				collision.cv.collision_extendmovelength.value
			)
			if not stucktrace.bmodelstartsolid or stucktrace.startdepth >= 0 then
				-- found a good location, use it
				SET_EV(prog, ent, "origin", stuckorigin)
				return true
			end
			local nudge = R(-stucktrace.startdepth) -- vec_t nudge = -(double)
			-- VectorMA(stuckorigin, nudge, stucktrace.startdepthnormal, stuckorigin): float + float * double
			local n = stucktrace.startdepthnormal
			stuckorigin[1] = R(stuckorigin[1] + nudge * n[1])
			stuckorigin[2] = R(stuckorigin[2] + nudge * n[2])
			stuckorigin[3] = R(stuckorigin[3] + nudge * n[3])
		end
	end
	return false
end

--[[
	Movement and physics (sv_phys.c L892-3232).
	The edict_engineprivate_t fields (progs.h L68-110) used here are one table per field on the prog, indexed
	by edict number, nil = the zeroed C memory: prog.ed_mark (priv.required->mark, shared with
	svvm_cmds.luau), prog.ed_move, prog.ed_suspendedinairflag (shared with svvm_cmds.luau),
	prog.ed_waterposition_forceupdate, prog.ed_waterposition_origin, prog.ed_moved_from,
	prog.ed_moved_fromangles, prog.ed_cullmins / prog.ed_cullmaxs (written by SV_PrepareEntityForSending,
	sv_main.c, not ported yet: until then they stay zero, as for an entity that was never sent).
	host_client is server.host_client; svs is host_cmd.svs, client i (0-based) at svs.clients[i], nil = a
	zeroed client_t. PRVM_serverfunction(name) is prog.funcoffsets[name] (PRVM_ED_FindFunction on first use,
	0 = missing). SV_PushEntity returns (qboolean, trace_t) instead of filling a trace_t *.
]]
local host_cmd = require("./host_cmd")
local mathlib = require("./mathlib")
local svvm_cmds = require("./svvm_cmds")

local DotProduct = mathlib.DotProduct
local Mod_Q1BSP_NativeContentsFromSuperContents = svvm_cmds.Mod_Q1BSP_NativeContentsFromSuperContents

-- server.h L322-339
local MOVETYPE_NONE, MOVETYPE_WALK, MOVETYPE_STEP, MOVETYPE_FLY, MOVETYPE_TOSS = 0, 3, 4, 5, 6
local MOVETYPE_PUSH, MOVETYPE_NOCLIP, MOVETYPE_FLYMISSILE, MOVETYPE_BOUNCE = 7, 8, 9, 10
local MOVETYPE_BOUNCEMISSILE, MOVETYPE_FOLLOW, MOVETYPE_FAKEPUSH, MOVETYPE_FLY_WORLDONLY = 11, 12, 13, 33
local MOVETYPE_USER_FIRST, MOVETYPE_USER_LAST = 128, 191
sv_phys.MOVETYPE_NONE = MOVETYPE_NONE
sv_phys.MOVETYPE_WALK = MOVETYPE_WALK
sv_phys.MOVETYPE_STEP = MOVETYPE_STEP
sv_phys.MOVETYPE_FLY = MOVETYPE_FLY
sv_phys.MOVETYPE_TOSS = MOVETYPE_TOSS
sv_phys.MOVETYPE_PUSH = MOVETYPE_PUSH
sv_phys.MOVETYPE_NOCLIP = MOVETYPE_NOCLIP
sv_phys.MOVETYPE_FLYMISSILE = MOVETYPE_FLYMISSILE
sv_phys.MOVETYPE_BOUNCE = MOVETYPE_BOUNCE
sv_phys.MOVETYPE_BOUNCEMISSILE = MOVETYPE_BOUNCEMISSILE
sv_phys.MOVETYPE_FOLLOW = MOVETYPE_FOLLOW
sv_phys.MOVETYPE_FAKEPUSH = MOVETYPE_FAKEPUSH
sv_phys.MOVETYPE_FLY_WORLDONLY = MOVETYPE_FLY_WORLDONLY
-- server.h L367-378
local FL_FLY, FL_SWIM, FL_ONGROUND, FL_WATERJUMP = 1, 2, 512, 2048
sv_phys.FL_FLY = FL_FLY
sv_phys.FL_SWIM = FL_SWIM
sv_phys.FL_ONGROUND = FL_ONGROUND
sv_phys.FL_WATERJUMP = FL_WATERJUMP
-- bspfile.h L128-131, L192-194, L213
local CONTENTS_EMPTY, CONTENTS_WATER, CONTENTS_SLIME = -1, -3, -4
local SUPERCONTENTS_LIQUIDSMASK = bit32.bor(0x08, 0x04, 0x02)
local PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN, PRVM_EDICT_MARK_SETORIGIN_CAUGHT = -1, -2 -- progsvm.h L75-76
local OFS_PARM0, OFS_PARM1 = 4, 7 -- pr_comp.h
local MOVE_EPSILON = 0.01 -- sv_phys.c L43 (unused in the release code, kept as in C)
sv_phys.MOVE_EPSILON = MOVE_EPSILON
local STOP_EPSILON = 0.1 -- sv_phys.c L1150 (double)
local MAX_CLIP_PLANES = 5 -- sv_phys.c L1180

-- cvar value (float) of sv_main.c / cvar.c, else the default it is registered with
local function cvarval(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.value else R(default)
end
local function cvarstr(name: string, default: string): string
	local v = cvar.Cvar_FindVar(name)
	return if v then v.string else default
end

local function SET_EF(prog: any, ed: number, f: string, v: number) -- PRVM_serveredictfloat(ed, f) = v
	buffer.writef32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4, v)
end
local function SET_EI(prog: any, ed: number, f: string, v: number) -- PRVM_serveredictedict(ed, f) = v
	buffer.writei32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f)) * 4, v)
end
local function EVi(prog: any, ed: number, f: string, i: number): number -- PRVM_serveredictvector(ed, f)[i - 1]
	return buffer.readf32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f) + i - 1) * 4)
end
local function SET_EVi(prog: any, ed: number, f: string, i: number, v: number)
	buffer.writef32(prog.edictsfields, (ed * prog.entityfields + FieldOfs(prog, f) + i - 1) * 4, v)
end
local function GF(prog: any, g: string): number -- PRVM_serverglobalfloat
	return buffer.readf32(prog.globals, GlobalOfs(prog, g) * 4)
end
local function SET_G_FLOAT(prog: any, ofs: number, v: number) -- PRVM_G_FLOAT(ofs) = v
	buffer.writef32(prog.globals, ofs * 4, v)
end
-- (int)flags | bit and (int)flags & ~bit: the int results are signed, then stored as float
local function orflag(x: number, b: number): number
	local r = bit32.bor(toint(x), b)
	return if r >= 0x80000000 then r - 0x100000000 else r
end
local function andnotflag(x: number, b: number): number
	local r = bit32.band(toint(x), bit32.bnot(b))
	return if r >= 0x80000000 then r - 0x100000000 else r
end
local function hasflag(x: number, b: number): boolean -- (int)x & b
	return bit32.band(toint(x), b) ~= 0
end
-- ent->priv.* table of one field (see the block comment above)
local function priv(prog: any, name: string): { [number]: any }
	local t = prog[name]
	if not t then
		t = {}
		prog[name] = t
	end
	return t
end
local function privvec(prog: any, name: string, ed: number): { number }
	local t = priv(prog, name)
	local v = t[ed]
	if not v then
		v = { 0, 0, 0 }
		t[ed] = v
	end
	return v
end
-- PRVM_serverfunction(name) (prog->funcoffsets.name)
local function serverfunction(prog: any, name: string): number
	local fo = prog.funcoffsets
	if not fo then
		fo = {}
		prog.funcoffsets = fo
	end
	local f = fo[name]
	if f == nil then
		local _, fnum = prvm_edict.PRVM_ED_FindFunction(prog, name)
		f = fnum or 0
		fo[name] = f
	end
	return f
end
-- svs.clients + i (0-based); a missing client_t is zeroed memory
local function svs_client(i: number): any
	local svs = host_cmd.svs :: any
	local c = svs.clients and svs.clients[i]
	return c or {}
end
local function classname(prog: any, ent: number): string -- PRVM_GetString(prog, PRVM_serveredictstring(ent, classname))
	return prvm_edict.PRVM_GetString(prog, EI(prog, ent, "classname"))
end

-- SV_StartSound(ent, channel, sample, 255, 1, false, 1.0f) (sv_main.c, engine/sv_main.luau); sample is a
-- cvar's string (cvarstr gives the cvar_t string reference, or the default text when the cvar is missing)
local function SV_StartSound_cvar(ent: number, channel: number, sample: any)
	local s = if type(sample) == "table" then sample.str else sample
	sv_main.SV_StartSound(ent, channel, s, 255, 1, false, 1.0)
end
-- SV_ClientThink (sv_user.c, engine/sv_user.luau; required on first use and kept: sv_user requires this module)
local sv_user_mod: any = nil
local function SV_ClientThink()
	if not sv_user_mod then
		sv_user_mod = require("./sv_user")
	end
	sv_user_mod.SV_ClientThink()
end

-- port: mathlib.c AngleVectorsFLU L498-550 @xonotic-v0.8.6 (belongs in engine/mathlib.luau, which lacks it;
-- PITCH 1, YAW 2, ROLL 3 here; double temporaries, float stores)
local function AngleVectorsFLU(angles: { number }, forward: { number }?, left: { number }?, up: { number }?)
	local M_PI = 3.14159265358979323846
	local angle = angles[YAW] * (M_PI * 2 / 360)
	local sy = libm.sin(angle)
	local cy = libm.cos(angle)
	angle = angles[PITCH] * (M_PI * 2 / 360)
	local sp = libm.sin(angle)
	local cp = libm.cos(angle)
	if forward then
		forward[1] = R(cp * cy)
		forward[2] = R(cp * sy)
		forward[3] = R(-sp)
	end
	if left or up then
		if angles[ROLL] ~= 0 then
			angle = angles[ROLL] * (M_PI * 2 / 360)
			local sr = libm.sin(angle)
			local cr = libm.cos(angle)
			if left then
				left[1] = R(sr * sp * cy + cr * -sy)
				left[2] = R(sr * sp * sy + cr * cy)
				left[3] = R(sr * cp)
			end
			if up then
				up[1] = R(cr * sp * cy + -sr * -sy)
				up[2] = R(cr * sp * sy + -sr * cy)
				up[3] = R(cr * cp)
			end
		else
			if left then
				left[1] = R(-sy)
				left[2] = R(cy)
				left[3] = 0
			end
			if up then
				up[1] = R(sp * cy)
				up[2] = R(sp * sy)
				up[3] = R(cp)
			end
		end
	end
end
sv_phys.AngleVectorsFLU = AngleVectorsFLU

--[[
===============================================================================

Utility functions

===============================================================================
]]

--[[
============
SV_TestEntityPosition

returns true if the entity is in solid currently
============
]]
-- port: sv_phys.c SV_TestEntityPosition L907-966 @xonotic-v0.8.6
function sv_phys.SV_TestEntityPosition(ent: number, offset: { number }): boolean
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local hitsupercontentsmask = sv_phys.SV_GenericHitSuperContentsMask(ent)
	local skipsupercontentsmask = 0
	local skipmaterialflagsmask = 0
	local origin = EV(prog, ent, "origin")
	local org = { R(origin[1] + offset[1]), R(origin[2] + offset[2]), R(origin[3] + offset[3]) }
	local entorigin = EV(prog, ent, "origin")
	local entmins = EV(prog, ent, "mins")
	local entmaxs = EV(prog, ent, "maxs")
	local trace = sv_phys.SV_TraceBox(
		org,
		entmins,
		entmaxs,
		entorigin,
		if EF(prog, ent, "movetype") == MOVETYPE_FLY_WORLDONLY then MOVE_WORLDONLY else MOVE_NOMONSTERS,
		ent,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		collision.cv.collision_extendmovelength.value
	)
	if bit32.band(trace.startsupercontents, hitsupercontentsmask) ~= 0 then
		return true
	else
		if
			sv.worldmodel.brushq1
			and (sv.worldmodel.brushq1.numclipnodes or 0) ~= 0
			and not VectorCompare(EV(prog, ent, "mins"), EV(prog, ent, "maxs"))
		then
			-- q1bsp/hlbsp use hulls and if the entity does not exactly match
			-- a hull size it is incorrectly tested, so this code tries to
			-- 'fix' it slightly...
			-- FIXME: this breaks entities larger than the hull size
			local m1 = { R(org[1] + entmins[1]), R(org[2] + entmins[2]), R(org[3] + entmins[3]) }
			local m2 = { R(org[1] + entmaxs[1]), R(org[2] + entmaxs[2]), R(org[3] + entmaxs[3]) }
			local s = { R(m2[1] - m1[1]), R(m2[2] - m1[2]), R(m2[3] - m1[3]) }
			local EPSILON = R(1.0 / 32.0) -- (1.0f / 32.0f)
			for k = 1, 3 do
				if s[k] >= R(EPSILON * 2) then
					m1[k] = R(m1[k] + EPSILON)
					m2[k] = R(m2[k] - EPSILON)
				end
			end
			for i = 0, 7 do
				local v = {
					if bit32.band(i, 1) ~= 0 then m2[1] else m1[1],
					if bit32.band(i, 2) ~= 0 then m2[2] else m1[2],
					if bit32.band(i, 4) ~= 0 then m2[3] else m1[3],
				}
				if bit32.band(sv_phys.SV_PointSuperContents(v), hitsupercontentsmask) ~= 0 then
					return true
				end
			end
		end
	end
	-- if the trace found a better position for the entity, move it there
	-- (VectorDistance2 of the double endpos and the float origin: double arithmetic)
	local o = EV(prog, ent, "origin")
	local dx, dy, dz = trace.endpos[1] - o[1], trace.endpos[2] - o[2], trace.endpos[3] - o[3]
	if dx * dx + dy * dy + dz * dz >= 0.0001 then
		-- #if 0: please switch back to this code when trace.endpos sometimes being in solid bug is fixed
		-- verify if the endpos is REALLY outside solid
		org = { R(trace.endpos[1]), R(trace.endpos[2]), R(trace.endpos[3]) }
		trace = sv_phys.SV_TraceBox(
			org,
			entmins,
			entmaxs,
			org,
			MOVE_NOMONSTERS,
			ent,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask,
			collision.cv.collision_extendmovelength.value
		)
		if trace.startsolid then
			Con_Printf("SV_TestEntityPosition: trace.endpos detected to be in solid. NOT using it.\n")
		else
			SET_EV(prog, ent, "origin", org)
		end
	end
	return false
end

-- DRESK - Support for Entity Contents Transition Event
--[[
================
SV_CheckContentsTransition

returns true if entity had a valid contentstransition function call
================
]]
-- port: sv_phys.c SV_CheckContentsTransition L976-1007 @xonotic-v0.8.6
function sv_phys.SV_CheckContentsTransition(ent: number, nContents: number): boolean
	local prog = cvar.prvm_prog_list[0]

	-- Default Valid Function Call to False
	local bValidFunctionCall = false

	if EF(prog, ent, "watertype") ~= nContents then
		-- Changed Contents
		-- Acquire Contents Transition Function from QC
		if EI(prog, ent, "contentstransition") ~= 0 then
			-- Valid Function; Execute
			-- Assign Valid Function
			bValidFunctionCall = true
			-- Prepare Parameters (Original Contents, New Contents)
			-- Original Contents
			SET_G_FLOAT(prog, OFS_PARM0, EF(prog, ent, "watertype"))
			-- New Contents
			SET_G_FLOAT(prog, OFS_PARM1, nContents)
			-- Assign Self
			SET_GI(prog, "self", ent)
			-- Set Time
			SET_GF(prog, "time", server.sv.time)
			-- Execute VM Function
			prvm_edict.ExecuteProgram(prog, EI(prog, ent, "contentstransition"), "contentstransition: NULL function")
		end
	end

	-- Return if Function Call was Valid
	return bValidFunctionCall
end

--[[
================
SV_CheckVelocity
================
]]
-- port: sv_phys.c SV_CheckVelocity L1015-1053 @xonotic-v0.8.6
function sv_phys.SV_CheckVelocity(ent: number)
	local prog = cvar.prvm_prog_list[0]

	--
	-- bound velocity
	--
	for i = 1, 3 do
		local v = EVi(prog, ent, "velocity", i)
		if v ~= v then
			Con_Printf("Got a NaN velocity on entity #%i (%s)\n", ent, classname(prog, ent))
			SET_EVi(prog, ent, "velocity", i, 0)
		end
		local o = EVi(prog, ent, "origin", i)
		if o ~= o then
			Con_Printf("Got a NaN origin on entity #%i (%s)\n", ent, classname(prog, ent))
			SET_EVi(prog, ent, "origin", i, 0)
		end
	end

	-- LordHavoc: a hack to ensure that the (rather silly) id1 quakec
	-- player_run/player_stand1 does not horribly malfunction if the
	-- velocity becomes a denormalized float
	local vel = EV(prog, ent, "velocity")
	if DotProduct(vel, vel) < 0.0000001 then
		SET_EV(prog, ent, "velocity", { 0, 0, 0 })
	end

	-- LordHavoc: max velocity fix, inspired by Maddes's source fixes, but this is faster
	vel = EV(prog, ent, "velocity")
	local wishspeed = DotProduct(vel, vel)
	local maxvelocity = cvarval("sv_maxvelocity", 2000)
	if wishspeed > R(maxvelocity * maxvelocity) then
		wishspeed = R(maxvelocity / math.sqrt(wishspeed))
		SET_EVi(prog, ent, "velocity", 1, R(EVi(prog, ent, "velocity", 1) * wishspeed))
		SET_EVi(prog, ent, "velocity", 2, R(EVi(prog, ent, "velocity", 2) * wishspeed))
		SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) * wishspeed))
	end
end

--[[
=============
SV_RunThink

Runs thinking code if time.  There is some play in the exact time the think
function will be called, because it is called before any movement is done
in a frame.  Not used for pushmove objects, because they must be exact.
Returns false if the entity removed itself.
=============
]]
-- port: sv_phys.c SV_RunThink L1065-1090 @xonotic-v0.8.6
function sv_phys.SV_RunThink(ent: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv

	-- don't let things stay in the past.
	-- it is possible to start that way by a trigger with a local time.
	if EF(prog, ent, "nextthink") <= 0 or EF(prog, ent, "nextthink") > sv.time + sv.frametime then
		return true
	end

	local iterations = 0
	while iterations < 128 and not prog.ed_free[ent] do
		-- max(sv.time, nextthink): double comparison, the double result stored as float
		SET_GF(prog, "time", cmax(sv.time, EF(prog, ent, "nextthink")))
		SET_EF(prog, ent, "nextthink", 0)
		SET_GI(prog, "self", ent)
		SET_GI(prog, "other", 0)
		prvm_edict.ExecuteProgram(prog, EI(prog, ent, "think"), "QC function self.think is missing")
		-- mods often set nextthink to time to cause a think every frame,
		-- we don't want to loop in that case, so exit if the new nextthink is
		-- <= the time the qc was told, also exit if it is past the end of the
		-- frame
		if
			EF(prog, ent, "nextthink") <= GF(prog, "time")
			or EF(prog, ent, "nextthink") > sv.time + sv.frametime
			or cvarint("sv_gameplayfix_multiplethinksperframe", 1) == 0
		then
			break
		end
		iterations += 1
	end
	return not prog.ed_free[ent]
end

--[[
==================
SV_Impact

Two entities have touched, so run their touch functions
==================
]]
-- port: sv_phys.c SV_Impact L1099-1139 @xonotic-v0.8.6 (trace.ent is set by the callers)
function sv_phys.SV_Impact(e1: number, trace: collision.trace_t)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local e2 = trace.ent :: number

	local old_self = GI(prog, "self")
	local old_other = GI(prog, "other")
	local restorevm_tempstringsbuf_cursize = prog.tempstringsbuf.cursize

	prvm_cmds.VM_SetTraceGlobals(prog, trace)

	if
		not prog.ed_free[e1]
		and not prog.ed_free[e2]
		and EI(prog, e1, "touch") ~= 0
		and EF(prog, e1, "solid") ~= SOLID_NOT
	then
		SET_GF(prog, "time", sv.time)
		SET_GI(prog, "self", e1)
		SET_GI(prog, "other", e2)
		prvm_edict.ExecuteProgram(prog, EI(prog, e1, "touch"), "QC function self.touch is missing")
	end

	if
		not prog.ed_free[e1]
		and not prog.ed_free[e2]
		and EI(prog, e2, "touch") ~= 0
		and EF(prog, e2, "solid") ~= SOLID_NOT
	then
		SET_GF(prog, "time", sv.time)
		SET_GI(prog, "self", e2)
		SET_GI(prog, "other", e1)
		local o = EV(prog, e2, "origin")
		SET_GV(prog, "trace_endpos", o[1], o[2], o[3])
		local n = trace.plane.normal
		SET_GV(prog, "trace_plane_normal", -n[1], -n[2], -n[3])
		SET_GF(prog, "trace_plane_dist", -trace.plane.dist)
		SET_GI(prog, "trace_ent", e1)
		SET_GF(prog, "trace_dpstartcontents", 0)
		SET_GF(prog, "trace_dphitcontents", 0)
		SET_GF(prog, "trace_dphitq3surfaceflags", 0)
		SET_GI(prog, "trace_dphittexturename", 0)
		prvm_edict.ExecuteProgram(prog, EI(prog, e2, "touch"), "QC function self.touch is missing")
	end

	SET_GI(prog, "self", old_self)
	SET_GI(prog, "other", old_other)
	prog.tempstringsbuf.cursize = restorevm_tempstringsbuf_cursize
end

--[[
==================
ClipVelocity

Slide off of the impacting object
returns the blocked flags (1 = floor, 2 = step / wall)
==================
]]
-- port: sv_phys.c ClipVelocity L1151-1162 @xonotic-v0.8.6 (in / out may be the same table, as in C)
function sv_phys.ClipVelocity(inv: { number }, normal: { number }, out: { number }, overbounce: number)
	local backoff = R(-DotProduct(inv, normal) * overbounce)
	-- VectorMA(in, backoff, normal, out)
	out[1] = R(inv[1] + R(backoff * normal[1]))
	out[2] = R(inv[2] + R(backoff * normal[2]))
	out[3] = R(inv[3] + R(backoff * normal[3]))

	for i = 1, 3 do
		if out[i] > -STOP_EPSILON and out[i] < STOP_EPSILON then
			out[i] = 0
		end
	end
end
local ClipVelocity = sv_phys.ClipVelocity

--[[
============
SV_FlyMove

The basic solid body movement clip that slides along multiple planes
Returns the clipflags if the velocity was modified (hit something solid)
1 = floor
2 = wall / step
4 = dead stop
8 = teleported by touch method
If stepnormal is not NULL, the plane normal of any vertical wall hit will be stored
============
]]
-- port: sv_phys.c SV_FlyMove L1181-1416 @xonotic-v0.8.6 (time and stepheight are float parameters: callers
-- round; stepnormal: a table or nil)
function sv_phys.SV_FlyMove(
	ent: number,
	time: number,
	applygravity: boolean,
	stepnormal: { number }?,
	_hitsupercontentsmask: number,
	_skipsupercontentsmask: number,
	_skipmaterialflagsmask: number,
	stepheight: number
): number
	local prog = cvar.prvm_prog_list[0]
	local blocked
	local numplanes
	local d, time_left, gravity
	local dir = { 0, 0, 0 }
	local push = { 0, 0, 0 }
	local planes = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
	local primal_velocity, original_velocity, restore_velocity
	local new_velocity = { 0, 0, 0 }
	local trace: collision.trace_t
	if time <= 0 then
		return 0
	end
	gravity = 0

	restore_velocity = EV(prog, ent, "velocity")

	if applygravity then
		gravity = sv_phys.SV_Gravity(ent)

		if cvarint("sv_gameplayfix_nogravityonground", 0) == 0 or not hasflag(EF(prog, ent, "flags"), FL_ONGROUND) then
			if cvarint("sv_gameplayfix_gravityunaffectedbyticrate", 0) ~= 0 then
				SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) - R(gravity * 0.5)))
			else
				SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) - gravity))
			end
		end
	end

	blocked = 0
	original_velocity = EV(prog, ent, "velocity")
	primal_velocity = EV(prog, ent, "velocity")
	numplanes = 0
	time_left = time
	for _bumpcount = 0, MAX_CLIP_PLANES - 1 do
		local vel = EV(prog, ent, "velocity")
		if vel[1] == 0 and vel[2] == 0 and vel[3] == 0 then
			break
		end

		push = { R(vel[1] * time_left), R(vel[2] * time_left), R(vel[3] * time_left) }
		local pushed
		pushed, trace = sv_phys.SV_PushEntity(ent, push, false)
		if not pushed then
			-- we got teleported by a touch function
			-- let's abort the move
			blocked = bit32.bor(blocked, 8)
			break
		end

		-- this code is used by MOVETYPE_WALK and MOVETYPE_STEP and SV_UnstickEntity
		-- abort move if we're stuck in the world (and didn't make it out)
		if trace.worldstartsolid and trace.allsolid then
			SET_EV(prog, ent, "velocity", restore_velocity)
			return 3
		end

		if trace.fraction == 1 then
			break
		end
		if trace.plane.normal[3] ~= 0 then
			if trace.plane.normal[3] > 0.7 then
				-- floor
				blocked = bit32.bor(blocked, 1)

				if trace.ent == nil then
					Con_Printf("SV_FlyMove: !trace.ent")
					trace.ent = 0
				end

				SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
				SET_EI(prog, ent, "groundentity", trace.ent)
			end
		elseif stepheight ~= 0 then
			-- step - handle it immediately
			--Con_Printf("step %f %f %f : ", PRVM_serveredictvector(ent, origin)[0], PRVM_serveredictvector(ent, origin)[1], PRVM_serveredictvector(ent, origin)[2]);
			local steppush = { 0, 0, stepheight }
			local org = EV(prog, ent, "origin")
			local ok = sv_phys.SV_PushEntity(ent, steppush, false)
			if not ok then
				blocked = bit32.bor(blocked, 8)
				break
			end
			--Con_Printf("%f %f %f : ", PRVM_serveredictvector(ent, origin)[0], PRVM_serveredictvector(ent, origin)[1], PRVM_serveredictvector(ent, origin)[2]);
			local steptrace2
			ok, steptrace2 = sv_phys.SV_PushEntity(ent, push, false)
			if not ok then
				blocked = bit32.bor(blocked, 8)
				break
			end
			--Con_Printf("%f %f %f : ", PRVM_serveredictvector(ent, origin)[0], PRVM_serveredictvector(ent, origin)[1], PRVM_serveredictvector(ent, origin)[2]);
			steppush = { 0, 0, R(org[3] - EVi(prog, ent, "origin", 3)) }
			ok = sv_phys.SV_PushEntity(ent, steppush, false)
			if not ok then
				blocked = bit32.bor(blocked, 8)
				break
			end
			--Con_Printf("%f %f %f : ", PRVM_serveredictvector(ent, origin)[0], PRVM_serveredictvector(ent, origin)[1], PRVM_serveredictvector(ent, origin)[2]);
			-- accept the new position if it made some progress...
			local o = EV(prog, ent, "origin")
			if math.abs(R(o[1] - org[1])) >= 0.03125 or math.abs(R(o[2] - org[2])) >= 0.03125 then
				--Con_Printf("accepted (delta %f %f %f)\n", PRVM_serveredictvector(ent, origin)[0] - org[0], PRVM_serveredictvector(ent, origin)[1] - org[1], PRVM_serveredictvector(ent, origin)[2] - org[2]);
				trace = steptrace2
				trace.endpos = { o[1], o[2], o[3] }
				time_left = R(time_left * (1 - trace.fraction))
				numplanes = 0
				continue
			else
				--Con_Printf("REJECTED (delta %f %f %f)\n", PRVM_serveredictvector(ent, origin)[0] - org[0], PRVM_serveredictvector(ent, origin)[1] - org[1], PRVM_serveredictvector(ent, origin)[2] - org[2]);
				SET_EV(prog, ent, "origin", org)
			end
		else
			-- step - return it to caller
			blocked = bit32.bor(blocked, 2)
			-- save the trace for player extrafriction
			if stepnormal then
				stepnormal[1], stepnormal[2], stepnormal[3] =
					trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3]
			end
		end
		if trace.fraction >= 0.001 then
			-- actually covered some distance
			original_velocity = EV(prog, ent, "velocity")
			numplanes = 0
		end

		time_left = R(time_left * (1 - trace.fraction))

		-- clipped to another plane
		if numplanes >= MAX_CLIP_PLANES then
			-- this shouldn't really happen
			SET_EV(prog, ent, "velocity", { 0, 0, 0 })
			blocked = 3
			break
		end

		--[[
		for (i = 0;i < numplanes;i++)
			if (DotProduct(trace.plane.normal, planes[i]) > 0.99)
				break;
		if (i < numplanes)
		{
			VectorAdd(PRVM_serveredictvector(ent, velocity), trace.plane.normal, PRVM_serveredictvector(ent, velocity));
			continue;
		}
		]]

		local p = planes[numplanes + 1]
		p[1], p[2], p[3] = trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3]
		numplanes += 1

		-- modify original_velocity so it parallels all of the clip planes
		local i = 0
		while i < numplanes do
			ClipVelocity(original_velocity, planes[i + 1], new_velocity, 1)
			local j = 0
			while j < numplanes do
				if j ~= i then
					-- not ok
					if DotProduct(new_velocity, planes[j + 1]) < 0 then
						break
					end
				end
				j += 1
			end
			if j == numplanes then
				break
			end
			i += 1
		end

		if i ~= numplanes then
			-- go along this plane
			SET_EV(prog, ent, "velocity", new_velocity)
		else
			-- go along the crease
			if numplanes ~= 2 then
				SET_EV(prog, ent, "velocity", { 0, 0, 0 })
				blocked = 7
				break
			end
			-- CrossProduct(planes[0], planes[1], dir)
			local a, b = planes[1], planes[2]
			dir[1] = R(R(a[2] * b[3]) - R(a[3] * b[2]))
			dir[2] = R(R(a[3] * b[1]) - R(a[1] * b[3]))
			dir[3] = R(R(a[1] * b[2]) - R(a[2] * b[1]))
			-- LordHavoc: thanks to taniwha of QuakeForge for pointing out this fix for slowed falling in corners
			mathlib.VectorNormalize(dir)
			d = DotProduct(dir, EV(prog, ent, "velocity"))
			SET_EV(prog, ent, "velocity", { R(dir[1] * d), R(dir[2] * d), R(dir[3] * d) })
		end

		-- if current velocity is against the original velocity,
		-- stop dead to avoid tiny occilations in sloping corners
		if DotProduct(EV(prog, ent, "velocity"), primal_velocity) <= 0 then
			SET_EV(prog, ent, "velocity", { 0, 0, 0 })
			break
		end
	end

	--Con_Printf("entity %i final: blocked %i velocity %f %f %f\n", ent - prog->edicts, blocked, PRVM_serveredictvector(ent, velocity)[0], PRVM_serveredictvector(ent, velocity)[1], PRVM_serveredictvector(ent, velocity)[2]);

	--[[
	if ((blocked & 1) == 0 && bumpcount > 1)
	{
		// LordHavoc: fix the 'fall to your death in a wedge corner' glitch
		// flag ONGROUND if there's ground under it
		trace = SV_TraceBox(PRVM_serveredictvector(ent, origin), PRVM_serveredictvector(ent, mins), PRVM_serveredictvector(ent, maxs), end, MOVE_NORMAL, ent, hitsupercontentsmask, skipsupercontentsmask, skipmaterialflagsmask);
	}
	]]

	-- LordHavoc: this came from QW and allows you to get out of water more easily
	if
		cvarint("sv_gameplayfix_easierwaterjump", 1) ~= 0
		and hasflag(EF(prog, ent, "flags"), FL_WATERJUMP)
		and bit32.band(blocked, 8) == 0
	then
		SET_EV(prog, ent, "velocity", primal_velocity)
	end

	if applygravity then
		if cvarint("sv_gameplayfix_nogravityonground", 0) == 0 or not hasflag(EF(prog, ent, "flags"), FL_ONGROUND) then
			if cvarint("sv_gameplayfix_gravityunaffectedbyticrate", 0) ~= 0 then
				SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) - R(gravity * 0.5)))
			end
		end
	end

	return blocked
end

--[[
============
SV_Gravity

============
]]
-- port: sv_phys.c SV_Gravity L1424-1433 @xonotic-v0.8.6
function sv_phys.SV_Gravity(ent: number): number
	local prog = cvar.prvm_prog_list[0]
	local ent_gravity = EF(prog, ent, "gravity")
	if ent_gravity == 0 then
		ent_gravity = 1.0
	end
	-- float * float, then * double sv.frametime, returned as float
	return R(R(ent_gravity * cvarval("sv_gravity", 800)) * server.sv.frametime)
end

--[[
===============================================================================

PUSHMOVE

===============================================================================
]]

-- port: sv_phys.c SV_NudgeOutOfSolid_PivotIsKnownGood L1444-1523 @xonotic-v0.8.6
function sv_phys.SV_NudgeOutOfSolid_PivotIsKnownGood(ent: number, pivot: { number }): boolean
	local prog = cvar.prvm_prog_list[0]
	local stuckorigin = EV(prog, ent, "origin")
	local stuckmins = EV(prog, ent, "mins")
	local stuckmaxs = EV(prog, ent, "maxs")
	local goodmins = { pivot[1], pivot[2], pivot[3] }
	local goodmaxs = { pivot[1], pivot[2], pivot[3] }
	for bump = 0, 5 do
		local coord = 2 - bit32.rshift(bump, 1) + 1 -- C index 2-(bump >> 1), as a Luau index
		--int coord = (bump >> 1);
		local dir = bit32.band(bump, 1)
		local subbump = 0

		while true do
			local testorigin = { stuckorigin[1], stuckorigin[2], stuckorigin[3] }
			if dir ~= 0 then
				-- pushing maxs
				testorigin[coord] = R(testorigin[coord] + R(stuckmaxs[coord] - goodmaxs[coord]))
			else
				-- pushing mins
				testorigin[coord] = R(testorigin[coord] + R(stuckmins[coord] - goodmins[coord]))
			end

			local stucktrace = sv_phys.SV_TraceBox(
				stuckorigin,
				goodmins,
				goodmaxs,
				testorigin,
				MOVE_NOMONSTERS,
				ent,
				sv_phys.SV_GenericHitSuperContentsMask(ent),
				0,
				0,
				collision.cv.collision_extendmovelength.value
			)
			if stucktrace.bmodelstartsolid then
				-- BAD BAD, can't fix that
				return false
			end

			if stucktrace.fraction >= 1 then
				break -- it WORKS!
			end

			if subbump >= 10 then
				-- BAD BAD, can't fix that
				return false
			end

			-- we hit something... let's move out of it
			-- VectorSubtract(stucktrace.endpos, testorigin, move): double - float, stored as float
			local move = {
				R(stucktrace.endpos[1] - testorigin[1]),
				R(stucktrace.endpos[2] - testorigin[2]),
				R(stucktrace.endpos[3] - testorigin[3]),
			}
			local nudge = R(DotProduct(stucktrace.plane.normal, move) + R(0.03125)) -- FIXME cvar this constant
			local n = stucktrace.plane.normal
			stuckorigin[1] = R(stuckorigin[1] + R(nudge * n[1]))
			stuckorigin[2] = R(stuckorigin[2] + R(nudge * n[2]))
			stuckorigin[3] = R(stuckorigin[3] + R(nudge * n[3]))
			subbump += 1
		end
		--[[
		if(subbump > 0)
			Con_Printf("subbump: %d\n", subbump);
		]]

		if dir ~= 0 then
			-- pushing maxs
			goodmaxs[coord] = stuckmaxs[coord]
		else
			-- pushing mins
			goodmins[coord] = stuckmins[coord]
		end
	end

	-- WE WIN
	SET_EV(prog, ent, "origin", stuckorigin)

	return true
end

--[[
============
SV_PushEntity

Does not change the entities velocity at all
The trace struct is filled with the trace that has been done.
Returns true if the push did not result in the entity being teleported by QC code.
============
]]
-- port: sv_phys.c SV_PushEntity L1574-1647 @xonotic-v0.8.6 (returns the qboolean and the trace)
function sv_phys.SV_PushEntity(ent: number, push: { number }, dolink: boolean): (boolean, collision.trace_t)
	local prog = cvar.prvm_prog_list[0]
	local marks = priv(prog, "ed_mark")
	local type

	local solid = toint(EF(prog, ent, "solid"))
	local movetype = toint(EF(prog, ent, "movetype"))
	local mins = EV(prog, ent, "mins")
	local maxs = EV(prog, ent, "maxs")

	-- move start position out of solids
	if
		cvarint("sv_gameplayfix_nudgeoutofsolid", 0) ~= 0
		and cvarval("sv_gameplayfix_nudgeoutofsolid_separation", 0.03125) >= 0
	then
		sv_phys.SV_NudgeOutOfSolid(ent)
	end

	local start = EV(prog, ent, "origin")
	local end_ = { R(start[1] + push[1]), R(start[2] + push[2]), R(start[3] + push[3]) }

	if movetype == MOVETYPE_FLYMISSILE then
		type = MOVE_MISSILE
	elseif movetype == MOVETYPE_FLY_WORLDONLY then
		type = MOVE_WORLDONLY
	elseif solid == SOLID_TRIGGER or solid == SOLID_NOT then
		type = MOVE_NOMONSTERS -- only clip against bmodels
	else
		type = MOVE_NORMAL
	end

	local trace = sv_phys.SV_TraceBox(
		start,
		mins,
		maxs,
		end_,
		type,
		ent,
		sv_phys.SV_GenericHitSuperContentsMask(ent),
		0,
		0,
		collision.cv.collision_extendmovelength.value
	)
	-- fail the move if stuck in world
	if trace.worldstartsolid then
		return true, trace
	end

	SET_EV(prog, ent, "origin", trace.endpos) -- double endpos stored as float

	marks[ent] = PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN -- -2: setorigin running

	sv_phys.SV_LinkEdict(ent)

	--[[ #if 0
	if(!trace->startsolid)
	if(SV_TraceBox(PRVM_serveredictvector(ent, origin), PRVM_serveredictvector(ent, mins), PRVM_serveredictvector(ent, maxs), PRVM_serveredictvector(ent, origin), type, ent, SV_GenericHitSuperContentsMask(ent), 0).startsolid)
	{
		Con_Printf("something eeeeevil happened\n");
	}
	#endif ]]

	if dolink then
		sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
	end

	if
		EF(prog, ent, "solid") >= SOLID_TRIGGER
		and trace.ent ~= nil
		and (not hasflag(EF(prog, ent, "flags"), FL_ONGROUND) or EI(prog, ent, "groundentity") ~= trace.ent)
	then
		sv_phys.SV_Impact(ent, trace)
	end

	local mark = marks[ent] or 0
	if mark == PRVM_EDICT_MARK_SETORIGIN_CAUGHT then
		marks[ent] = 0
		return false, trace
	elseif mark == PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN then
		marks[ent] = 0
		return true, trace
	else
		Con_Printf("The edict mark had been overwritten! Please debug this.\n")
		return true, trace
	end
end

-- static prvm_edict_t *checkentities[MAX_EDICTS] / static unsigned short moved_edicts[MAX_EDICTS]
local checkentities_PushMove: { number } = {}
local moved_edicts_PushMove: { number } = {}

--[[
============
SV_PushMove

============
]]
-- port: sv_phys.c SV_PushMove L1656-1958 @xonotic-v0.8.6 (movetime: float)
function sv_phys.SV_PushMove(pusher: number, movetime: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local mins, maxs, move = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local forward, left, up = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local checkentities = checkentities_PushMove
	local moved_edicts = moved_edicts_PushMove
	local pusherfinalmatrix, pusherfinalimatrix = matrixlib.new(), matrixlib.new()
	local forceupdate = priv(prog, "ed_waterposition_forceupdate")
	local extend = collision.cv.collision_extendmovelength.value

	local pv, pav = EV(prog, pusher, "velocity"), EV(prog, pusher, "avelocity")
	if pv[1] == 0 and pv[2] == 0 and pv[3] == 0 and pav[1] == 0 and pav[2] == 0 and pav[3] == 0 then
		SET_EF(prog, pusher, "ltime", R(EF(prog, pusher, "ltime") + movetime))
		return
	end

	-- VectorMA (origin, movetime, velocity, origin) and the same for angles / avelocity
	local function movepusher()
		local o, v = EV(prog, pusher, "origin"), EV(prog, pusher, "velocity")
		SET_EV(prog, pusher, "origin", {
			R(o[1] + R(movetime * v[1])),
			R(o[2] + R(movetime * v[2])),
			R(o[3] + R(movetime * v[3])),
		})
		local an, av = EV(prog, pusher, "angles"), EV(prog, pusher, "avelocity")
		SET_EV(prog, pusher, "angles", {
			R(an[1] + R(movetime * av[1])),
			R(an[2] + R(movetime * av[2])),
			R(an[3] + R(movetime * av[3])),
		})
	end
	-- angles[i] -= 360.0 * floor(angles[i] * (1.0 / 360.0)) (double, stored as float)
	local function anglemodpusher()
		for i = 1, 3 do
			local x = EVi(prog, pusher, "angles", i)
			SET_EVi(prog, pusher, "angles", i, R(x - 360.0 * math.floor(x * (1.0 / 360.0))))
		end
	end

	local solid = toint(EF(prog, pusher, "solid"))
	-- LordHavoc: valid pusher types
	-- selene: allow(empty_if)
	if solid == SOLID_BSP or solid == SOLID_BBOX or solid == SOLID_SLIDEBOX or solid == SOLID_CORPSE then
		-- SOLID_CORPSE: LordHavoc: this would be weird...
	elseif solid == SOLID_NOT or solid == SOLID_TRIGGER then
		-- LordHavoc: no collisions
		movepusher()
		anglemodpusher()
		SET_EF(prog, pusher, "ltime", R(EF(prog, pusher, "ltime") + movetime))
		sv_phys.SV_LinkEdict(pusher)
		return
	else
		Con_Printf("SV_PushMove: entity #%i, unrecognized solid type %f\n", pusher, EF(prog, pusher, "solid"))
		return
	end
	local index = toint(EF(prog, pusher, "modelindex"))
	if index < 1 or index >= MAX_MODELS then
		Con_Printf("SV_PushMove: entity #%i has an invalid modelindex %f\n", pusher, EF(prog, pusher, "modelindex"))
		return
	end
	local pushermodel = SV_GetModelByIndex(index)
	local pusherowner = EI(prog, pusher, "owner")
	local pusherprog = pusher

	local an, av = EV(prog, pusher, "angles"), EV(prog, pusher, "avelocity")
	local rotated = R(DotProduct(an, an) + DotProduct(av, av)) > 0

	local movetime2 = movetime
	pv = EV(prog, pusher, "velocity")
	local move1 = { R(pv[1] * movetime2), R(pv[2] * movetime2), R(pv[3] * movetime2) }
	local moveangle = { R(av[1] * movetime2), R(av[2] * movetime2), R(av[3] * movetime2) }
	-- the three C loops differ only in the model box they read
	local bmins, bmaxs
	if moveangle[1] ~= 0 or moveangle[3] ~= 0 then
		bmins, bmaxs = pushermodel.rotatedmins, pushermodel.rotatedmaxs
	elseif moveangle[2] ~= 0 then
		bmins, bmaxs = pushermodel.yawmins, pushermodel.yawmaxs
	else
		bmins, bmaxs = pushermodel.normalmins, pushermodel.normalmaxs
	end
	local po = EV(prog, pusher, "origin")
	for i = 1, 3 do
		if move1[i] > 0 then
			mins[i] = R(R(bmins[i] + po[i]) - 1)
			maxs[i] = R(R(R(bmaxs[i] + move1[i]) + po[i]) + 1)
		else
			mins[i] = R(R(R(bmins[i] + move1[i]) + po[i]) - 1)
			maxs[i] = R(R(bmaxs[i] + po[i]) + 1)
		end
	end

	local a = { -moveangle[1], -moveangle[2], -moveangle[3] }
	AngleVectorsFLU(a, forward, left, up)

	local pushorig = EV(prog, pusher, "origin")
	local pushang = EV(prog, pusher, "angles")
	local pushltime = EF(prog, pusher, "ltime")

	-- move the pusher to its final position

	movepusher()
	SET_EF(prog, pusher, "ltime", R(EF(prog, pusher, "ltime") + movetime))
	sv_phys.SV_LinkEdict(pusher)

	pushermodel = SV_GetModelFromEdict(pusher)
	po = EV(prog, pusher, "origin")
	local pa = EV(prog, pusher, "angles")
	matrixlib.Matrix4x4_CreateFromQuakeEntity(pusherfinalmatrix, po[1], po[2], po[3], pa[1], pa[2], pa[3], 1)
	matrixlib.Matrix4x4_Invert_Simple(pusherfinalimatrix, pusherfinalmatrix)

	local savesolid = EF(prog, pusher, "solid")

	-- see if any solid entities are inside the final position
	local num_moved = 0

	local numcheckentities
	if EF(prog, pusher, "movetype") == MOVETYPE_FAKEPUSH then -- Tenebrae's MOVETYPE_PUSH variant that doesn't push...
		numcheckentities = 0
	else -- MOVETYPE_PUSH
		numcheckentities = sv_phys.SV_EntitiesInBox(mins, maxs, MAX_EDICTS, checkentities)
	end
	-- Collision_ClipToGenericEntity of check against the pusher's final position (with the pusher's
	-- priv.server frameblend / skeleton as they are: the C does not regenerate them here)
	local function cliptopusher(check: number, checkcontents: number): collision.trace_t
		local trace = collision.newtrace()
		local pushermins = EV(prog, pusher, "mins")
		local pushermaxs = EV(prog, pusher, "maxs")
		local checkorigin = EV(prog, check, "origin")
		local checkmins = EV(prog, check, "mins")
		local checkmaxs = EV(prog, check, "maxs")
		local _, pusherframeblend, pusherskeleton = prvm_cmds.EdictFrameBlend(prog, pusher)
		collision.Collision_ClipToGenericEntity(
			trace,
			pushermodel,
			pusherframeblend,
			pusherskeleton,
			pushermins,
			pushermaxs,
			SUPERCONTENTS_BODY,
			pusherfinalmatrix,
			pusherfinalimatrix,
			checkorigin,
			checkmins,
			checkmaxs,
			checkorigin,
			checkcontents,
			0,
			0,
			extend
		)
		return trace
	end
	for e = 0, numcheckentities - 1 do
		local check = checkentities[e + 1]
		local movetype = toint(EF(prog, check, "movetype"))
		if
			movetype == MOVETYPE_NONE
			or movetype == MOVETYPE_PUSH
			or movetype == MOVETYPE_FOLLOW
			or movetype == MOVETYPE_NOCLIP
			or movetype == MOVETYPE_FLY_WORLDONLY
		then
			continue
		end

		if EI(prog, check, "owner") == pusherprog then
			continue
		end

		if pusherowner == check then
			continue
		end

		--Con_Printf("%i %s ", PRVM_NUM_FOR_EDICT(check), PRVM_GetString(PRVM_serveredictstring(check, classname)));

		-- tell any MOVETYPE_STEP entity that it may need to check for water transitions
		forceupdate[check] = true

		local checkcontents = sv_phys.SV_GenericHitSuperContentsMask(check)

		-- if the entity is standing on the pusher, it will definitely be moved
		-- if the entity is not standing on the pusher, but is in the pusher's
		-- final position, move it
		if not hasflag(EF(prog, check, "flags"), FL_ONGROUND) or EI(prog, check, "groundentity") ~= pusher then
			local trace = cliptopusher(check, checkcontents)
			--trace = SV_TraceBox(PRVM_serveredictvector(check, origin), PRVM_serveredictvector(check, mins), PRVM_serveredictvector(check, maxs), PRVM_serveredictvector(check, origin), MOVE_NOMONSTERS, check, checkcontents);
			if not trace.startsolid then
				--Con_Printf("- not in solid\n");
				continue
			end
		end

		-- VectorLerp(mins, 0.5f, maxs, pivot)
		local cmn, cmx = EV(prog, check, "mins"), EV(prog, check, "maxs")
		local pivot = {
			R(cmn[1] + R(0.5 * R(cmx[1] - cmn[1]))),
			R(cmn[2] + R(0.5 * R(cmx[2] - cmn[2]))),
			R(cmn[3] + R(0.5 * R(cmx[3] - cmn[3]))),
		}
		--VectorClear(pivot);

		if rotated then
			local co, pco = EV(prog, check, "origin"), EV(prog, pusher, "origin")
			local org = { R(co[1] - pco[1]), R(co[2] - pco[2]), R(co[3] - pco[3]) }
			org = { R(org[1] + pivot[1]), R(org[2] + pivot[2]), R(org[3] + pivot[3]) }
			local org2 = { DotProduct(org, forward), DotProduct(org, left), DotProduct(org, up) }
			move = { R(org2[1] - org[1]), R(org2[2] - org[2]), R(org2[3] - org[3]) }
			move = { R(move[1] + move1[1]), R(move[2] + move1[2]), R(move[3] + move1[3]) }
		else
			move = { move1[1], move1[2], move1[3] }
		end

		--Con_Printf("- pushing %f %f %f\n", move[0], move[1], move[2]);

		priv(prog, "ed_moved_from")[check] = EV(prog, check, "origin")
		priv(prog, "ed_moved_fromangles")[check] = EV(prog, check, "angles")
		moved_edicts[num_moved + 1] = check
		num_moved += 1

		-- physics objects need better collisions than this code can do
		if movetype == MOVETYPE_PHYSICS then
			local co = EV(prog, check, "origin")
			SET_EV(prog, check, "origin", { R(co[1] + move[1]), R(co[2] + move[2]), R(co[3] + move[3]) })
			sv_phys.SV_LinkEdict(check)
			sv_phys.SV_LinkEdict_TouchAreaGrid(check)
			continue
		end

		-- try moving the contacted entity
		SET_EF(prog, pusher, "solid", SOLID_NOT)
		local pushed, trace = sv_phys.SV_PushEntity(check, move, true)
		if not pushed then
			-- entity "check" got teleported
			-- angles[1] += trace.fraction * moveangle[1]: double, stored as float
			SET_EVi(prog, check, "angles", 2, R(EVi(prog, check, "angles", 2) + trace.fraction * moveangle[2]))
			SET_EF(prog, pusher, "solid", savesolid) -- was SOLID_BSP
			continue -- pushed enough
		end
		-- FIXME: turn players specially
		SET_EVi(prog, check, "angles", 2, R(EVi(prog, check, "angles", 2) + trace.fraction * moveangle[2]))
		SET_EF(prog, pusher, "solid", savesolid) -- was SOLID_BSP
		--Con_Printf("%s:%d frac %f startsolid %d bmodelstartsolid %d allsolid %d\n", __FILE__, __LINE__, trace.fraction, trace.startsolid, trace.bmodelstartsolid, trace.allsolid);

		-- this trace.fraction < 1 check causes items to fall off of pushers
		-- if they pass under or through a wall
		-- the groundentity check causes items to fall off of ledges
		if
			EF(prog, check, "movetype") ~= MOVETYPE_WALK
			and (trace.fraction < 1 or EI(prog, check, "groundentity") ~= pusher)
		then
			SET_EF(prog, check, "flags", andnotflag(EF(prog, check, "flags"), FL_ONGROUND))
		end

		-- if it is still inside the pusher, block
		trace = cliptopusher(check, checkcontents)
		if trace.startsolid then
			if sv_phys.SV_NudgeOutOfSolid_PivotIsKnownGood(check, pivot) then
				-- hack to invoke all necessary movement triggers
				local move2 = { 0, 0, 0 }
				if not sv_phys.SV_PushEntity(check, move2, true) then
					-- entity "check" got teleported
					continue
				end
				-- we could fix it
				continue
			end

			-- still inside pusher, so it's really blocked

			-- fail the move
			if EVi(prog, check, "mins", 1) == EVi(prog, check, "maxs", 1) then
				continue
			end
			if EF(prog, check, "solid") == SOLID_NOT or EF(prog, check, "solid") == SOLID_TRIGGER then
				-- corpse
				SET_EVi(prog, check, "mins", 2, 0)
				SET_EVi(prog, check, "mins", 1, 0)
				SET_EV(prog, check, "maxs", EV(prog, check, "mins"))
				continue
			end

			SET_EV(prog, pusher, "origin", pushorig)
			SET_EV(prog, pusher, "angles", pushang)
			SET_EF(prog, pusher, "ltime", pushltime)
			sv_phys.SV_LinkEdict(pusher)

			-- move back any entities we already moved
			for i = 0, num_moved - 1 do
				local ed = moved_edicts[i + 1]
				SET_EV(prog, ed, "origin", priv(prog, "ed_moved_from")[ed])
				SET_EV(prog, ed, "angles", priv(prog, "ed_moved_fromangles")[ed])
				sv_phys.SV_LinkEdict(ed)
			end

			-- if the pusher has a "blocked" function, call it, otherwise just stay in place until the obstacle is gone
			if EI(prog, pusher, "blocked") ~= 0 then
				SET_GF(prog, "time", sv.time)
				SET_GI(prog, "self", pusher)
				SET_GI(prog, "other", check)
				prvm_edict.ExecuteProgram(prog, EI(prog, pusher, "blocked"), "QC function self.blocked is missing")
			end
			break
		end
	end
	anglemodpusher()
end

--[[
================
SV_Physics_Pusher

================
]]
-- port: sv_phys.c SV_Physics_Pusher L1966-1995 @xonotic-v0.8.6
function sv_phys.SV_Physics_Pusher(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local movetime

	local oldltime = EF(prog, ent, "ltime")

	local thinktime = EF(prog, ent, "nextthink")
	if thinktime < EF(prog, ent, "ltime") + sv.frametime then
		movetime = R(thinktime - EF(prog, ent, "ltime"))
		if movetime < 0 then
			movetime = 0
		end
	else
		movetime = R(sv.frametime)
	end

	if movetime ~= 0 then
		-- advances PRVM_serveredictfloat(ent, ltime) if not blocked
		sv_phys.SV_PushMove(ent, movetime)
	end

	if thinktime > oldltime and thinktime <= EF(prog, ent, "ltime") then
		SET_EF(prog, ent, "nextthink", 0)
		SET_GF(prog, "time", sv.time)
		SET_GI(prog, "self", ent)
		SET_GI(prog, "other", 0)
		prvm_edict.ExecuteProgram(prog, EI(prog, ent, "think"), "QC function self.think is missing")
	end
end

--[[
===============================================================================

CLIENT MOVEMENT

===============================================================================
]]

-- sv_phys.c L2006-2021: static float unstickoffsets[] (C element i at [i + 1])
local unstickoffsets = {
	-- poutting -/+z changes first as they are least weird
	0,
	0,
	-1,
	0,
	0,
	1,
	-- x or y changes
	-1,
	0,
	0,
	1,
	0,
	0,
	0,
	-1,
	0,
	0,
	1,
	0,
	-- x and y changes
	-1,
	-1,
	0,
	1,
	-1,
	0,
	-1,
	1,
	0,
	1,
	1,
	0,
}

-- sv_phys.c L2023-2029 unstickresult_t
local UNSTICK_STUCK, UNSTICK_GOOD, UNSTICK_UNSTUCK = 0, 1, 2
sv_phys.UNSTICK_STUCK = UNSTICK_STUCK
sv_phys.UNSTICK_GOOD = UNSTICK_GOOD
sv_phys.UNSTICK_UNSTUCK = UNSTICK_UNSTUCK

-- port: sv_phys.c SV_UnstickEntityReturnOffset L2031-2074 @xonotic-v0.8.6 (offset: output vec3)
function sv_phys.SV_UnstickEntityReturnOffset(ent: number, offset: { number }): number
	local prog = cvar.prvm_prog_list[0]

	-- if not stuck in a bmodel, just return
	if not sv_phys.SV_TestEntityPosition(ent, { 0, 0, 0 }) then
		return UNSTICK_GOOD
	end

	local i = 0
	while i < #unstickoffsets do
		local o = { unstickoffsets[i + 1], unstickoffsets[i + 2], unstickoffsets[i + 3] }
		if not sv_phys.SV_TestEntityPosition(ent, o) then
			offset[1], offset[2], offset[3] = o[1], o[2], o[3]
			sv_phys.SV_LinkEdict(ent)
			--SV_LinkEdict_TouchAreaGrid(ent);
			return UNSTICK_UNSTUCK
		end
		i += 3
	end

	-- (int) of float - float times the double 0.36
	local maxunstick = toint(R(EVi(prog, ent, "maxs", 3) - EVi(prog, ent, "mins", 3)) * 0.36)
	-- magic number 0.36 allows unsticking by up to 17 units with the largest supported bbox

	for k = 2, maxunstick do
		offset[1], offset[2], offset[3] = 0, 0, 0
		offset[3] = -k
		if not sv_phys.SV_TestEntityPosition(ent, offset) then
			sv_phys.SV_LinkEdict(ent)
			--SV_LinkEdict_TouchAreaGrid(ent);
			return UNSTICK_UNSTUCK
		end
		offset[3] = k
		if not sv_phys.SV_TestEntityPosition(ent, offset) then
			sv_phys.SV_LinkEdict(ent)
			--SV_LinkEdict_TouchAreaGrid(ent);
			return UNSTICK_UNSTUCK
		end
	end

	return UNSTICK_STUCK
end

-- port: sv_phys.c SV_UnstickEntity L2076-2095 @xonotic-v0.8.6
function sv_phys.SV_UnstickEntity(ent: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local offset = { 0, 0, 0 }
	local r = sv_phys.SV_UnstickEntityReturnOffset(ent, offset)
	if r == UNSTICK_GOOD then
		return true
	elseif r == UNSTICK_UNSTUCK then
		Con_DPrintf(
			'Unstuck entity %i (classname "%s") with offset %f %f %f.\n',
			ent,
			classname(prog, ent),
			offset[1],
			offset[2],
			offset[3]
		)
		return true
	elseif r == UNSTICK_STUCK then
		if cvarint("developer_extra", 0) ~= 0 then
			Con_DPrintf('Stuck entity %i (classname "%s").\n', ent, classname(prog, ent))
		end
		return false
	else
		Con_Printf("SV_UnstickEntityReturnOffset returned a value outside its enum.\n")
		return false
	end
end

--[[
=============
SV_CheckStuck

This is a big hack to try and fix the rare case of getting stuck in the world
clipping hull.
=============
]]
-- port: sv_phys.c SV_CheckStuck L2105-2132 @xonotic-v0.8.6
function sv_phys.SV_CheckStuck(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local offset = { 0, 0, 0 }

	local r = sv_phys.SV_UnstickEntityReturnOffset(ent, offset)
	if r == UNSTICK_GOOD then
		SET_EV(prog, ent, "oldorigin", EV(prog, ent, "origin"))
	elseif r == UNSTICK_UNSTUCK then
		Con_DPrintf(
			'Unstuck player entity %i (classname "%s") with offset %f %f %f.\n',
			ent,
			classname(prog, ent),
			offset[1],
			offset[2],
			offset[3]
		)
	elseif r == UNSTICK_STUCK then
		local oo, o = EV(prog, ent, "oldorigin"), EV(prog, ent, "origin")
		offset = { R(oo[1] - o[1]), R(oo[2] - o[2]), R(oo[3] - o[3]) }
		if not sv_phys.SV_TestEntityPosition(ent, offset) then
			Con_DPrintf(
				'Unstuck player entity %i (classname "%s") by restoring oldorigin.\n',
				ent,
				classname(prog, ent)
			)
			sv_phys.SV_LinkEdict(ent)
			--SV_LinkEdict_TouchAreaGrid(ent);
		else
			Con_DPrintf('Stuck player entity %i (classname "%s").\n', ent, classname(prog, ent))
		end
	else
		Con_Printf("SV_UnstickEntityReturnOffset returned a value outside its enum.\n")
	end
end

--[[
=============
SV_CheckWater
=============
]]
-- port: sv_phys.c SV_CheckWater L2140-2184 @xonotic-v0.8.6
function sv_phys.SV_CheckWater(ent: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local point = { 0, 0, 0 }

	point[1] = EVi(prog, ent, "origin", 1)
	point[2] = EVi(prog, ent, "origin", 2)
	point[3] = R(R(EVi(prog, ent, "origin", 3) + EVi(prog, ent, "mins", 3)) + 1)

	-- DRESK - Support for Entity Contents Transition Event
	-- NOTE: Some logic needed to be slightly re-ordered
	-- to not affect performance and allow for the feature.

	-- Acquire Super Contents Prior to Resets
	local cont = sv_phys.SV_PointSuperContents(point)
	-- Acquire Native Contents Here
	local nNativeContents = Mod_Q1BSP_NativeContentsFromSuperContents(cont)

	-- DRESK - Support for Entity Contents Transition Event
	if EF(prog, ent, "watertype") ~= 0 then
		-- Entity did NOT Spawn; Check
		sv_phys.SV_CheckContentsTransition(ent, nNativeContents)
	end

	SET_EF(prog, ent, "waterlevel", 0)
	SET_EF(prog, ent, "watertype", CONTENTS_EMPTY)
	cont = sv_phys.SV_PointSuperContents(point)
	if bit32.band(cont, SUPERCONTENTS_LIQUIDSMASK) ~= 0 then
		SET_EF(prog, ent, "watertype", nNativeContents)
		SET_EF(prog, ent, "waterlevel", 1)
		-- origin + (mins + maxs) * 0.5: the float sum times a double, stored as float
		point[3] = R(EVi(prog, ent, "origin", 3) + R(EVi(prog, ent, "mins", 3) + EVi(prog, ent, "maxs", 3)) * 0.5)
		if bit32.band(sv_phys.SV_PointSuperContents(point), SUPERCONTENTS_LIQUIDSMASK) ~= 0 then
			SET_EF(prog, ent, "waterlevel", 2)
			point[3] = R(EVi(prog, ent, "origin", 3) + EVi(prog, ent, "view_ofs", 3))
			if bit32.band(sv_phys.SV_PointSuperContents(point), SUPERCONTENTS_LIQUIDSMASK) ~= 0 then
				SET_EF(prog, ent, "waterlevel", 3)
			end
		end
	end

	return EF(prog, ent, "waterlevel") > 1
end

--[[
============
SV_WallFriction

============
]]
-- port: sv_phys.c SV_WallFriction L2192-2209 @xonotic-v0.8.6
function sv_phys.SV_WallFriction(ent: number, stepnormal: { number })
	local prog = cvar.prvm_prog_list[0]
	local forward = { 0, 0, 0 }

	local v_angle = EV(prog, ent, "v_angle")
	mathlib.AngleVectors(v_angle, forward, nil, nil)
	-- d = DotProduct (stepnormal, forward) + 0.5: float + double, stored in the float d
	local d = R(DotProduct(stepnormal, forward) + 0.5)
	if d < 0 then
		-- cut the tangential velocity
		local vel = EV(prog, ent, "velocity")
		local i = DotProduct(stepnormal, vel)
		local into = { R(stepnormal[1] * i), R(stepnormal[2] * i), R(stepnormal[3] * i) }
		local side = { R(vel[1] - into[1]), R(vel[2] - into[2]), R(vel[3] - into[3]) }
		SET_EVi(prog, ent, "velocity", 1, R(side[1] * R(1 + d)))
		SET_EVi(prog, ent, "velocity", 2, R(side[2] * R(1 + d)))
	end
end

--[[ #if 0: SV_TryUnstick (sv_phys.c L2211-2271) is not compiled ]]

--[[
=====================
SV_WalkMove

Only used by players
======================
]]
-- port: sv_phys.c SV_WalkMove L2280-2477 @xonotic-v0.8.6
function sv_phys.SV_WalkMove(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local clip
	--int originalmove_clip;
	local hitsupercontentsmask = sv_phys.SV_GenericHitSuperContentsMask(ent)
	local skipsupercontentsmask = 0
	local skipmaterialflagsmask = 0
	local type
	-- C leaves stepnormal uninitialized; it is only read after a SV_FlyMove that returned bit 2
	local stepnormal = { 0, 0, 0 }
	local trace: collision.trace_t

	-- if frametime is 0 (due to client sending the same timestamp twice),
	-- don't move
	if sv.frametime <= 0 then
		return
	end

	if cvarint("sv_gameplayfix_unstickplayers", 1) ~= 0 then
		sv_phys.SV_CheckStuck(ent)
	end

	local applygravity = not sv_phys.SV_CheckWater(ent)
		and EF(prog, ent, "movetype") == MOVETYPE_WALK
		and not hasflag(EF(prog, ent, "flags"), FL_WATERJUMP)

	sv_phys.SV_CheckVelocity(ent)

	-- do a regular slide move unless it looks like you ran into a step
	local oldonground = bit32.band(toint(EF(prog, ent, "flags")), FL_ONGROUND)

	local start_origin = EV(prog, ent, "origin")
	local start_velocity = EV(prog, ent, "velocity")

	clip = sv_phys.SV_FlyMove(
		ent,
		R(sv.frametime),
		applygravity,
		nil,
		hitsupercontentsmask,
		skipsupercontentsmask,
		skipmaterialflagsmask,
		if cvarint("sv_gameplayfix_stepmultipletimes", 0) ~= 0 then cvarval("sv_stepheight", 18) else 0
	)

	if cvarint("sv_gameplayfix_downtracesupportsongroundflag", 1) ~= 0 then
		if bit32.band(clip, 1) == 0 then
			-- only try this if there was no floor in the way in the trace (no,
			-- this check seems to be not REALLY necessary, because if clip & 1,
			-- our trace will hit that thing too)
			local o = EV(prog, ent, "origin")
			local upmove = { o[1], o[2], R(o[3] + 1) }
			local downmove = { o[1], o[2], R(o[3] - 1) }
			if EF(prog, ent, "movetype") == MOVETYPE_FLYMISSILE then
				type = MOVE_MISSILE
			elseif EF(prog, ent, "movetype") == MOVETYPE_FLY_WORLDONLY then
				type = MOVE_WORLDONLY
			elseif EF(prog, ent, "solid") == SOLID_TRIGGER or EF(prog, ent, "solid") == SOLID_NOT then
				type = MOVE_NOMONSTERS -- only clip against bmodels
			else
				type = MOVE_NORMAL
			end
			local entmins = EV(prog, ent, "mins")
			local entmaxs = EV(prog, ent, "maxs")
			trace = sv_phys.SV_TraceBox(
				upmove,
				entmins,
				entmaxs,
				downmove,
				type,
				ent,
				sv_phys.SV_GenericHitSuperContentsMask(ent),
				skipsupercontentsmask,
				skipmaterialflagsmask,
				collision.cv.collision_extendmovelength.value
			)
			if trace.fraction < 1 and trace.plane.normal[3] > 0.7 then
				clip = bit32.bor(clip, 1) -- but we HAVE found a floor
			end
		end
	end

	-- if the move did not hit the ground at any point, we're not on ground
	if bit32.band(clip, 1) == 0 then
		SET_EF(prog, ent, "flags", andnotflag(EF(prog, ent, "flags"), FL_ONGROUND))
	end

	sv_phys.SV_CheckVelocity(ent)
	sv_phys.SV_LinkEdict(ent)
	sv_phys.SV_LinkEdict_TouchAreaGrid(ent)

	if bit32.band(clip, 8) ~= 0 then -- teleport
		return
	end

	if hasflag(EF(prog, ent, "flags"), FL_WATERJUMP) then
		return
	end

	if cvarint("sv_nostep", 0) ~= 0 then
		return
	end

	local originalmove_origin = EV(prog, ent, "origin")
	local originalmove_velocity = EV(prog, ent, "velocity")
	--originalmove_clip = clip;
	local originalmove_flags = toint(EF(prog, ent, "flags"))
	local originalmove_groundentity = EI(prog, ent, "groundentity")

	-- if move didn't block on a step, return
	if bit32.band(clip, 2) ~= 0 then
		-- if move was not trying to move into the step, return
		if math.abs(start_velocity[1]) < 0.03125 and math.abs(start_velocity[2]) < 0.03125 then
			return
		end

		if EF(prog, ent, "movetype") ~= MOVETYPE_FLY then
			-- return if gibbed by a trigger
			if EF(prog, ent, "movetype") ~= MOVETYPE_WALK then
				return
			end

			-- return if attempting to jump while airborn (unless sv_jumpstep)
			if cvarint("sv_jumpstep", 0) == 0 then
				if oldonground == 0 and EF(prog, ent, "waterlevel") == 0 then
					return
				end
			end
		end

		-- try moving up and forward to go up a step
		-- back to start pos
		SET_EV(prog, ent, "origin", start_origin)
		SET_EV(prog, ent, "velocity", start_velocity)

		-- move up
		local upmove = { 0, 0, 0 }
		upmove[3] = cvarval("sv_stepheight", 18)
		if not sv_phys.SV_PushEntity(ent, upmove, true) then
			-- we got teleported when upstepping... must abort the move
			return
		end

		-- move forward
		SET_EVi(prog, ent, "velocity", 3, 0)
		clip = sv_phys.SV_FlyMove(
			ent,
			R(sv.frametime),
			applygravity,
			stepnormal,
			hitsupercontentsmask,
			skipsupercontentsmask,
			skipmaterialflagsmask,
			0
		)
		SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) + start_velocity[3]))
		if bit32.band(clip, 8) ~= 0 then
			-- we got teleported when upstepping... must abort the move
			-- note that z velocity handling may not be what QC expects here, but we cannot help it
			return
		end

		sv_phys.SV_CheckVelocity(ent)
		sv_phys.SV_LinkEdict(ent)
		sv_phys.SV_LinkEdict_TouchAreaGrid(ent)

		-- check for stuckness, possibly due to the limited precision of floats
		-- in the clipping hulls
		if
			clip ~= 0
			and math.abs(R(originalmove_origin[2] - EVi(prog, ent, "origin", 2))) < 0.03125
			and math.abs(R(originalmove_origin[1] - EVi(prog, ent, "origin", 1))) < 0.03125
		then
			--Con_Printf("wall\n");
			-- stepping up didn't make any progress, revert to original move
			SET_EV(prog, ent, "origin", originalmove_origin)
			SET_EV(prog, ent, "velocity", originalmove_velocity)
			--clip = originalmove_clip;
			SET_EF(prog, ent, "flags", originalmove_flags)
			SET_EI(prog, ent, "groundentity", originalmove_groundentity)
			-- now try to unstick if needed
			--clip = SV_TryUnstick (ent, oldvel);
			return
		end

		--Con_Printf("step - ");

		-- extra friction based on view angle
		if bit32.band(clip, 2) ~= 0 and cvarint("sv_wallfriction", 1) ~= 0 then
			sv_phys.SV_WallFriction(ent, stepnormal)
		end
	-- don't do the down move if stepdown is disabled, moving upward, not in water, or the move started offground or ended onground
	elseif
		cvarint("sv_gameplayfix_stepdown", 0) == 0
		or EF(prog, ent, "waterlevel") >= 3
		or start_velocity[3] >= (1.0 / 32.0)
		or oldonground == 0
		or hasflag(EF(prog, ent, "flags"), FL_ONGROUND)
	then
		return
	end

	-- move down
	local downmove = { 0, 0, 0 }
	-- -sv_stepheight.value + start_velocity[2]*sv.frametime: float + double, stored as float
	downmove[3] = R(-cvarval("sv_stepheight", 18) + start_velocity[3] * sv.frametime)
	local pushed, downtrace = sv_phys.SV_PushEntity(ent, downmove, true)
	if not pushed then
		-- we got teleported when downstepping... must abort the move
		return
	end

	-- selene: allow(empty_if)
	if downtrace.fraction < 1 and downtrace.plane.normal[3] > 0.7 then
		-- this has been disabled so that you can't jump when you are stepping
		-- up while already jumping (also known as the Quake2 double jump bug)
		--[[ #if 0
		// LordHavoc: disabled this check so you can walk on monsters/players
		//if (PRVM_serveredictfloat(ent, solid) == SOLID_BSP)
		{
			//Con_Printf("onground\n");
			PRVM_serveredictfloat(ent, flags) =	(int)PRVM_serveredictfloat(ent, flags) | FL_ONGROUND;
			PRVM_serveredictedict(ent, groundentity) = PRVM_EDICT_TO_PROG(downtrace.ent);
		}
		#endif ]]
	else
		--Con_Printf("slope\n");
		-- if the push down didn't end up on good ground, use the move without
		-- the step up.  This happens near wall / slope combinations, and can
		-- cause the player to hop up higher on a slope too steep to climb
		SET_EV(prog, ent, "origin", originalmove_origin)
		SET_EV(prog, ent, "velocity", originalmove_velocity)
		--clip = originalmove_clip;
		SET_EF(prog, ent, "flags", originalmove_flags)
		SET_EI(prog, ent, "groundentity", originalmove_groundentity)
	end

	sv_phys.SV_CheckVelocity(ent)
	sv_phys.SV_LinkEdict(ent)
	sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
end

--============================================================================

--[[
=============
SV_Physics_Follow

Entities that are "stuck" to another entity
=============
]]
-- port: sv_phys.c SV_Physics_Follow L2488-2521 @xonotic-v0.8.6
function sv_phys.SV_Physics_Follow(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local vf, vr, vu = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local angles, v = { 0, 0, 0 }, { 0, 0, 0 }

	-- LordHavoc: implemented rotation on MOVETYPE_FOLLOW objects
	local e = EI(prog, ent, "aiment")
	local ea, pa = EV(prog, e, "angles"), EV(prog, ent, "punchangle")
	if ea[1] == pa[1] and ea[2] == pa[2] and ea[3] == pa[3] then
		-- quick case for no rotation
		local eo, vo = EV(prog, e, "origin"), EV(prog, ent, "view_ofs")
		SET_EV(prog, ent, "origin", { R(eo[1] + vo[1]), R(eo[2] + vo[2]), R(eo[3] + vo[3]) })
	else
		angles[1] = -pa[1]
		angles[2] = pa[2]
		angles[3] = pa[3]
		mathlib.AngleVectors(angles, vf, vr, vu)
		local vo = EV(prog, ent, "view_ofs")
		v[1] = R(R(R(vo[1] * vf[1]) + R(vo[2] * vr[1])) + R(vo[3] * vu[1]))
		v[2] = R(R(R(vo[1] * vf[2]) + R(vo[2] * vr[2])) + R(vo[3] * vu[2]))
		v[3] = R(R(R(vo[1] * vf[3]) + R(vo[2] * vr[3])) + R(vo[3] * vu[3]))
		angles[1] = -ea[1]
		angles[2] = ea[2]
		angles[3] = ea[3]
		mathlib.AngleVectors(angles, vf, vr, vu)
		local eo = EV(prog, e, "origin")
		SET_EV(prog, ent, "origin", {
			R(R(R(R(v[1] * vf[1]) + R(v[2] * vf[2])) + R(v[3] * vf[3])) + eo[1]),
			R(R(R(R(v[1] * vr[1]) + R(v[2] * vr[2])) + R(v[3] * vr[3])) + eo[2]),
			R(R(R(R(v[1] * vu[1]) + R(v[2] * vu[2])) + R(v[3] * vu[3])) + eo[3]),
		})
	end
	ea = EV(prog, e, "angles")
	local va = EV(prog, ent, "v_angle")
	SET_EV(prog, ent, "angles", { R(ea[1] + va[1]), R(ea[2] + va[2]), R(ea[3] + va[3]) })
	sv_phys.SV_LinkEdict(ent)
	--SV_LinkEdict_TouchAreaGrid(ent);
end

--[[
==============================================================================

TOSS / BOUNCE

==============================================================================
]]

--[[
=============
SV_CheckWaterTransition

=============
]]
-- port: sv_phys.c SV_CheckWaterTransition L2537-2576 @xonotic-v0.8.6
function sv_phys.SV_CheckWaterTransition(ent: number)
	local prog = cvar.prvm_prog_list[0]
	-- LordHavoc: bugfixes in this function are keyed to the sv_gameplayfix_bugfixedcheckwatertransition cvar - if this cvar is 0 then all the original bugs should be reenabled for compatibility
	local entorigin = EV(prog, ent, "origin")
	local cont = Mod_Q1BSP_NativeContentsFromSuperContents(sv_phys.SV_PointSuperContents(entorigin))
	local fixed = cvarint("sv_gameplayfix_fixedcheckwatertransition", 1)
	if EF(prog, ent, "watertype") == 0 then
		-- just spawned here
		if fixed == 0 then
			SET_EF(prog, ent, "watertype", cont)
			SET_EF(prog, ent, "waterlevel", 1)
			return
		end
	-- DRESK - Support for Entity Contents Transition Event
	-- NOTE: Call here BEFORE updating the watertype below,
	-- and suppress watersplash sound if a valid function
	-- call was made to allow for custom "splash" sounds.
	elseif not sv_phys.SV_CheckContentsTransition(ent, cont) then
		-- Contents Transition Function Invalid; Potentially Play Water Sound
		-- check if the entity crossed into or out of water
		-- engine quirk kept: sv_sound_watersplash.string is a pointer, never NULL, so an empty cvar still
		-- reaches SV_StartSound
		local wt = EF(prog, ent, "watertype")
		if (wt == CONTENTS_WATER or wt == CONTENTS_SLIME) ~= (cont == CONTENTS_WATER or cont == CONTENTS_SLIME) then
			SV_StartSound_cvar(ent, 0, cvarstr("sv_sound_watersplash", "misc/h2ohit1.wav"))
		end
	end

	if cont <= CONTENTS_WATER then
		SET_EF(prog, ent, "watertype", cont)
		SET_EF(prog, ent, "waterlevel", 1)
	else
		SET_EF(prog, ent, "watertype", CONTENTS_EMPTY)
		SET_EF(prog, ent, "waterlevel", if fixed ~= 0 then 0 else cont)
	end
end

--[[
=============
SV_Physics_Toss

Toss, bounce, and fly movement.  When onground, do nothing.
=============
]]

-- port: sv_phys.c SV_Physics_Toss L2586-2728 @xonotic-v0.8.6
function sv_phys.SV_Physics_Toss(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local suspended = priv(prog, "ed_suspendedinairflag")
	local trace: collision.trace_t
	local move
	local movetime
	local d, ent_gravity
	local bouncefactor
	local bouncestop

	-- if onground, return without moving
	if hasflag(EF(prog, ent, "flags"), FL_ONGROUND) then
		local groundentity = EI(prog, ent, "groundentity")
		if
			EVi(prog, ent, "velocity", 3) >= (1.0 / 32.0)
			and cvarint("sv_gameplayfix_upwardvelocityclearsongroundflag", 1) ~= 0
		then
			-- don't stick to ground if onground and moving upward
			SET_EF(prog, ent, "flags", R(EF(prog, ent, "flags") - FL_ONGROUND))
		elseif EI(prog, ent, "groundentity") == 0 or cvarint("sv_gameplayfix_noairborncorpse", 1) == 0 then
			-- we can trust FL_ONGROUND if groundentity is world because it never moves
			return
		elseif suspended[ent] and prog.ed_free[groundentity] then
			-- if ent was supported by a brush model on previous frame,
			-- and groundentity is now freed, set groundentity to 0 (world)
			-- which leaves it suspended in the air
			SET_EI(prog, ent, "groundentity", 0)
			if cvarint("sv_gameplayfix_noairborncorpse_allowsuspendeditems", 1) ~= 0 then
				return
			end
		else
			local a, b = privvec(prog, "ed_cullmins", ent), privvec(prog, "ed_cullmaxs", ent)
			local c, dd = privvec(prog, "ed_cullmins", groundentity), privvec(prog, "ed_cullmaxs", groundentity)
			-- BoxesOverlap(ent cullmins, ent cullmaxs, groundentity cullmins, groundentity cullmaxs)
			if a[1] <= dd[1] and b[1] >= c[1] and a[2] <= dd[2] and b[2] >= c[2] and a[3] <= dd[3] and b[3] >= c[3] then
				-- don't slide if still touching the groundentity
				return
			end
		end
	end
	suspended[ent] = false

	sv_phys.SV_CheckVelocity(ent)

	-- add gravity
	if EF(prog, ent, "movetype") == MOVETYPE_TOSS or EF(prog, ent, "movetype") == MOVETYPE_BOUNCE then
		SET_EVi(prog, ent, "velocity", 3, R(EVi(prog, ent, "velocity", 3) - sv_phys.SV_Gravity(ent)))
	end

	-- move angles
	-- VectorMA (angles, sv.frametime, avelocity, angles): float + double * float, stored as float
	local an, av = EV(prog, ent, "angles"), EV(prog, ent, "avelocity")
	SET_EV(prog, ent, "angles", {
		R(an[1] + sv.frametime * av[1]),
		R(an[2] + sv.frametime * av[2]),
		R(an[3] + sv.frametime * av[3]),
	})

	movetime = R(sv.frametime)
	local bump = 0
	while bump < MAX_CLIP_PLANES and movetime > 0 do
		-- move origin
		local vel = EV(prog, ent, "velocity")
		move = { R(vel[1] * movetime), R(vel[2] * movetime), R(vel[3] * movetime) }
		local pushed
		pushed, trace = sv_phys.SV_PushEntity(ent, move, true)
		if not pushed then
			return -- teleported
		end
		if prog.ed_free[ent] then
			return
		end
		if trace.bmodelstartsolid and cvarint("sv_gameplayfix_unstickentities", 1) ~= 0 then
			-- try to unstick the entity
			sv_phys.SV_UnstickEntity(ent)
			pushed, trace = sv_phys.SV_PushEntity(ent, move, true)
			if not pushed then
				return -- teleported
			end
			if prog.ed_free[ent] then
				return
			end
		end
		if trace.fraction == 1 then
			break
		end
		-- movetime *= 1 - min(1, trace.fraction): double, stored as float
		movetime = R(movetime * (1 - cmin(1, trace.fraction)))
		local mt = toint(EF(prog, ent, "movetype"))
		if mt == MOVETYPE_BOUNCEMISSILE then
			bouncefactor = EF(prog, ent, "bouncefactor")
			if bouncefactor == 0 then
				bouncefactor = 1.0
			end

			local v = EV(prog, ent, "velocity")
			ClipVelocity(v, trace.plane.normal, v, R(1 + bouncefactor))
			SET_EV(prog, ent, "velocity", v)
			SET_EF(prog, ent, "flags", andnotflag(EF(prog, ent, "flags"), FL_ONGROUND))
			if cvarint("sv_gameplayfix_slidemoveprojectiles", 1) == 0 then
				movetime = 0
			end
		elseif mt == MOVETYPE_BOUNCE then
			bouncefactor = EF(prog, ent, "bouncefactor")
			if bouncefactor == 0 then
				bouncefactor = 0.5
			end

			bouncestop = EF(prog, ent, "bouncestop")
			if bouncestop == 0 then
				bouncestop = R(60.0 / 800.0) -- 60.0f / 800.0f
			end

			local v = EV(prog, ent, "velocity")
			ClipVelocity(v, trace.plane.normal, v, R(1 + bouncefactor))
			SET_EV(prog, ent, "velocity", v)
			ent_gravity = EF(prog, ent, "gravity")
			if ent_gravity == 0 then
				ent_gravity = 1.0
			end
			-- LordHavoc: fixed grenades not bouncing when fired down a slope
			if cvarint("sv_gameplayfix_grenadebouncedownslopes", 1) ~= 0 then
				d = math.abs(DotProduct(trace.plane.normal, EV(prog, ent, "velocity")))
			else
				d = EVi(prog, ent, "velocity", 3)
			end
			if trace.plane.normal[3] > 0.7 and d < R(R(cvarval("sv_gravity", 800) * bouncestop) * ent_gravity) then
				SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
				SET_EI(prog, ent, "groundentity", trace.ent or 0)
				SET_EV(prog, ent, "velocity", { 0, 0, 0 })
				SET_EV(prog, ent, "avelocity", { 0, 0, 0 })
				movetime = 0
			else
				SET_EF(prog, ent, "flags", andnotflag(EF(prog, ent, "flags"), FL_ONGROUND))
				if cvarint("sv_gameplayfix_slidemoveprojectiles", 1) == 0 then
					movetime = 0
				end
			end
		else
			local v = EV(prog, ent, "velocity")
			ClipVelocity(v, trace.plane.normal, v, 1.0)
			SET_EV(prog, ent, "velocity", v)
			if trace.plane.normal[3] > 0.7 then
				SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
				SET_EI(prog, ent, "groundentity", trace.ent or 0)
				if EF(prog, trace.ent or 0, "solid") == SOLID_BSP then
					suspended[ent] = true
				end
				SET_EV(prog, ent, "velocity", { 0, 0, 0 })
				SET_EV(prog, ent, "avelocity", { 0, 0, 0 })
				movetime = 0
			else
				SET_EF(prog, ent, "flags", andnotflag(EF(prog, ent, "flags"), FL_ONGROUND))
				if cvarint("sv_gameplayfix_slidemoveprojectiles", 1) == 0 then
					movetime = 0
				end
			end
		end
		bump += 1
	end

	-- check for in water
	sv_phys.SV_CheckWaterTransition(ent)
end

--[[
===============================================================================

STEPPING MOVEMENT

===============================================================================
]]

--[[
=============
SV_Physics_Step

Monsters freefall when they don't have a ground entity, otherwise
all movement is done with discrete steps.

This is also used for objects that have become still on the ground, but
will fall if the floor is pulled out from under them.
=============
]]
-- port: sv_phys.c SV_Physics_Step L2749-2812 @xonotic-v0.8.6
function sv_phys.SV_Physics_Step(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local forceupdate = priv(prog, "ed_waterposition_forceupdate")
	local flags = toint(EF(prog, ent, "flags"))

	-- DRESK
	-- Backup Velocity in the event that movetypesteplandevent is called,
	-- to provide a parameter with the entity's velocity at impact.
	local backupVelocity = EV(prog, ent, "velocity")
	-- don't fall at all if fly/swim
	if bit32.band(flags, bit32.bor(FL_FLY, FL_SWIM)) == 0 then
		if bit32.band(flags, FL_ONGROUND) ~= 0 then
			-- freefall if onground and moving upward
			-- freefall if not standing on a world surface (it may be a lift or trap door)
			if
				EVi(prog, ent, "velocity", 3) >= (1.0 / 32.0)
				and cvarint("sv_gameplayfix_upwardvelocityclearsongroundflag", 1) ~= 0
			then
				SET_EF(prog, ent, "flags", R(EF(prog, ent, "flags") - FL_ONGROUND))
				sv_phys.SV_CheckVelocity(ent)
				sv_phys.SV_FlyMove(
					ent,
					R(sv.frametime),
					true,
					nil,
					sv_phys.SV_GenericHitSuperContentsMask(ent),
					0,
					0,
					0
				)
				sv_phys.SV_LinkEdict(ent)
				sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
				forceupdate[ent] = true
			end
		else
			-- freefall if not onground
			-- velocity[2] < sv_gravity.value * -0.1: float times double, compared in double
			local hitsound = EVi(prog, ent, "velocity", 3) < cvarval("sv_gravity", 800) * -0.1

			sv_phys.SV_CheckVelocity(ent)
			sv_phys.SV_FlyMove(ent, R(sv.frametime), true, nil, sv_phys.SV_GenericHitSuperContentsMask(ent), 0, 0, 0)
			sv_phys.SV_LinkEdict(ent)
			sv_phys.SV_LinkEdict_TouchAreaGrid(ent)

			-- just hit ground
			if hitsound and hasflag(EF(prog, ent, "flags"), FL_ONGROUND) then
				-- DRESK - Check for Entity Land Event Function
				if EI(prog, ent, "movetypesteplandevent") ~= 0 then
					-- Valid Function; Execute
					-- Prepare Parameters
					-- Assign Velocity at Impact
					SET_G_FLOAT(prog, OFS_PARM0, backupVelocity[1])
					SET_G_FLOAT(prog, OFS_PARM0 + 1, backupVelocity[2])
					SET_G_FLOAT(prog, OFS_PARM0 + 2, backupVelocity[3])
					-- Assign Self
					SET_GI(prog, "self", ent)
					-- Set Time
					SET_GF(prog, "time", sv.time)
					-- Execute VM Function
					prvm_edict.ExecuteProgram(
						prog,
						EI(prog, ent, "movetypesteplandevent"),
						"movetypesteplandevent: NULL function"
					)
				else
					-- Check for Engine Landing Sound
					-- (engine quirk kept: sv_sound_land.string is never NULL, an empty cvar still reaches SV_StartSound)
					SV_StartSound_cvar(ent, 0, cvarstr("sv_sound_land", "demon/dland2.wav"))
				end
			end
			forceupdate[ent] = true
		end
	end
end

--============================================================================

-- port: sv_phys.c SV_Physics_Entity L2816-2891 @xonotic-v0.8.6
function sv_phys.SV_Physics_Entity(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local edmove = priv(prog, "ed_move")
	-- don't run think/move on newly spawned projectiles as it messes up
	-- movement interpolation and rocket trails, and is inconsistent with
	-- respect to entities spawned in the same frame
	-- (if an ent spawns a higher numbered ent, it moves in the same frame,
	--  but if it spawns a lower numbered ent, it doesn't - this never moves
	--  ents in the first frame regardless)
	local runmove = edmove[ent] == true
	edmove[ent] = true
	if not runmove and cvarint("sv_gameplayfix_delayprojectiles", 1) > 0 then
		return
	end
	local movetype = toint(EF(prog, ent, "movetype"))
	if movetype == MOVETYPE_PUSH or movetype == MOVETYPE_FAKEPUSH then
		sv_phys.SV_Physics_Pusher(ent)
	elseif movetype == MOVETYPE_NONE then
		-- LordHavoc: manually inlined the thinktime check here because MOVETYPE_NONE is used on so many objects
		if EF(prog, ent, "nextthink") > 0 and EF(prog, ent, "nextthink") <= sv.time + sv.frametime then
			sv_phys.SV_RunThink(ent)
		end
	elseif movetype == MOVETYPE_FOLLOW then
		if sv_phys.SV_RunThink(ent) then
			sv_phys.SV_Physics_Follow(ent)
		end
	elseif movetype == MOVETYPE_NOCLIP then
		if sv_phys.SV_RunThink(ent) then
			sv_phys.SV_CheckWater(ent)
			local o, v = EV(prog, ent, "origin"), EV(prog, ent, "velocity")
			SET_EV(prog, ent, "origin", {
				R(o[1] + sv.frametime * v[1]),
				R(o[2] + sv.frametime * v[2]),
				R(o[3] + sv.frametime * v[3]),
			})
			local an, av = EV(prog, ent, "angles"), EV(prog, ent, "avelocity")
			SET_EV(prog, ent, "angles", {
				R(an[1] + sv.frametime * av[1]),
				R(an[2] + sv.frametime * av[2]),
				R(an[3] + sv.frametime * av[3]),
			})
		end
		sv_phys.SV_LinkEdict(ent)
	elseif movetype == MOVETYPE_STEP then
		sv_phys.SV_Physics_Step(ent)
		-- regular thinking
		if sv_phys.SV_RunThink(ent) then
			local forceupdate = priv(prog, "ed_waterposition_forceupdate")
			local wpo = privvec(prog, "ed_waterposition_origin", ent)
			if forceupdate[ent] or not VectorCompare(EV(prog, ent, "origin"), wpo) then
				forceupdate[ent] = false
				local o = EV(prog, ent, "origin")
				wpo[1], wpo[2], wpo[3] = o[1], o[2], o[3]
				sv_phys.SV_CheckWaterTransition(ent)
			end
		end
	elseif movetype == MOVETYPE_WALK then
		if sv_phys.SV_RunThink(ent) then
			sv_phys.SV_WalkMove(ent)
		end
	elseif
		movetype == MOVETYPE_TOSS
		or movetype == MOVETYPE_BOUNCE
		or movetype == MOVETYPE_BOUNCEMISSILE
		or movetype == MOVETYPE_FLYMISSILE
		or movetype == MOVETYPE_FLY
		or movetype == MOVETYPE_FLY_WORLDONLY
	then
		-- regular thinking
		if sv_phys.SV_RunThink(ent) then
			sv_phys.SV_Physics_Toss(ent)
		end
	elseif movetype == MOVETYPE_PHYSICS then
		if sv_phys.SV_RunThink(ent) then
			sv_phys.SV_LinkEdict(ent)
			sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
		end
	else
		if movetype >= MOVETYPE_USER_FIRST and movetype <= MOVETYPE_USER_LAST then
			return
		end
		Con_Printf("SV_Physics: bad movetype %i\n", movetype)
	end
end

-- port: sv_phys.c SV_Physics_ClientEntity_NoThink L2893-2941 @xonotic-v0.8.6
-- selene: allow(empty_if, if_same_then_else)
function sv_phys.SV_Physics_ClientEntity_NoThink(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv

	-- don't run think at all, that is done during server frames
	-- instead, call the movetypes directly so they match client input

	-- This probably only makes sense for CSQC-networked (SendEntity field set) player entities
	local movetype = toint(EF(prog, ent, "movetype"))
	if movetype == MOVETYPE_PUSH or movetype == MOVETYPE_FAKEPUSH then
		-- push physics relies heavily on think times and calls, and so cannot be predicted currently
		Con_Printf("SV_Physics_ClientEntity_NoThink: bad movetype %i\n", movetype)
	elseif movetype == MOVETYPE_NONE then
		-- nothing
	elseif movetype == MOVETYPE_FOLLOW then
		sv_phys.SV_Physics_Follow(ent)
	elseif movetype == MOVETYPE_NOCLIP then
		local o, v = EV(prog, ent, "origin"), EV(prog, ent, "velocity")
		SET_EV(prog, ent, "origin", {
			R(o[1] + sv.frametime * v[1]),
			R(o[2] + sv.frametime * v[2]),
			R(o[3] + sv.frametime * v[3]),
		})
		local an, av = EV(prog, ent, "angles"), EV(prog, ent, "avelocity")
		SET_EV(prog, ent, "angles", {
			R(an[1] + sv.frametime * av[1]),
			R(an[2] + sv.frametime * av[2]),
			R(an[3] + sv.frametime * av[3]),
		})
	elseif movetype == MOVETYPE_STEP then
		sv_phys.SV_Physics_Step(ent)
	elseif movetype == MOVETYPE_WALK then
		sv_phys.SV_WalkMove(ent)
	elseif
		movetype == MOVETYPE_TOSS
		or movetype == MOVETYPE_BOUNCE
		or movetype == MOVETYPE_BOUNCEMISSILE
		or movetype == MOVETYPE_FLYMISSILE
	then
		sv_phys.SV_Physics_Toss(ent)
	elseif movetype == MOVETYPE_FLY or movetype == MOVETYPE_FLY_WORLDONLY then
		sv_phys.SV_WalkMove(ent)
	elseif movetype == MOVETYPE_PHYSICS then
		-- nothing
	else
		if movetype >= MOVETYPE_USER_FIRST and movetype <= MOVETYPE_USER_LAST then
			return
		end
		Con_Printf("SV_Physics_ClientEntity_NoThink: bad movetype %i\n", movetype)
	end
end

-- port: sv_phys.c SV_Physics_ClientMove L2943-2984 @xonotic-v0.8.6
function sv_phys.SV_Physics_ClientMove()
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local host_client = server.host_client
	local ent = host_client.edict :: number

	-- call player physics, this needs the proper frametime
	SET_GF(prog, "frametime", sv.frametime)
	SV_ClientThink()

	-- call standard client pre-think, with frametime = 0
	SET_GF(prog, "time", sv.time)
	SET_GF(prog, "frametime", 0)
	SET_GI(prog, "self", ent)
	prvm_edict.ExecuteProgram(prog, serverfunction(prog, "PlayerPreThink"), "QC function PlayerPreThink is missing")
	SET_GF(prog, "frametime", sv.frametime)

	-- make sure the velocity is sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	-- perform movetype behaviour
	-- note: will always be MOVETYPE_WALK if disableclientprediction = 0
	sv_phys.SV_Physics_ClientEntity_NoThink(ent)

	-- call standard player post-think, with frametime = 0
	SET_GF(prog, "time", sv.time)
	SET_GF(prog, "frametime", 0)
	SET_GI(prog, "self", ent)
	prvm_edict.ExecuteProgram(prog, serverfunction(prog, "PlayerPostThink"), "QC function PlayerPostThink is missing")
	SET_GF(prog, "frametime", sv.frametime)

	if EF(prog, ent, "fixangle") ~= 0 then
		-- angle fixing was requested by physics code...
		-- so store the current angles for later use
		host_client.fixangle_angles = EV(prog, ent, "angles")
		host_client.fixangle_angles_set = true

		-- and clear fixangle for the next frame
		SET_EF(prog, ent, "fixangle", 0)
	end
end

-- port: sv_phys.c SV_Physics_ClientEntity_PreThink L2986-3013 @xonotic-v0.8.6
function sv_phys.SV_Physics_ClientEntity_PreThink(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local host_client = server.host_client
	-- don't do physics on disconnected clients, FrikBot relies on this
	if not host_client.begun then
		return
	end

	-- make sure the velocity is sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	-- don't run physics here if running asynchronously
	if (host_client.clmovement_inputtimeout or 0) <= 0 then
		SV_ClientThink()
		--host_client->cmd.time = max(host_client->cmd.time, sv.time);
	end

	-- make sure the velocity is still sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	-- call standard client pre-think
	SET_GF(prog, "time", server.sv.time)
	SET_GI(prog, "self", ent)
	prvm_edict.ExecuteProgram(prog, serverfunction(prog, "PlayerPreThink"), "QC function PlayerPreThink is missing")

	-- make sure the velocity is still sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)
end

-- port: sv_phys.c SV_Physics_ClientEntity_PostThink L3015-3050 @xonotic-v0.8.6
function sv_phys.SV_Physics_ClientEntity_PostThink(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local host_client = server.host_client
	-- don't do physics on disconnected clients, FrikBot relies on this
	if not host_client.begun then
		return
	end

	-- make sure the velocity is sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	-- call standard player post-think
	SET_GF(prog, "time", sv.time)
	SET_GI(prog, "self", ent)
	prvm_edict.ExecuteProgram(prog, serverfunction(prog, "PlayerPostThink"), "QC function PlayerPostThink is missing")

	-- make sure the velocity is still sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	if EF(prog, ent, "fixangle") ~= 0 then
		-- angle fixing was requested by physics code...
		-- so store the current angles for later use
		host_client.fixangle_angles = EV(prog, ent, "angles")
		host_client.fixangle_angles_set = true

		-- and clear fixangle for the next frame
		SET_EF(prog, ent, "fixangle", 0)
	end

	-- decrement the countdown variable used to decide when to go back to
	-- synchronous physics
	local timeout = host_client.clmovement_inputtimeout or 0
	if timeout > sv.frametime then
		host_client.clmovement_inputtimeout = R(timeout - sv.frametime) -- float - double, stored as float
	else
		host_client.clmovement_inputtimeout = 0
	end
end

-- port: sv_phys.c SV_Physics_ClientEntity L3052-3138 @xonotic-v0.8.6
-- selene: allow(if_same_then_else)
function sv_phys.SV_Physics_ClientEntity(ent: number)
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local host_client = server.host_client
	-- don't do physics on disconnected clients, FrikBot relies on this
	if not host_client.begun then
		-- memset(&host_client->cmd, 0, sizeof(host_client->cmd)): usercmd_t is not ported yet, a new empty
		-- table stands for the zeroed struct (its readers treat nil fields as 0)
		host_client.cmd = {}
		return
	end

	-- make sure the velocity is sane (not a NaN)
	sv_phys.SV_CheckVelocity(ent)

	local sync = (host_client.clmovement_inputtimeout or 0) <= 0 -- don't run physics here if running asynchronously
	local movetype = toint(EF(prog, ent, "movetype"))
	if movetype == MOVETYPE_PUSH or movetype == MOVETYPE_FAKEPUSH then
		sv_phys.SV_Physics_Pusher(ent)
	elseif movetype == MOVETYPE_NONE then
		-- LordHavoc: manually inlined the thinktime check here because MOVETYPE_NONE is used on so many objects
		if EF(prog, ent, "nextthink") > 0 and EF(prog, ent, "nextthink") <= sv.time + sv.frametime then
			sv_phys.SV_RunThink(ent)
		end
	elseif movetype == MOVETYPE_FOLLOW then
		sv_phys.SV_RunThink(ent)
		if (host_client.clmovement_inputtimeout or 0) <= 0 then -- don't run physics here if running asynchronously
			sv_phys.SV_Physics_Follow(ent)
		end
	elseif movetype == MOVETYPE_NOCLIP then
		sv_phys.SV_RunThink(ent)
		if (host_client.clmovement_inputtimeout or 0) <= 0 then -- don't run physics here if running asynchronously
			sv_phys.SV_CheckWater(ent)
			local o, v = EV(prog, ent, "origin"), EV(prog, ent, "velocity")
			SET_EV(prog, ent, "origin", {
				R(o[1] + sv.frametime * v[1]),
				R(o[2] + sv.frametime * v[2]),
				R(o[3] + sv.frametime * v[3]),
			})
			local an, av = EV(prog, ent, "angles"), EV(prog, ent, "avelocity")
			SET_EV(prog, ent, "angles", {
				R(an[1] + sv.frametime * av[1]),
				R(an[2] + sv.frametime * av[2]),
				R(an[3] + sv.frametime * av[3]),
			})
		end
	elseif movetype == MOVETYPE_STEP then
		if sync then -- don't run physics here if running asynchronously
			sv_phys.SV_Physics_Step(ent)
		end
		if sv_phys.SV_RunThink(ent) then
			local forceupdate = priv(prog, "ed_waterposition_forceupdate")
			local wpo = privvec(prog, "ed_waterposition_origin", ent)
			if forceupdate[ent] or not VectorCompare(EV(prog, ent, "origin"), wpo) then
				forceupdate[ent] = false
				local o = EV(prog, ent, "origin")
				wpo[1], wpo[2], wpo[3] = o[1], o[2], o[3]
				sv_phys.SV_CheckWaterTransition(ent)
			end
		end
	elseif movetype == MOVETYPE_WALK then
		sv_phys.SV_RunThink(ent)
		-- don't run physics here if running asynchronously
		if (host_client.clmovement_inputtimeout or 0) <= 0 then
			sv_phys.SV_WalkMove(ent)
		end
	elseif
		movetype == MOVETYPE_TOSS
		or movetype == MOVETYPE_BOUNCE
		or movetype == MOVETYPE_BOUNCEMISSILE
		or movetype == MOVETYPE_FLYMISSILE
	then
		-- regular thinking
		sv_phys.SV_RunThink(ent)
		if (host_client.clmovement_inputtimeout or 0) <= 0 then -- don't run physics here if running asynchronously
			sv_phys.SV_Physics_Toss(ent)
		end
	elseif movetype == MOVETYPE_FLY or movetype == MOVETYPE_FLY_WORLDONLY then
		sv_phys.SV_RunThink(ent)
		if (host_client.clmovement_inputtimeout or 0) <= 0 then -- don't run physics here if running asynchronously
			sv_phys.SV_WalkMove(ent)
		end
	elseif movetype == MOVETYPE_PHYSICS then
		sv_phys.SV_RunThink(ent)
	else
		if not (movetype >= MOVETYPE_USER_FIRST and movetype <= MOVETYPE_USER_LAST) then
			Con_Printf("SV_Physics_ClientEntity: bad movetype %i\n", movetype)
		end
	end

	sv_phys.SV_CheckVelocity(ent)

	sv_phys.SV_LinkEdict(ent)
	sv_phys.SV_LinkEdict_TouchAreaGrid(ent)

	sv_phys.SV_CheckVelocity(ent)
end

--[[
================
SV_Physics

================
]]
-- port: sv_phys.c SV_Physics L3146-3232 @xonotic-v0.8.6
function sv_phys.SV_Physics()
	local prog = cvar.prvm_prog_list[0]
	local sv = server.sv
	local svs = host_cmd.svs :: any
	local i

	-- let the progs know that a new frame has started
	SET_GI(prog, "self", 0)
	SET_GI(prog, "other", 0)
	SET_GF(prog, "time", sv.time)
	SET_GF(prog, "frametime", sv.frametime)
	prvm_edict.ExecuteProgram(prog, serverfunction(prog, "StartFrame"), "QC function StartFrame is missing")

	-- run physics engine
	-- World_Physics_Frame(&sv.world, sv.frametime, sv_gravity.value)
	notPorted("World_Physics_Frame (world.c physics engine, ODE) in SV_Physics")

	--
	-- treat each object in turn
	--

	-- if force_retouch, relink all the entities
	if GF(prog, "force_retouch") > 0 then
		i = 1
		while i < prog.num_edicts do
			if not prog.ed_free[i] then
				sv_phys.SV_LinkEdict_TouchAreaGrid(i) -- force retouch even for stationary
			end
			i += 1
		end
	end

	if cvarint("sv_gameplayfix_consistentplayerprethink", 0) ~= 0 then
		-- run physics on the client entities in 3 stages
		i = 1
		while i <= svs.maxclients do
			server.host_client = svs_client(i - 1)
			if not prog.ed_free[i] then
				sv_phys.SV_Physics_ClientEntity_PreThink(i)
			end
			i += 1
		end

		i = 1
		while i <= svs.maxclients do
			server.host_client = svs_client(i - 1)
			if not prog.ed_free[i] then
				sv_phys.SV_Physics_ClientEntity(i)
			end
			i += 1
		end

		i = 1
		while i <= svs.maxclients do
			server.host_client = svs_client(i - 1)
			if not prog.ed_free[i] then
				sv_phys.SV_Physics_ClientEntity_PostThink(i)
			end
			i += 1
		end
	else
		-- run physics on the client entities
		i = 1
		while i <= svs.maxclients do
			server.host_client = svs_client(i - 1)
			if not prog.ed_free[i] then
				sv_phys.SV_Physics_ClientEntity_PreThink(i)
				sv_phys.SV_Physics_ClientEntity(i)
				sv_phys.SV_Physics_ClientEntity_PostThink(i)
			end
			i += 1
		end
	end
	-- (C leaves host_client at svs.clients + svs.maxclients, one past the last client)
	server.host_client = svs_client(svs.maxclients)

	-- run physics on all the non-client entities
	if cvarint("sv_freezenonclients", 0) == 0 then
		while i < prog.num_edicts do
			if not prog.ed_free[i] then
				sv_phys.SV_Physics_Entity(i)
			end
			i += 1
		end
		-- make a second pass to see if any ents spawned this frame and make
		-- sure they run their move/think
		if cvarint("sv_gameplayfix_delayprojectiles", 1) < 0 then
			local edmove = priv(prog, "ed_move")
			i = svs.maxclients + 1
			while i < prog.num_edicts do
				if not edmove[i] and not prog.ed_free[i] then
					sv_phys.SV_Physics_Entity(i)
				end
				i += 1
			end
		end
	end

	if GF(prog, "force_retouch") > 0 then
		SET_GF(prog, "force_retouch", cmax(0, R(GF(prog, "force_retouch") - 1)))
	end

	-- LordHavoc: endframe support
	if serverfunction(prog, "EndFrame") ~= 0 then
		SET_GI(prog, "self", 0)
		SET_GI(prog, "other", 0)
		SET_GF(prog, "time", sv.time)
		prvm_edict.ExecuteProgram(prog, serverfunction(prog, "EndFrame"), "QC function EndFrame is missing")
	end

	-- decrement prog->num_edicts if the highest number entities died
	while prvm_edict.PRVM_ED_CanAlloc(prog, prog.num_edicts - 1) do
		prog.num_edicts -= 1
	end

	if cvarint("sv_freezenonclients", 0) == 0 then
		sv.time += sv.frametime
	end
end

--[[
	SV_Trace_Toss is svvm_cmds.c (static, used by VM_SV_tracetoss); it is here until it moves to
	engine/svvm_cmds.luau with the tracetoss builtin. ignore is unused, as in C.
]]
-- port: svvm_cmds.c SV_Trace_Toss L703-748 @xonotic-v0.8.6
function sv_phys.SV_Trace_Toss(prog: any, tossent: number, _ignore: number?): collision.trace_t
	local trace: collision.trace_t = collision.newtrace()

	local original_origin = EV(prog, tossent, "origin")
	local original_velocity = EV(prog, tossent, "velocity")
	local original_angles = EV(prog, tossent, "angles")
	local original_avelocity = EV(prog, tossent, "avelocity")

	local gravity = EF(prog, tossent, "gravity")
	if gravity == 0 then
		gravity = 1.0
	end
	-- gravity *= sv_gravity.value * 0.025: float * double, stored as float
	gravity = R(gravity * (cvarval("sv_gravity", 800) * 0.025))

	for _i = 0, 199 do -- LordHavoc: sanity check; never trace more than 10 seconds
		sv_phys.SV_CheckVelocity(tossent)
		SET_EVi(prog, tossent, "velocity", 3, R(EVi(prog, tossent, "velocity", 3) - gravity))
		local an, av = EV(prog, tossent, "angles"), EV(prog, tossent, "avelocity")
		SET_EV(prog, tossent, "angles", { R(an[1] + 0.05 * av[1]), R(an[2] + 0.05 * av[2]), R(an[3] + 0.05 * av[3]) })
		local vel = EV(prog, tossent, "velocity")
		local move = { R(vel[1] * 0.05), R(vel[2] * 0.05), R(vel[3] * 0.05) }
		local o = EV(prog, tossent, "origin")
		local end_ = { R(o[1] + move[1]), R(o[2] + move[2]), R(o[3] + move[3]) }
		local tossentorigin = EV(prog, tossent, "origin")
		local tossentmins = EV(prog, tossent, "mins")
		local tossentmaxs = EV(prog, tossent, "maxs")
		trace = sv_phys.SV_TraceBox(
			tossentorigin,
			tossentmins,
			tossentmaxs,
			end_,
			MOVE_NORMAL,
			tossent,
			sv_phys.SV_GenericHitSuperContentsMask(tossent),
			0,
			0,
			collision.cv.collision_extendmovelength.value
		)
		SET_EV(prog, tossent, "origin", trace.endpos)
		SET_EVi(prog, tossent, "velocity", 3, R(EVi(prog, tossent, "velocity", 3) - gravity))

		if trace.fraction < 1 then
			break
		end
	end

	SET_EV(prog, tossent, "origin", original_origin)
	SET_EV(prog, tossent, "velocity", original_velocity)
	SET_EV(prog, tossent, "angles", original_angles)
	SET_EV(prog, tossent, "avelocity", original_avelocity)

	return trace
end

return sv_phys
