--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces host_cmd.c; GPLv2 or later, see engine/cvar.luau)
]]
--[[
	Port of host_cmd.c @xonotic-v0.8.6. PARTIAL: MaxPlayers_f, Host_Map_f (the `map` command; it runs
	sv_main.SV_SpawnServer, whose compiled-QuakeC hook is sv_main.vm_setup_opts). Other commands are registered as
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

-- host_cmd.c L32: qboolean allowcheats = false;
host_cmd.allowcheats = false

local notported: { [string]: boolean } = {}
local function notPorted(what: string)
	if not notported[what] then
		notported[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

--[[
======================
Host_Map_f

handle a
map <servername>
command from the console.  Active clients are kicked off.
======================
]]
-- port: host_cmd.c Host_Map_f L356-396 @xonotic-v0.8.6
local function Host_Map_f()
	local level

	if cmd.Cmd_Argc() ~= 2 then
		console.Con_Print("map <levelname> : start a new game (kicks off all players)\n")
		return
	end

	-- GAME_DELUXEQUAKE - clear warpmark (used by QC): gamemode is GAME_XONOTIC

	-- cls.demonum = -1;		// stop demo loop in case this fails (client)

	-- CL_Disconnect(): returns at once on a dedicated server (cls.state == ca_dedicated)
	if host_cmd.sv_active then
		notPorted("Host_ShutdownServer (host.c L486-536) in Host_Map_f")
	end
	-- (Host_ShutdownServer returns at once while !sv.active)

	local svs = host_cmd.svs :: any
	if svs.maxclients ~= svs.maxclients_next then
		svs.maxclients = svs.maxclients_next
		-- Mem_Free(svs.clients); svs.clients = Mem_Alloc(sv_mempool, sizeof(client_t) * svs.maxclients): zeroed
		svs.clients = {}
	end

	-- key_dest = key_game (client; CONFIG_MENU MR_ToggleMenu is client only)

	svs.serverflags = 0 -- haven't completed an episode yet
	local cheats = cvar.Cvar_FindVar("sv_cheats")
	host_cmd.allowcheats = cheats ~= nil and cheats.integer ~= 0
	level = string.sub(cmd.Cmd_Argv(1), 1, 127) -- strlcpy(level, Cmd_Argv(1), sizeof(level)) (MAX_QPATH)
	require("./sv_main").SV_SpawnServer(level) -- sv_main requires this module
	-- if (sv.active && cls.state == ca_disconnected) CL_EstablishConnection(...): never on a dedicated server
end

host_cmd.PORTED = {
	maxplayers = MaxPlayers_f,
	map = Host_Map_f,
} :: { [string]: () -> () }

return host_cmd
