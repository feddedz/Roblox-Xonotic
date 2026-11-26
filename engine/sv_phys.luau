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
	Port of sv_phys.c @xonotic-v0.8.6. PARTIAL: line testing and entity linking (SV_GetPitchSign ..
	SV_LinkEdict, sv_phys.c L47-890; the COLLISIONPARANOID variants are not compiled in the release).

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
	NOT YET PORTED: VM_GenerateFrameGroupBlend / VM_FrameBlendFromFrameGroupBlend / VM_UpdateEdictSkeleton
	(prvm_cmds.c; the frameblend / skeleton passed to the models is nil), and the rest of sv_phys.c (movers,
	SV_Physics*).
]]
local collision = require("./collision")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
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

-- VM_GenerateFrameGroupBlend + VM_FrameBlendFromFrameGroupBlend + VM_UpdateEdictSkeleton (prvm_cmds.c);
-- the frameblend and skeleton they fill stay nil (NULL) until they are ported
local function frameblend_stub()
	notPorted(
		"VM_GenerateFrameGroupBlend / VM_FrameBlendFromFrameGroupBlend / VM_UpdateEdictSkeleton (prvm_cmds.c) in sv_phys.c"
	)
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
		frameblend_stub()
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				nil,
				nil,
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
				nil,
				nil,
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
		frameblend_stub()
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				nil,
				nil,
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
				nil,
				nil,
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
		frameblend_stub()
		local touchmins = EV(prog, touch, "mins")
		local touchmaxs = EV(prog, touch, "maxs")
		if type == MOVE_MISSILE and bit32.band(toint(EF(prog, touch, "flags")), FL_MONSTER) ~= 0 then
			collision.Collision_ClipToGenericEntity(
				trace,
				model,
				nil,
				nil,
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
				nil,
				nil,
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

	frameblend_stub()

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

return sv_phys
