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
]]
--[[
	Port of world.c / world.h @xonotic-v0.8.6 (world query functions). PARTIAL: the entity area grid
	(World_ClearLink .. World_LinkEdict, world.c L62-324) and World_Init.

	Representation:
	  * link_t is a table { entitynumber, prev, next }; a link that is not in a list has prev == nil (C: NULL).
	  * An edict is its number, as everywhere in the port. The part of edict_engineprivate_t (progs.h L88-94)
	    this file owns lives in prog.ed_area[n] = { areagrid = { link_t x ENTITYGRIDAREAS }, areagridmarknumber,
	    areamins, areamaxs }, made on first use (C: zeroed memory); `free` is prog.ed_free[n] (prvm_edict.luau).
	  * world_t.areagrid holds the AREA_GRIDNODES list heads at [index + 1].
	float (vec3_t) values are float32 (D-004).
	NOT YET PORTED: the physics engine support (World_Physics_*, ODE: world.c L329-2966); World_Start /
	World_End / World_Shutdown only call into it.
]]
local collision = require("./collision")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")

local world = {}

local R = f32.round
local Con_Printf, Con_DPrintf = console.Con_Printf, console.Con_DPrintf

-- world.h L33-34, progs.h L25
local AREA_GRID = 128
local AREA_GRIDNODES = AREA_GRID * AREA_GRID
local ENTITYGRIDAREAS = 16
world.AREA_GRID = AREA_GRID
world.AREA_GRIDNODES = AREA_GRIDNODES
world.ENTITYGRIDAREAS = ENTITYGRIDAREAS

-- world.h link_t L36-40
export type link_t = { entitynumber: number, prev: link_t?, next: link_t? }

-- world.h world_t L66-94 (without world_physics_t)
export type world_t = {
	filename: string, -- convenient string name
	mins: { number },
	maxs: { number },
	prog: any,
	areagrid_stats_calls: number,
	areagrid_stats_nodechecks: number,
	areagrid_stats_entitychecks: number,
	areagrid: { link_t },
	areagrid_outside: link_t,
	areagrid_bias: { number },
	areagrid_scale: { number },
	areagrid_mins: { number },
	areagrid_maxs: { number },
	areagrid_size: { number },
	areagrid_marknumber: number,
}

-- the edict's area grid data (see the header)
export type edictarea_t = {
	areagrid: { link_t },
	areagridmarknumber: number,
	areamins: { number },
	areamaxs: { number },
}

-- A zeroed world_t (C: part of the zeroed server_t / client_state_t).
function world.new(): world_t
	return {
		filename = "",
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		prog = nil,
		areagrid_stats_calls = 0,
		areagrid_stats_nodechecks = 0,
		areagrid_stats_entitychecks = 0,
		areagrid = {},
		areagrid_outside = { entitynumber = 0, prev = nil, next = nil },
		areagrid_bias = { 0, 0, 0 },
		areagrid_scale = { 0, 0, 0 },
		areagrid_mins = { 0, 0, 0 },
		areagrid_maxs = { 0, 0, 0 },
		areagrid_size = { 0, 0, 0 },
		areagrid_marknumber = 0,
	}
end

-- ent->priv.server-> areagrid / areagridmarknumber / areamins / areamaxs of edict n
local function edictarea(prog: any, n: number): edictarea_t
	local areas = prog.ed_area
	if not areas then
		areas = {}
		prog.ed_area = areas
	end
	local a = areas[n]
	if not a then
		local links: { link_t } = table.create(ENTITYGRIDAREAS)
		for i = 1, ENTITYGRIDAREAS do
			links[i] = { entitynumber = 0, prev = nil, next = nil }
		end
		a = { areagrid = links, areagridmarknumber = 0, areamins = { 0, 0, 0 }, areamaxs = { 0, 0, 0 } }
		areas[n] = a
	end
	return a
end
world.edictarea = edictarea

-- port: world.c World_Init L35-39 @xonotic-v0.8.6
function world.World_Init()
	collision.Collision_Init()
	-- World_Physics_Init(): NOT YET PORTED (ODE)
end

-- port: world.c World_ClearLink L62-66 @xonotic-v0.8.6
-- World_ClearLink is used for new headnodes
local function World_ClearLink(l: link_t)
	l.entitynumber = 0
	l.prev = l
	l.next = l
end
world.World_ClearLink = World_ClearLink

-- port: world.c World_RemoveLink L68-72 @xonotic-v0.8.6
local function World_RemoveLink(l: link_t)
	local next, prev = l.next :: link_t, l.prev :: link_t
	next.prev = prev
	prev.next = next
end
world.World_RemoveLink = World_RemoveLink

-- port: world.c World_InsertLinkBefore L74-81 @xonotic-v0.8.6
local function World_InsertLinkBefore(l: link_t, before: link_t, entitynumber: number)
	l.entitynumber = entitynumber
	l.next = before
	l.prev = before.prev
	local prev = l.prev :: link_t
	prev.next = l
	before.prev = l
end
world.World_InsertLinkBefore = World_InsertLinkBefore

-- port: world.c World_PrintAreaStats L91-97 @xonotic-v0.8.6
function world.World_PrintAreaStats(w: world_t, worldname: string)
	Con_Printf(
		"%s areagrid check stats: %d calls %d nodes (%f per call) %d entities (%f per call)\n",
		worldname,
		w.areagrid_stats_calls,
		w.areagrid_stats_nodechecks,
		w.areagrid_stats_nodechecks / w.areagrid_stats_calls,
		w.areagrid_stats_entitychecks,
		w.areagrid_stats_entitychecks / w.areagrid_stats_calls
	)
	w.areagrid_stats_calls = 0
	w.areagrid_stats_nodechecks = 0
	w.areagrid_stats_entitychecks = 0
end

-- port: world.c World_SetSize L105-138 @xonotic-v0.8.6
function world.World_SetSize(w: world_t, filename: string, mins: { number }, maxs: { number }, prog: any)
	w.filename = string.sub(filename, 1, 127) -- strlcpy(world->filename, filename, sizeof(world->filename))
	w.mins[1], w.mins[2], w.mins[3] = mins[1], mins[2], mins[3]
	w.maxs[1], w.maxs[2], w.maxs[3] = maxs[1], maxs[2], maxs[3]
	w.prog = prog

	local mingrid = cvar.Cvar_FindVar("sv_areagrid_mingridsize")
	local mingridsize = if mingrid then mingrid.value else 128 -- sv_areagrid_mingridsize.value (sv_main.c: "128")
	local developer_extra = cvar.Cvar_FindVar("developer_extra")

	-- the areagrid_marknumber is not allowed to be 0
	if w.areagrid_marknumber < 1 then
		w.areagrid_marknumber = 1
	end
	for k = 1, 3 do
		-- choose either the world box size, or a larger box to ensure the grid isn't too fine
		w.areagrid_size[k] = math.max(R(w.maxs[k] - w.mins[k]), R(AREA_GRID * mingridsize))
		-- figure out the corners of such a box, centered at the center of the world box
		w.areagrid_mins[k] = R(R(R(w.mins[k] + w.maxs[k]) - w.areagrid_size[k]) * 0.5)
		w.areagrid_maxs[k] = R(R(R(w.mins[k] + w.maxs[k]) + w.areagrid_size[k]) * 0.5)
		-- now calculate the actual useful info from that
		w.areagrid_bias[k] = -w.areagrid_mins[k]
		w.areagrid_scale[k] = R(AREA_GRID / w.areagrid_size[k])
	end
	World_ClearLink(w.areagrid_outside)
	for i = 1, AREA_GRIDNODES do
		local l = w.areagrid[i]
		if not l then
			l = { entitynumber = 0, prev = nil, next = nil }
			w.areagrid[i] = l
		end
		World_ClearLink(l)
	end
	if developer_extra and developer_extra.integer ~= 0 then
		Con_DPrintf(
			"areagrid settings: divisions %ix%ix1 : box %f %f %f : %f %f %f size %f %f %f grid %f %f %f (mingrid %f)\n",
			AREA_GRID,
			AREA_GRID,
			w.areagrid_mins[1],
			w.areagrid_mins[2],
			w.areagrid_mins[3],
			w.areagrid_maxs[1],
			w.areagrid_maxs[2],
			w.areagrid_maxs[3],
			w.areagrid_size[1],
			w.areagrid_size[2],
			w.areagrid_size[3],
			R(1.0 / w.areagrid_scale[1]),
			R(1.0 / w.areagrid_scale[2]),
			R(1.0 / w.areagrid_scale[3]),
			mingridsize
		)
	end
end

-- port: world.c World_UnlinkEdict L165-176 @xonotic-v0.8.6 (ent: edict number)
local function World_UnlinkEdict(prog: any, ent: number)
	local links = edictarea(prog, ent).areagrid
	for i = 1, ENTITYGRIDAREAS do
		local l = links[i]
		if l.prev then
			World_RemoveLink(l)
			l.prev = nil
			l.next = nil
		end
	end
end
world.World_UnlinkEdict = World_UnlinkEdict

-- port: world.c World_UnlinkAll L146-158 @xonotic-v0.8.6
function world.World_UnlinkAll(w: world_t)
	local prog = w.prog
	-- unlink all entities one by one
	local grid = w.areagrid_outside
	while grid.next ~= grid do
		World_UnlinkEdict(prog, (grid.next :: link_t).entitynumber)
	end
	for i = 1, AREA_GRIDNODES do
		grid = w.areagrid[i]
		while grid.next ~= grid do
			World_UnlinkEdict(prog, (grid.next :: link_t).entitynumber)
		end
	end
end

-- port: world.c World_EntitiesInBox L178-264 @xonotic-v0.8.6
-- (list: edict numbers at [1 .. min(numlist, maxlist)]; returns numlist)
function world.World_EntitiesInBox(
	w: world_t,
	requestmins: { number },
	requestmaxs: { number },
	maxlist: number,
	list: { number }
): number
	local prog = w.prog
	local ed_free = prog.ed_free

	-- LordHavoc: discovered this actually causes its own bugs (dm6 teleporters being too close to info_teleport_destination)
	--VectorSet(paddedmins, requestmins[0] - 1.0f, requestmins[1] - 1.0f, requestmins[2] - 1.0f);
	--VectorSet(paddedmaxs, requestmaxs[0] + 1.0f, requestmaxs[1] + 1.0f, requestmaxs[2] + 1.0f);
	local pmin1, pmin2, pmin3 = requestmins[1], requestmins[2], requestmins[3]
	local pmax1, pmax2, pmax3 = requestmaxs[1], requestmaxs[2], requestmaxs[3]

	-- FIXME: if areagrid_marknumber wraps, all entities need their
	-- ent->priv.server->areagridmarknumber reset
	w.areagrid_stats_calls += 1
	w.areagrid_marknumber += 1
	local marknumber = w.areagrid_marknumber
	local bias, scale = w.areagrid_bias, w.areagrid_scale
	local igridmins0 = math.floor(R(R(pmin1 + bias[1]) * scale[1]))
	local igridmins1 = math.floor(R(R(pmin2 + bias[2]) * scale[2]))
	local igridmaxs0 = math.floor(R(R(pmax1 + bias[1]) * scale[1])) + 1
	local igridmaxs1 = math.floor(R(R(pmax2 + bias[2]) * scale[2])) + 1
	igridmins0 = math.max(0, igridmins0)
	igridmins1 = math.max(0, igridmins1)
	igridmaxs0 = math.min(AREA_GRID, igridmaxs0)
	igridmaxs1 = math.min(AREA_GRID, igridmaxs1)

	local numlist = 0
	-- the loop over one list (C has it twice; the outside list counts an entity check only for entities it
	-- had not marked yet, the grid lists count every link)
	local function check(grid: link_t, outside: boolean)
		local l = grid.next :: link_t
		while l ~= grid do
			local ent = l.entitynumber
			local area = edictarea(prog, ent)
			if area.areagridmarknumber ~= marknumber then
				area.areagridmarknumber = marknumber
				local amins, amaxs = area.areamins, area.areamaxs
				if
					not ed_free[ent]
					and pmin1 <= amaxs[1]
					and pmax1 >= amins[1]
					and pmin2 <= amaxs[2]
					and pmax2 >= amins[2]
					and pmin3 <= amaxs[3]
					and pmax3 >= amins[3]
				then
					if numlist < maxlist then
						list[numlist + 1] = ent
					end
					numlist += 1
				end
				if outside then
					w.areagrid_stats_entitychecks += 1
				end
			end
			if not outside then
				w.areagrid_stats_entitychecks += 1
			end
			l = l.next :: link_t
		end
	end
	-- add entities not linked into areagrid because they are too big or
	-- outside the grid bounds
	if w.areagrid_outside.next then
		check(w.areagrid_outside, true)
	end
	-- add grid linked entities
	for igrid1 = igridmins1, igridmaxs1 - 1 do
		for igrid0 = igridmins0, igridmaxs0 - 1 do
			local grid = w.areagrid[igrid1 * AREA_GRID + igrid0 + 1]
			if grid.next then
				check(grid, false)
			end
		end
	end
	return numlist
end

-- port: world.c World_LinkEdict_AreaGrid L266-298 @xonotic-v0.8.6
local function World_LinkEdict_AreaGrid(w: world_t, ent: number)
	local prog = w.prog
	local entitynumber = ent

	if entitynumber <= 0 or entitynumber >= prog.max_edicts then
		Con_Printf("World_LinkEdict_AreaGrid: invalid edict %i (max_edicts is %i)\n", entitynumber, prog.max_edicts)
		return
	end

	local area = edictarea(prog, ent)
	local bias, scale = w.areagrid_bias, w.areagrid_scale
	local igridmins0 = math.floor(R(R(area.areamins[1] + bias[1]) * scale[1]))
	local igridmins1 = math.floor(R(R(area.areamins[2] + bias[2]) * scale[2]))
	local igridmaxs0 = math.floor(R(R(area.areamaxs[1] + bias[1]) * scale[1])) + 1
	local igridmaxs1 = math.floor(R(R(area.areamaxs[2] + bias[2]) * scale[2])) + 1
	if
		igridmins0 < 0
		or igridmaxs0 > AREA_GRID
		or igridmins1 < 0
		or igridmaxs1 > AREA_GRID
		or ((igridmaxs0 - igridmins0) * (igridmaxs1 - igridmins1)) > ENTITYGRIDAREAS
	then
		-- wow, something outside the grid, store it as such
		World_InsertLinkBefore(area.areagrid[1], w.areagrid_outside, entitynumber)
		return
	end

	local gridnum = 0
	for igrid1 = igridmins1, igridmaxs1 - 1 do
		for igrid0 = igridmins0, igridmaxs0 - 1 do
			World_InsertLinkBefore(
				area.areagrid[gridnum + 1],
				w.areagrid[igrid1 * AREA_GRID + igrid0 + 1],
				entitynumber
			)
			gridnum += 1
		end
	end
end

-- port: world.c World_LinkEdict L306-324 @xonotic-v0.8.6 (ent: edict number)
function world.World_LinkEdict(w: world_t, ent: number, mins: { number }, maxs: { number })
	local prog = w.prog
	local area = edictarea(prog, ent)
	-- unlink from old position first
	if area.areagrid[1].prev then
		World_UnlinkEdict(prog, ent)
	end

	-- don't add the world
	if ent == 0 then
		return
	end

	-- don't add free entities
	if prog.ed_free[ent] then
		return
	end

	area.areamins[1], area.areamins[2], area.areamins[3] = mins[1], mins[2], mins[3]
	area.areamaxs[1], area.areamaxs[2], area.areamaxs[3] = maxs[1], maxs[2], maxs[3]
	World_LinkEdict_AreaGrid(w, ent)
end

return world
