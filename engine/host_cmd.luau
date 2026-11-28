--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces host_cmd.c; GPLv2 or later, see engine/cvar.luau)
]]
--[[
	Port of host_cmd.c @xonotic-v0.8.6. PARTIAL: MaxPlayers_f, Host_Map_f (the `map` command; it runs
	sv_main.SV_SpawnServer, whose compiled-QuakeC hook is sv_main.vm_setup_opts), and the signon client commands
	Host_PreSpawn_f, Host_Spawn_f, Host_Begin_f (host_cmd.CLIENTCOMMANDS). Other commands are registered as
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

--[[
	The signon client commands (Cmd_AddCommand_WithClientCommand("prespawn", NULL, Host_PreSpawn_f, ...), L3067-3069:
	no console function, client function only). They act on server.host_client; SV_ReadClientMessage (sv_user.c,
	not ported) is what runs them for a network client, so they are reached through host_cmd.CLIENTCOMMANDS.
]]
local svc_time, svc_setangle, svc_lightstyle, svc_updatename, svc_updatefrags = 7, 10, 12, 13, 14 -- protocol.h
local svc_updatecolors, svc_updatestat, svc_signonnum = 17, 3, 25
local STAT_TOTALSECRETS, STAT_TOTALMONSTERS, STAT_SECRETS, STAT_MONSTERS = 11, 12, 13, 14 -- quakedef.h
local NUM_SPAWN_PARMS, MAX_LIGHTSTYLES, MAX_CL_STATS = 16, 256, 256

-- engine modules that require this one, required on first use
local function mods(): (any, any, any, any, any)
	return require("./server"),
		require("./sv_main"),
		require("./common"),
		require("./prvm_edict"),
		require("./prvm_cmds")
end

--[[
==================
Host_PreSpawn_f
==================
]]
-- port: host_cmd.c Host_PreSpawn_f L1851-1870 @xonotic-v0.8.6
local function Host_PreSpawn_f()
	local server, _, common = mods()
	local host_client = server.host_client
	local sv = server.sv
	if host_client.prespawned then
		console.Con_Print("prespawn not valid -- already prespawned\n")
		return
	end
	host_client.prespawned = true

	if host_client.netconnection then
		common.SZ_Write(host_client.netconnection.message, buffer.readstring(sv.signon.data, 0, sv.signon.cursize))
		common.MSG_WriteByte(host_client.netconnection.message, svc_signonnum)
		common.MSG_WriteByte(host_client.netconnection.message, 2)
		host_client.sendsignon = 0 -- enable unlimited sends again
	end

	-- reset the name change timer because the client will send name soon
	host_client.nametime = 0
end

--[[
==================
Host_Spawn_f
==================
]]
-- port: host_cmd.c Host_Spawn_f L1877-2013 @xonotic-v0.8.6
local function Host_Spawn_f()
	local server, sv_main, common, prvm_edict, prvm_cmds = mods()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local host_client = server.host_client
	local stats: { [number]: number } = table.create(MAX_CL_STATS) -- int stats[MAX_CL_STATS] (0-based)
	local function GOFS(g: string): number
		return prvm_cmds.GlobalOfs(prog, g)
	end
	local function SET_GF(g: string, v: number)
		local o = GOFS(g)
		if o >= 0 then
			buffer.writef32(prog.globals, o * 4, v)
		end
	end
	local function SET_GI(g: string, v: number)
		local o = GOFS(g)
		if o >= 0 then
			buffer.writei32(prog.globals, o * 4, v)
		end
	end
	local function GF(g: string): number
		local o = GOFS(g)
		return if o >= 0 then buffer.readf32(prog.globals, o * 4) else 0
	end
	-- PRVM_serverfunction(name): the prog.funcoffsets cache engine/sv_main.luau and engine/sv_phys.luau use
	local function serverfunction(name: string): number
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
	local function EV(e: number, f: string, i: number): number
		local o = prvm_edict.FieldOfs(prog, f)
		return if o >= 0 then buffer.readf32(prog.edictsfields, (e * prog.entityfields + o + i) * 4) else 0
	end

	if not host_client.prespawned then
		console.Con_Print("Spawn not valid -- not yet prespawned\n")
		return
	end
	if host_client.spawned then
		console.Con_Print("Spawn not valid -- already spawned\n")
		return
	end
	host_client.spawned = true

	-- reset name change timer again because they might want to change name
	-- again in the first 5 seconds after connecting
	host_client.nametime = 0

	-- LordHavoc: moved this above the QC calls at FrikaC's request
	-- LordHavoc: commented this out
	--if (host_client->netconnection)
	--	SZ_Clear (&host_client->netconnection->message);

	-- run the entrance script
	if sv.loadgame then
		-- loaded games are fully initialized already
		if serverfunction("RestoreGame") ~= 0 then
			console.Con_DPrint("Calling RestoreGame\n")
			SET_GF("time", sv.time)
			SET_GI("self", host_client.edict)
			prvm_edict.ExecuteProgram(prog, serverfunction("RestoreGame"), "QC function RestoreGame is missing")
		end
	else
		--Con_Printf("Host_Spawn_f: host_client->edict->netname = %s, ...);

		-- copy spawn parms out of the client_t
		local parm1 = GOFS("parm1")
		for i = 0, NUM_SPAWN_PARMS - 1 do
			buffer.writef32(prog.globals, (parm1 + i) * 4, host_client.spawn_parms[i])
		end

		-- call the spawn function
		host_client.clientconnectcalled = true
		SET_GF("time", sv.time)
		SET_GI("self", host_client.edict)
		prvm_edict.ExecuteProgram(prog, serverfunction("ClientConnect"), "QC function ClientConnect is missing")

		if cvar.cls_state_dedicated then
			console.Con_Printf("%s connected\n", host_client.name.str)
		end

		SET_GF("time", sv.time)
		prvm_edict.ExecuteProgram(prog, serverfunction("PutClientInServer"), "QC function PutClientInServer is missing")
	end

	if not host_client.netconnection then
		return
	end
	local msg = host_client.netconnection.message

	-- send time of update
	common.MSG_WriteByte(msg, svc_time)
	common.MSG_WriteFloat(msg, sv.time)

	-- send all current names, colors, and frag counts
	for i = 0, svs.maxclients - 1 do
		local c = sv_main.client(i)
		if not c.active then
			continue
		end
		common.MSG_WriteByte(msg, svc_updatename)
		common.MSG_WriteByte(msg, i)
		common.MSG_WriteString(msg, c.name.str)
		common.MSG_WriteByte(msg, svc_updatefrags)
		common.MSG_WriteByte(msg, i)
		common.MSG_WriteShort(msg, c.frags)
		common.MSG_WriteByte(msg, svc_updatecolors)
		common.MSG_WriteByte(msg, i)
		common.MSG_WriteByte(msg, c.colors)
	end

	-- send all current light styles
	for i = 0, MAX_LIGHTSTYLES - 1 do
		if (sv.lightstyles[i] or "") ~= "" then
			common.MSG_WriteByte(msg, svc_lightstyle)
			common.MSG_WriteByte(msg, i) -- (char)i
			common.MSG_WriteString(msg, sv.lightstyles[i])
		end
	end

	-- send some stats
	common.MSG_WriteByte(msg, svc_updatestat)
	common.MSG_WriteByte(msg, STAT_TOTALSECRETS)
	common.MSG_WriteLong(msg, libc.toint(GF("total_secrets")))

	common.MSG_WriteByte(msg, svc_updatestat)
	common.MSG_WriteByte(msg, STAT_TOTALMONSTERS)
	common.MSG_WriteLong(msg, libc.toint(GF("total_monsters")))

	common.MSG_WriteByte(msg, svc_updatestat)
	common.MSG_WriteByte(msg, STAT_SECRETS)
	common.MSG_WriteLong(msg, libc.toint(GF("found_secrets")))

	common.MSG_WriteByte(msg, svc_updatestat)
	common.MSG_WriteByte(msg, STAT_MONSTERS)
	common.MSG_WriteLong(msg, libc.toint(GF("killed_monsters")))

	-- send a fixangle
	-- Never send a roll angle, because savegames can catch the server
	-- in a state where it is expecting the client to correct the angle
	-- and it won't happen if the game was just loaded, so you wind up
	-- with a permanent head tilt
	if sv.loadgame then
		common.MSG_WriteByte(msg, svc_setangle)
		common.MSG_WriteAngle(msg, EV(host_client.edict, "v_angle", 0), sv.protocol)
		common.MSG_WriteAngle(msg, EV(host_client.edict, "v_angle", 1), sv.protocol)
		common.MSG_WriteAngle(msg, 0, sv.protocol)
	else
		common.MSG_WriteByte(msg, svc_setangle)
		common.MSG_WriteAngle(msg, EV(host_client.edict, "angles", 0), sv.protocol)
		common.MSG_WriteAngle(msg, EV(host_client.edict, "angles", 1), sv.protocol)
		common.MSG_WriteAngle(msg, 0, sv.protocol)
	end

	sv_main.SV_WriteClientdataToMessage(host_client, host_client.edict, msg, stats)

	common.MSG_WriteByte(msg, svc_signonnum)
	common.MSG_WriteByte(msg, 3)
end

--[[
==================
Host_Begin_f
==================
]]
-- port: host_cmd.c Host_Begin_f L2020-2047 @xonotic-v0.8.6
local function Host_Begin_f()
	local server = mods()
	local host_client = server.host_client
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	if not host_client.spawned then
		console.Con_Print("Begin not valid -- not yet spawned\n")
		return
	end
	if host_client.begun then
		console.Con_Print("Begin not valid -- already begun\n")
		return
	end
	host_client.begun = true

	-- LordHavoc: note: this code also exists in SV_DropClient
	if sv.loadgame then
		local i = 0
		while i < svs.maxclients do
			local c = svs.clients[i]
			if c and c.active and not c.spawned then
				break
			end
			i += 1
		end
		if i == svs.maxclients then
			console.Con_Printf("Loaded game, everyone rejoined - unpausing\n")
			sv.loadgame = false
			sv.paused = false -- we're basically done with loading now
		end
	end
end

-- the client functions of client commands (name -> function; run with server.host_client set)
host_cmd.CLIENTCOMMANDS = {
	prespawn = Host_PreSpawn_f,
	spawn = Host_Spawn_f,
	begin = Host_Begin_f,
} :: { [string]: () -> () }

--[[
	The Cmd_AddCommand_WithClientCommand registrations of Host_InitCommands (host_cmd.c L3018-3090) and
	SV_InitOperatorCommands (sv_main.c L451-452): { name, console function is NULL }. engine/host.luau registers
	every command of engine/_port/sv_init_defs.luau as a console command (the table does not record the client
	function), so Host_InitClientCommands gives these their client function (the ported one from CLIENTCOMMANDS
	or a stub that logs NOT YET PORTED) and clears the console function where C passes NULL. Call it once after
	the command registration of host.Host_Init_Dedicated (before Cmd_SaveInitState); it is idempotent.
]]
host_cmd.WITHCLIENTCOMMAND = {
	{ "status", false },
	{ "god", true },
	{ "notarget", true },
	{ "fly", true },
	{ "noclip", true },
	{ "give", true },
	{ "say", false },
	{ "say_team", false },
	{ "tell", false },
	{ "kill", true },
	{ "pause", false },
	{ "ping", false },
	{ "name", false },
	{ "color", false },
	{ "rate", false },
	{ "rate_burstsize", false },
	{ "pmodel", false },
	{ "playermodel", false },
	{ "playerskin", false },
	{ "prespawn", true },
	{ "spawn", true },
	{ "begin", true },
	{ "pings", true },
	{ "sv_startdownload", true },
	{ "download", true },
} :: { { any } }

function host_cmd.Host_InitClientCommands()
	local byname: { [string]: any } = {}
	for _, c in cmd.commands() do
		byname[c.name] = c
	end
	for _, d in host_cmd.WITHCLIENTCOMMAND do
		local name, noconsole = d[1] :: string, d[2] :: boolean
		local c = byname[name]
		if c then
			if noconsole then
				c.consolefunction = nil
			end
			c.clientfunction = host_cmd.CLIENTCOMMANDS[name]
				or host_cmd.PORTED[name]
				or function()
					notPorted("client command " .. name)
				end
		end
	end
end

return host_cmd
