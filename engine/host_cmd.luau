--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces host_cmd.c; GPLv2 or later, see engine/cvar.luau)
]]
--[[
	Port of host_cmd.c @xonotic-v0.8.6. PARTIAL: MaxPlayers_f. Other commands are registered as
	NOT YET PORTED stubs by engine/host.luau; ported ones are listed in host_cmd.PORTED (name -> function).
]]
local cmd = require("./cmd")
local console = require("./console")
local cvar = require("./cvar")
local libc = require("./_port/libc")

local host_cmd = {}

local MAX_SCOREBOARD = 255 -- quakedef.h

-- set by host.luau: svs (maxclients_next) and sv.active
host_cmd.svs = { maxclients = 8, maxclients_next = 8 }
host_cmd.sv_active = false

-- port: host_cmd.c MaxPlayers_f L2517-2542 @xonotic-v0.8.6
local function MaxPlayers_f()
	if cmd.Cmd_Argc() ~= 2 then
		console.Con_Printf('"maxplayers" is "%u"\n', host_cmd.svs.maxclients_next)
		return
	end
	if host_cmd.sv_active then
		console.Con_Print("maxplayers can not be changed while a server is running.\n")
		console.Con_Print('It will be changed on next server startup ("map" command).\n')
	end
	local n = libc.atoi(cmd.Cmd_Argv(1))
	n = math.clamp(n, 1, MAX_SCOREBOARD)
	console.Con_Printf('"maxplayers" set to "%u"\n', n)
	host_cmd.svs.maxclients_next = n
	if n == 1 then
		cvar.Cvar_Set("deathmatch", "0")
	else
		cvar.Cvar_Set("deathmatch", "1")
	end
end

host_cmd.PORTED = {
	maxplayers = MaxPlayers_f,
} :: { [string]: () -> () }

return host_cmd
