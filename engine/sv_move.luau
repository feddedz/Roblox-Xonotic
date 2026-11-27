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
-- sv_move.c -- monster movement
--[[
	Port of sv_move.c @xonotic-v0.8.6 (the whole file). Conventions as in engine/sv_phys.luau: an edict is its
	number (prog->edicts, the world, is 0), SVVM_prog is cvar.prvm_prog_list[0], fields / globals are the
	4-byte slots of prog.edictsfields / prog.globals, priv.server->areamins / areamaxs is world.edictarea(prog, n).
	vec_t is float (qtypes.h, VEC_64 off): every float result is rounded (D-004); trace_t.fraction / endpos are
	double (collision.h) and comparisons mixing them with floats are done in double, as in C.
	Requires sv_phys at the top: sv_phys -> sv_main -> svvm_cmds, and svvm_cmds requires this module only
	inside its builtins, so there is no load loop.
]]
local collision = require("./collision")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libm = require("./_port/libm")
local libc = require("./_port/libc")
local mathlib = require("./mathlib")
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local sv_phys = require("./sv_phys")
local world = require("./world")

local sv_move = {}

local R = f32.round
local toint = libc.toint
local rand = libc.rand
local FieldOfs = prvm_edict.FieldOfs
local GlobalOfs = prvm_cmds.GlobalOfs
local SV_TraceBox, SV_TraceLine = sv_phys.SV_TraceBox, sv_phys.SV_TraceLine
local SV_PointSuperContents = sv_phys.SV_PointSuperContents
local SV_GenericHitSuperContentsMask = sv_phys.SV_GenericHitSuperContentsMask

-- world.h L27-28
local MOVE_NORMAL, MOVE_NOMONSTERS = 0, 1
-- server.h L367-368, L376-377
local FL_FLY, FL_SWIM, FL_ONGROUND, FL_PARTIALGROUND = 1, 2, 512, 1024
-- bspfile.h L191-213
local SUPERCONTENTS_SOLID, SUPERCONTENTS_WATER, SUPERCONTENTS_SLIME = 0x01, 0x02, 0x04
local SUPERCONTENTS_LAVA, SUPERCONTENTS_BODY = 0x08, 0x20
local SUPERCONTENTS_LIQUIDSMASK = bit32.bor(SUPERCONTENTS_LAVA, SUPERCONTENTS_SLIME, SUPERCONTENTS_WATER)
local YAW = 2 -- mathlib.h YAW 1, as a Luau index
local M_PI = math.pi -- mathlib.h L28 (3.14159265358979323846 rounds to this double)
local OFS_RETURN, OFS_PARM0 = 1, 4

-- cvars (registered values, else the defaults sv_main.c registers them with)
local function sv_stepheight_value(): number -- sv_main.c L144 "18"
	local v = cvar.Cvar_FindVar("sv_stepheight")
	return if v then v.value else 18
end
local function cvarint(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else default
end

-- PRVM_serveredict* / PRVM_serverglobal* (see engine/sv_phys.luau)
local function EOFS(prog: any, ed: number, f: string): number
	return (ed * prog.entityfields + FieldOfs(prog, f)) * 4
end
local function EF(prog: any, ed: number, f: string): number
	return buffer.readf32(prog.edictsfields, EOFS(prog, ed, f))
end
local function SET_EF(prog: any, ed: number, f: string, v: number)
	buffer.writef32(prog.edictsfields, EOFS(prog, ed, f), v)
end
local function EI(prog: any, ed: number, f: string): number
	return buffer.readi32(prog.edictsfields, EOFS(prog, ed, f))
end
local function SET_EI(prog: any, ed: number, f: string, v: number)
	buffer.writei32(prog.edictsfields, EOFS(prog, ed, f), v)
end
local function EV(prog: any, ed: number, f: string): { number } -- a copy of PRVM_serveredictvector
	local b, o = prog.edictsfields, EOFS(prog, ed, f)
	return { buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8) }
end
local function SET_EV(prog: any, ed: number, f: string, v: { number }) -- stores float (double values rounded)
	local b, o = prog.edictsfields, EOFS(prog, ed, f)
	buffer.writef32(b, o, v[1])
	buffer.writef32(b, o + 4, v[2])
	buffer.writef32(b, o + 8, v[3])
end
local function GI(prog: any, g: string): number
	return buffer.readi32(prog.globals, GlobalOfs(prog, g) * 4)
end
-- (int)flags & bit != 0
local function hasflag(x: number, bit: number): boolean
	return bit32.band(toint(x), bit) ~= 0
end
-- (int)flags & ~bit, stored back as float: the int result is signed
local function clearflag(x: number, bit: number): number
	local r = bit32.band(toint(x), bit32.bnot(bit))
	return if r >= 0x80000000 then r - 0x100000000 else r
end
-- (int)flags | bit
local function orflag(x: number, bit: number): number
	local r = bit32.bor(toint(x), bit)
	return if r >= 0x80000000 then r - 0x100000000 else r
end

--[[
=============
SV_CheckBottom

Returns false if any part of the bottom of the entity is off an edge that
is not a staircase.

=============
]]
sv_move.c_yes = 0
sv_move.c_no = 0

-- port: sv_move.c SV_CheckBottom L36-97 @xonotic-v0.8.6
function sv_move.SV_CheckBottom(ent: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local start, stop = { 0, 0, 0 }, { 0, 0, 0 }
	local trace
	local mid, bottom
	local sv_stepheight = sv_stepheight_value()
	local extend = collision.cv.collision_extendmovelength.value

	local origin, emins, emaxs = EV(prog, ent, "origin"), EV(prog, ent, "mins"), EV(prog, ent, "maxs")
	local mins = { R(origin[1] + emins[1]), R(origin[2] + emins[2]), R(origin[3] + emins[3]) }
	local maxs = { R(origin[1] + emaxs[1]), R(origin[2] + emaxs[2]), R(origin[3] + emaxs[3]) }

	-- if all of the points under the corners are solid world, don't bother
	-- with the tougher checks
	-- the corners must be within 16 of the midpoint
	start[3] = R(mins[3] - 1)
	local realcheck = false
	for x = 0, 1 do
		for y = 0, 1 do
			start[1] = if x ~= 0 then maxs[1] else mins[1]
			start[2] = if y ~= 0 then maxs[2] else mins[2]
			if bit32.band(SV_PointSuperContents(start), bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY)) == 0 then
				realcheck = true -- goto realcheck
				break
			end
		end
		if realcheck then
			break
		end
	end

	if not realcheck then
		sv_move.c_yes += 1
		return true -- we got out easy
	end

	-- realcheck:
	sv_move.c_no += 1
	--
	-- check it for real...
	--
	start[3] = mins[3]

	-- the midpoint must be within 16 of the bottom
	-- (mins + maxs) is float, * 0.5 (double), stored float
	start[1] = R(R(mins[1] + maxs[1]) * 0.5)
	stop[1] = start[1]
	start[2] = R(R(mins[2] + maxs[2]) * 0.5)
	stop[2] = start[2]
	stop[3] = R(start[3] - R(2 * sv_stepheight))
	trace = SV_TraceLine(start, stop, MOVE_NOMONSTERS, ent, SV_GenericHitSuperContentsMask(ent), 0, 0, extend)

	if trace.fraction == 1.0 then
		return false
	end
	mid = R(trace.endpos[3])
	bottom = mid

	-- the corners must be within 16 of the midpoint
	for x = 0, 1 do
		for y = 0, 1 do
			start[1] = if x ~= 0 then maxs[1] else mins[1]
			stop[1] = start[1]
			start[2] = if y ~= 0 then maxs[2] else mins[2]
			stop[2] = start[2]

			trace = SV_TraceLine(start, stop, MOVE_NOMONSTERS, ent, SV_GenericHitSuperContentsMask(ent), 0, 0, extend)

			-- (double endpos compared with the float bottom in double; the float bottom = double endpos rounds)
			if trace.fraction ~= 1.0 and trace.endpos[3] > bottom then
				bottom = R(trace.endpos[3])
			end
			-- mid - endpos: float - double, evaluated in double
			if trace.fraction == 1.0 or mid - trace.endpos[3] > sv_stepheight then
				return false
			end
		end
	end

	sv_move.c_yes += 1
	return true
end

--[[
=============
SV_movestep

Called by monster program code.
The move will be adjusted for slopes and stairs, but if the move isn't
possible, no move is done and false is returned
=============
]]
-- port: sv_move.c SV_movestep L109-243 @xonotic-v0.8.6
-- (engine quirk kept: settrace is accepted and never used in 0.8.6)
function sv_move.SV_movestep(
	ent: number,
	move: { number },
	relink: boolean,
	noenemy: boolean,
	_settrace: boolean
): boolean
	local prog = cvar.prvm_prog_list[0]
	local dz
	local trace
	local enemy
	local sv_stepheight = sv_stepheight_value()
	local extend = collision.cv.collision_extendmovelength.value

	-- try the move
	local oldorg = EV(prog, ent, "origin")
	local origin = EV(prog, ent, "origin")
	local neworg = { R(origin[1] + move[1]), R(origin[2] + move[2]), R(origin[3] + move[3]) }
	local entmins = EV(prog, ent, "mins")
	local entmaxs = EV(prog, ent, "maxs")

	-- flying monsters don't step up
	if hasflag(EF(prog, ent, "flags"), bit32.bor(FL_SWIM, FL_FLY)) then
		-- try one move with vertical motion, then one without
		for i = 0, 1 do
			origin = EV(prog, ent, "origin")
			neworg = { R(origin[1] + move[1]), R(origin[2] + move[2]), R(origin[3] + move[3]) }
			if noenemy then
				enemy = 0
			else
				enemy = EI(prog, ent, "enemy")
				if i == 0 and enemy ~= 0 then
					dz = R(EV(prog, ent, "origin")[3] - EV(prog, enemy, "origin")[3])
					if dz > 40 then
						neworg[3] = R(neworg[3] - 8)
					end
					if dz < 30 then
						neworg[3] = R(neworg[3] + 8)
					end
				end
			end
			local entorigin = EV(prog, ent, "origin")
			trace = SV_TraceBox(
				entorigin,
				entmins,
				entmaxs,
				neworg,
				MOVE_NORMAL,
				ent,
				SV_GenericHitSuperContentsMask(ent),
				0,
				0,
				extend
			)

			if trace.fraction == 1 then
				local traceendpos = { R(trace.endpos[1]), R(trace.endpos[2]), R(trace.endpos[3]) }
				if
					hasflag(EF(prog, ent, "flags"), FL_SWIM)
					and bit32.band(SV_PointSuperContents(traceendpos), SUPERCONTENTS_LIQUIDSMASK) == 0
				then
					return false -- swim monster left water
				end

				SET_EV(prog, ent, "origin", traceendpos)
				if relink then
					sv_phys.SV_LinkEdict(ent)
					sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
				end
				return true
			end

			if enemy == 0 then
				break
			end
		end

		return false
	end

	-- push down from a step height above the wished position
	neworg[3] = R(neworg[3] + sv_stepheight)
	local end_ = { neworg[1], neworg[2], neworg[3] }
	end_[3] = R(end_[3] - R(sv_stepheight * 2))

	trace =
		SV_TraceBox(neworg, entmins, entmaxs, end_, MOVE_NORMAL, ent, SV_GenericHitSuperContentsMask(ent), 0, 0, extend)

	if trace.startsolid then
		neworg[3] = R(neworg[3] - sv_stepheight)
		trace = SV_TraceBox(
			neworg,
			entmins,
			entmaxs,
			end_,
			MOVE_NORMAL,
			ent,
			SV_GenericHitSuperContentsMask(ent),
			0,
			0,
			extend
		)
		if trace.startsolid then
			return false
		end
	end
	if trace.fraction == 1 then
		-- if monster had the ground pulled out, go ahead and fall
		if hasflag(EF(prog, ent, "flags"), FL_PARTIALGROUND) then
			origin = EV(prog, ent, "origin")
			SET_EV(prog, ent, "origin", { R(origin[1] + move[1]), R(origin[2] + move[2]), R(origin[3] + move[3]) })
			if relink then
				sv_phys.SV_LinkEdict(ent)
				sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
			end
			SET_EF(prog, ent, "flags", clearflag(EF(prog, ent, "flags"), FL_ONGROUND))
			return true
		end

		return false -- walked off an edge
	end

	-- check point traces down for dangling corners
	SET_EV(prog, ent, "origin", trace.endpos)

	if not sv_move.SV_CheckBottom(ent) then
		if hasflag(EF(prog, ent, "flags"), FL_PARTIALGROUND) then
			-- entity had floor mostly pulled out from underneath it
			-- and is trying to correct
			if relink then
				sv_phys.SV_LinkEdict(ent)
				sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
			end
			return true
		end
		SET_EV(prog, ent, "origin", oldorg)
		return false
	end

	if hasflag(EF(prog, ent, "flags"), FL_PARTIALGROUND) then
		SET_EF(prog, ent, "flags", clearflag(EF(prog, ent, "flags"), FL_PARTIALGROUND))
	end

	-- gameplayfix: check if reached pretty steep plane and bail
	if
		not hasflag(EF(prog, ent, "flags"), bit32.bor(FL_SWIM, FL_FLY))
		and cvarint("sv_gameplayfix_nostepmoveonsteepslopes", 0) ~= 0
	then
		-- plane.normal is vec3_t (float)
		if R(trace.plane.normal[3]) < 0.5 then
			SET_EV(prog, ent, "origin", oldorg)
			return false
		end
	end

	-- PRVM_EDICT_TO_PROG(trace.ent): trace.ent is set (at least the world) whenever fraction < 1
	SET_EI(prog, ent, "groundentity", trace.ent or 0)

	-- the move is ok
	if relink then
		sv_phys.SV_LinkEdict(ent)
		sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
	end
	return true
end

--============================================================================

--[[
======================
SV_StepDirection

Turns to the movement direction, and walks the current distance if
facing it.

======================
]]
-- port: sv_move.c SV_StepDirection L257-287 @xonotic-v0.8.6
-- (engine quirk kept: VM_changeyaw turns the QC `self`, not ent; every caller passes self)
local function SV_StepDirection(ent: number, yaw: number, dist: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local move = { 0, 0, 0 }
	local delta

	SET_EF(prog, ent, "ideal_yaw", yaw)
	prvm_cmds.VM_changeyaw(prog)

	-- float * M_PI (double) * 2 / 360 in double, stored into the float yaw
	yaw = R(yaw * M_PI * 2 / 360)
	-- cos / sin take and return double; * dist (double), stored float
	move[1] = R(libm.cos(yaw) * dist)
	move[2] = R(libm.sin(yaw) * dist)
	move[3] = 0

	local oldorigin = EV(prog, ent, "origin")
	if sv_move.SV_movestep(ent, move, false, false, false) then
		delta = R(EV(prog, ent, "angles")[YAW] - EF(prog, ent, "ideal_yaw"))
		if delta > 45 and delta < 315 then
			-- not turned far enough, so don't take the step
			SET_EV(prog, ent, "origin", oldorigin)
		end
		sv_phys.SV_LinkEdict(ent)
		sv_phys.SV_LinkEdict_TouchAreaGrid(ent)
		return true
	end
	sv_phys.SV_LinkEdict(ent)
	sv_phys.SV_LinkEdict_TouchAreaGrid(ent)

	return false
end
sv_move.SV_StepDirection = SV_StepDirection

--[[
======================
SV_FixCheckBottom

======================
]]
-- port: sv_move.c SV_FixCheckBottom L295-299 @xonotic-v0.8.6
local function SV_FixCheckBottom(ent: number)
	local prog = cvar.prvm_prog_list[0]
	SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_PARTIALGROUND))
end
sv_move.SV_FixCheckBottom = SV_FixCheckBottom

--[[
================
SV_NewChaseDir

================
]]
local DI_NODIR = -1
-- port: sv_move.c SV_NewChaseDir L310-392 @xonotic-v0.8.6
local function SV_NewChaseDir(actor: number, enemy: number, dist: number)
	local prog = cvar.prvm_prog_list[0]
	local deltax, deltay
	local d = { 0, 0, 0 } -- C d[0..2] at [1..3]
	local tdir, olddir, turnaround

	-- (int)(ideal_yaw / 45) * 45: an int product (wraps like the x86 imul), ANGLEMOD in double, stored float
	local q = toint(R(EF(prog, actor, "ideal_yaw") / 45)) * 45
	q = ((q + 2147483648) % 4294967296) - 2147483648
	olddir = R(mathlib.ANGLEMOD(q))
	turnaround = R(mathlib.ANGLEMOD(R(olddir - 180)))

	local eorigin, aorigin = EV(prog, enemy, "origin"), EV(prog, actor, "origin")
	deltax = R(eorigin[1] - aorigin[1])
	deltay = R(eorigin[2] - aorigin[2])
	if deltax > 10 then
		d[2] = 0
	elseif deltax < -10 then
		d[2] = 180
	else
		d[2] = DI_NODIR
	end
	if deltay < -10 then
		d[3] = 270
	elseif deltay > 10 then
		d[3] = 90
	else
		d[3] = DI_NODIR
	end

	-- try direct route
	if d[2] ~= DI_NODIR and d[3] ~= DI_NODIR then
		if d[2] == 0 then
			tdir = if d[3] == 90 then 45 else 315
		else
			-- engine quirk kept: 215, not 225 (id Software's original)
			tdir = if d[3] == 90 then 135 else 215
		end

		if tdir ~= turnaround and SV_StepDirection(actor, tdir, dist) then
			return
		end
	end

	-- try other directions
	if bit32.band(bit32.band(rand(), 3), 1) ~= 0 or math.abs(deltay) > math.abs(deltax) then
		tdir = d[2]
		d[2] = d[3]
		d[3] = tdir
	end

	if d[2] ~= DI_NODIR and d[2] ~= turnaround and SV_StepDirection(actor, d[2], dist) then
		return
	end

	if d[3] ~= DI_NODIR and d[3] ~= turnaround and SV_StepDirection(actor, d[3], dist) then
		return
	end

	--[[ there is no direct path to the player, so pick another direction ]]

	if olddir ~= DI_NODIR and SV_StepDirection(actor, olddir, dist) then
		return
	end

	if bit32.band(rand(), 1) ~= 0 then --[[randomly determine direction of search]]
		tdir = 0
		while tdir <= 315 do
			if tdir ~= turnaround and SV_StepDirection(actor, tdir, dist) then
				return
			end
			tdir += 45
		end
	else
		tdir = 315
		while tdir >= 0 do
			if tdir ~= turnaround and SV_StepDirection(actor, tdir, dist) then
				return
			end
			tdir -= 45
		end
	end

	if turnaround ~= DI_NODIR and SV_StepDirection(actor, turnaround, dist) then
		return
	end

	SET_EF(prog, actor, "ideal_yaw", olddir) -- can't move

	-- if a bridge was pulled out from underneath a monster, it may not have
	-- a valid standing position at all

	if not sv_move.SV_CheckBottom(actor) then
		SV_FixCheckBottom(actor)
	end
end
sv_move.SV_NewChaseDir = SV_NewChaseDir

--[[
======================
SV_CloseEnough

======================
]]
-- port: sv_move.c SV_CloseEnough L400-412 @xonotic-v0.8.6
local function SV_CloseEnough(ent: number, goal: number, dist: number): boolean
	local prog = cvar.prvm_prog_list[0]
	local g, e = world.edictarea(prog, goal), world.edictarea(prog, ent)

	for i = 1, 3 do
		if g.areamins[i] > R(e.areamaxs[i] + dist) then
			return false
		end
		if g.areamaxs[i] < R(e.areamins[i] - dist) then
			return false
		end
	end
	return true
end
sv_move.SV_CloseEnough = SV_CloseEnough

--[[
======================
SV_MoveToGoal

======================
]]
-- port: sv_move.c VM_SV_MoveToGoal L420-447 @xonotic-v0.8.6
-- (engine quirk kept: OFS_RETURN is only written on the not-on-ground early return)
function sv_move.VM_SV_MoveToGoal(prog: any)
	if prog.argc ~= 1 then -- VM_SAFEPARMCOUNT(1, SV_MoveToGoal)
		prog.error_cmd(string.format("SV_MoveToGoal wrong parameter count %i (1 expected ) !", prog.argc))
	end

	local ent = GI(prog, "self")
	local goal = EI(prog, ent, "goalentity")
	local dist = buffer.readf32(prog.globals, OFS_PARM0 * 4)

	if not hasflag(EF(prog, ent, "flags"), bit32.bor(FL_ONGROUND, FL_FLY, FL_SWIM)) then
		buffer.writef32(prog.globals, OFS_RETURN * 4, 0)
		return
	end

	-- if the next step hits the enemy, return immediately
	if EI(prog, ent, "enemy") ~= 0 and SV_CloseEnough(ent, goal, dist) then
		return
	end

	-- bump around...
	if bit32.band(rand(), 3) == 1 or not SV_StepDirection(ent, EF(prog, ent, "ideal_yaw"), dist) then
		SV_NewChaseDir(ent, goal, dist)
	end
end

return sv_move
