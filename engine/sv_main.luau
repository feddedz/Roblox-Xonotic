--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces sv_main.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of sv_main.c @xonotic-v0.8.6. PARTIAL: SV_VM_Setup up to PRVM_Prog_Load, the SVVM_* edict hooks,
	SV_GetModelByIndex, SV_GetModelFromEdict.
	NOT YET PORTED: the PROGHEADER_CRC branch that sets engine field offsets from entvars_t (applies to
	Xonotic: progs crc 5927), the remaining PRVM_Prog_Load steps (autocvar_* globals from cvars, .po
	translation, PRVM_Init_Exec, field/global offset lookup), the rest of SV_VM_Setup, and everything else.
]]
local prvm_edict = require("./prvm_edict")
local prvm_offsets = require("./prvm_offsets")
local svvm_cmds = require("./svvm_cmds")
local host_cmd = require("./host_cmd")
local cvar = require("./cvar")
local libc = require("./_port/libc")
local common = require("./common")
local console = require("./console")
local fs = require("./fs")
local model_shared = require("./model_shared")
require("./model_brush") -- installs model_shared.Mod_IBSP_Load (the Q3 BSP loader the world model needs)
local prvm_cmds = require("./prvm_cmds")
local world = require("./world")

local sv_main = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

--[[
	client_t (server.h L201-337): svs.clients[num] (0-based, host_cmd.svs.clients) is a table with the C field
	names. Each char array of a client_t (name, old_name, playermodel, playerskin) is one C pointer, so each is
	one string reference { str } for PRVM_SetEngineString that keeps its identity for the life of the slot
	(memset of the client keeps the array addresses: ClearClient empties their text). spawn_parms[0..15] are
	floats (0-based); cmd is the usercmd_t (a table, nil fields = 0); edict is the edict number (nil = NULL);
	netconnection is nil for a bot (no network clients connect yet, M6-NET). unreliablemsg is a sizebuf_t of
	NET_MAXMESSAGE bytes. The csqc entity tables, entity databases, stats and download state are not held yet
	(their users are the network code, M6-NET).
]]
local NULL_BOTCLIENT = { str = "null/botclient" } -- string literal in SVVM_init_edict
local MAX_SCOREBOARDNAME = 128 -- quakedef.h L145
local NET_MAXMESSAGE = 65536 -- quakedef.h L137

-- memset(client, 0, sizeof(*client)) (the char arrays keep their addresses)
local function ClearClient(c: any)
	local name, old_name = c.name or { str = "" }, c.old_name or { str = "" }
	local playermodel, playerskin = c.playermodel or { str = "" }, c.playerskin or { str = "" }
	table.clear(c)
	name.str, old_name.str, playermodel.str, playerskin.str = "", "", "", ""
	c.active = false
	c.clientconnectcalled = false
	c.prespawned = false
	c.spawned = false
	c.begun = false
	c.sendsignon = 0
	c.rate = 0
	c.rate_burstsize = 0
	c.connecttime = 0
	c.keepalivetime = 0
	c.netconnection = nil
	c.movesequence = 0
	c.movement_highestsequence_seen = 0
	c.cmd = {}
	c.edict = nil
	c.ping = 0
	c.clmovement_disabletimeout = 0
	c.clmovement_inputtimeout = 0
	c.spawn_parms = {}
	for i = 0, 15 do -- NUM_SPAWN_PARMS (server.h L185)
		c.spawn_parms[i] = 0
	end
	c.name, c.old_name = name, old_name
	c.colors, c.old_colors = 0, 0
	c.frags, c.old_frags = 0, 0
	c.playermodel, c.playerskin = playermodel, playerskin
	c.old_model, c.old_skin = "", ""
	c.netaddress = ""
	c.nametime = 0
	c.latestframenum = 0
	c.weaponmodel = ""
	c.weaponmodelindex = 0
	c.clientcamera = 0
	c.unreliablemsg = { data = buffer.create(0), cursize = 0, maxsize = 0 } -- data / maxsize set by SV_ConnectClient
	c.unreliablemsg_splitpoints = 0
	c.unreliablemsg_splitpoint = {}
	c.download_file = nil
	c.download_expectedposition = 0
	c.download_started = false
	c.download_name = ""
	c.download_deflate = false
	c.fixangle_angles_set = false
	c.fixangle_angles = { 0, 0, 0 }
	c.sv_demo_file = nil
	c.num_skippedentityframes = 0
	c.lastmovesequence = 0
end

-- svs.clients + num (svs.clients is Mem_Alloc'd zeroed memory: a slot is created cleared on first use)
local function client(num: number): any
	local svs = host_cmd.svs :: any
	svs.clients = svs.clients or {}
	local c = svs.clients[num]
	if not c then
		c = {}
		ClearClient(c)
		svs.clients[num] = c
	end
	return c
end
sv_main.client = client
sv_main.ClearClient = ClearClient

local function setf(prog: any, e: number, field: string, v: number)
	local o = prvm_edict.FieldOfs(prog, field)
	if o >= 0 then
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + o) * 4, v)
	end
end
local function seti(prog: any, e: number, field: string, v: number)
	local o = prvm_edict.FieldOfs(prog, field)
	if o >= 0 then
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + o) * 4, v)
	end
end

-- port: sv_main.c SVVM_begin_increase_edicts L3587-3591 @xonotic-v0.8.6
function sv_main.SVVM_begin_increase_edicts(_prog: any)
	-- links don't survive the transition, so unlink everything
	require("./world").World_UnlinkAll(require("./server").sv.world)
end

-- port: sv_main.c SVVM_end_increase_edicts L3593-3602 @xonotic-v0.8.6
function sv_main.SVVM_end_increase_edicts(prog: any)
	-- sv_phys requires sv_main, so it is required here
	local SV_LinkEdict = require("./sv_phys").SV_LinkEdict
	-- link every entity except world
	-- engine quirk kept: C starts ent at prog->edicts (edict 0) while i starts at 1, so ent is edict i - 1:
	-- edicts 0 .. num_edicts - 2 are relinked (SV_LinkEdict skips the world), the last one is not
	local amin, amax = prvm_edict.FieldOfs(prog, "absmin"), prvm_edict.FieldOfs(prog, "absmax")
	local f = prog.edictsfields
	for i = 1, prog.num_edicts - 1 do
		local ent = i - 1
		local base = ent * prog.entityfields
		if
			not prog.ed_free[ent]
			and not (
				buffer.readf32(f, (base + amin) * 4) == buffer.readf32(f, (base + amax) * 4)
				and buffer.readf32(f, (base + amin + 1) * 4) == buffer.readf32(f, (base + amax + 1) * 4)
				and buffer.readf32(f, (base + amin + 2) * 4) == buffer.readf32(f, (base + amax + 2) * 4)
			)
		then
			SV_LinkEdict(ent)
		end
	end
end

-- port: sv_main.c SVVM_init_edict L3604-3655 @xonotic-v0.8.6
function sv_main.SVVM_init_edict(prog: any, e: number)
	-- LordHavoc: for consistency set these here
	local num = e - 1

	-- e->priv.server->move = false; // don't move on first frame (prog.ed_move, read by engine/sv_phys.luau)
	prog.ed_move = prog.ed_move or {}
	prog.ed_move[e] = false

	if num >= 0 and num < host_cmd.svs.maxclients then
		local c = client(num)
		-- set colormap and team on newly created player entity
		setf(prog, e, "colormap", num + 1)
		setf(prog, e, "team", bit32.band(c.colors, 15) + 1)
		seti(prog, e, "netname", prvm_edict.PRVM_SetEngineString(prog, c.name))
		setf(prog, e, "clientcolors", c.colors)
		seti(prog, e, "playermodel", prvm_edict.PRVM_SetEngineString(prog, c.playermodel))
		seti(prog, e, "playerskin", prvm_edict.PRVM_SetEngineString(prog, c.playerskin))
		if c.netconnection ~= nil then
			notPorted("SVVM_init_edict netaddress/crypto of connected clients (needs netconn, M6-NET)")
		else
			seti(prog, e, "netaddress", prvm_edict.PRVM_SetEngineString(prog, NULL_BOTCLIENT))
		end
		seti(prog, e, "crypto_idfp", 0)
		setf(prog, e, "crypto_idfp_signed", 0)
		seti(prog, e, "crypto_keyfp", 0)
		seti(prog, e, "crypto_mykeyfp", 0)
		seti(prog, e, "crypto_encryptmethod", 0)
		seti(prog, e, "crypto_signmethod", 0)
	end
end

-- port: sv_main.c SVVM_free_edict L3657-3684 @xonotic-v0.8.6
function sv_main.SVVM_free_edict(prog: any, e: number)
	world.World_UnlinkEdict(prog, e) -- unlink from world bsp
	seti(prog, e, "model", 0)
	setf(prog, e, "takedamage", 0)
	setf(prog, e, "modelindex", 0)
	setf(prog, e, "colormap", 0)
	setf(prog, e, "skin", 0)
	setf(prog, e, "frame", 0)
	for _, f in { "origin", "angles" } do
		local o = prvm_edict.FieldOfs(prog, f)
		if o >= 0 then
			buffer.fill(prog.edictsfields, (e * prog.entityfields + o) * 4, 0, 12)
		end
	end
	setf(prog, e, "nextthink", -1)
	setf(prog, e, "solid", 0)

	prvm_cmds.VM_RemoveEdictSkeleton(prog, e)
	notPorted(
		"World_Physics_RemoveFromEntity / World_Physics_RemoveJointFromEntity (world.c, ODE) and the csqc entity versions (sv.csqcentityversion, csqcentitysendflags, M6-NET) in SVVM_free_edict"
	)
end

-- sv (engine/server.luau) and current_skill (sv_main.c L3377): set by SV_SpawnServer, M4
local server = require("./server")
sv_main.sv = server.sv
sv_main.current_skill = 0
prvm_edict.sv_time = function(): number
	return server.sv.time
end

local SPAWNFLAG_NOT_EASY, SPAWNFLAG_NOT_MEDIUM, SPAWNFLAG_NOT_HARD, SPAWNFLAG_NOT_DEATHMATCH = 256, 512, 1024, 2048 -- server.h L381-384

-- port: sv_main.c SVVM_load_edict L3714-3734 @xonotic-v0.8.6 (gamemode is GAME_XONOTIC, not Transfusion)
function sv_main.SVVM_load_edict(prog: any, ent: number): boolean
	-- remove things from different skill levels or deathmatch
	local sf = prvm_edict.FieldOfs(prog, "spawnflags")
	local flags = libc.toint(buffer.readf32(prog.edictsfields, (ent * prog.entityfields + sf) * 4))
	local dm = cvar.Cvar_FindVar("deathmatch")
	if dm and dm.integer ~= 0 then
		if bit32.band(flags, SPAWNFLAG_NOT_DEATHMATCH) ~= 0 then
			return false
		end
	elseif
		(sv_main.current_skill <= 0 and bit32.band(flags, SPAWNFLAG_NOT_EASY) ~= 0)
		or (sv_main.current_skill == 1 and bit32.band(flags, SPAWNFLAG_NOT_MEDIUM) ~= 0)
		or (sv_main.current_skill >= 2 and bit32.band(flags, SPAWNFLAG_NOT_HARD) ~= 0)
	then
		return false
	end
	return true
end

local P = common.PROTOCOL
local function oldprotocol(p: number): boolean
	return p == P.QUAKE
		or p == P.QUAKEDP
		or p == P.NEHAHRAMOVIE
		or p == P.NEHAHRABJP
		or p == P.NEHAHRABJP2
		or p == P.NEHAHRABJP3
end

-- port: sv_main.c SV_ModelIndex L2893-2948 @xonotic-v0.8.6
-- (svs.threaded is false: the server runs in the host frame, so the single threaded branch loads the model)
function sv_main.SV_ModelIndex(s: string?, precachemode: number): number
	local sv = server.sv
	local i
	local limit = if oldprotocol(sv.protocol) then 256 else server.MAX_MODELS
	if not s or s == "" then
		return 0
	end
	-- testing
	--if (precachemode == 2)
	--	return 0;
	local filename = string.sub(s :: string, 1, server.MAX_QPATH - 1) -- strlcpy(filename, s, sizeof(filename))
	i = 2
	while i < limit do
		local cur = sv.model_precache[i]
		if not cur or cur == "" then
			if precachemode ~= 0 then
				if
					sv.state ~= server.ss_loading
					and (
						oldprotocol(sv.protocol)
						or sv.protocol == P.DARKPLACES1
						or sv.protocol == P.DARKPLACES2
						or sv.protocol == P.DARKPLACES3
						or sv.protocol == P.DARKPLACES4
						or sv.protocol == P.DARKPLACES5
					)
				then
					console.Con_Printf(
						'SV_ModelIndex("%s"): precache_model can only be done in spawn functions\n',
						filename
					)
					return 0
				end
				if precachemode == 1 then
					console.Con_Printf(
						'SV_ModelIndex("%s"): not precached (fix your code), precaching anyway\n',
						filename
					)
				end
				sv.model_precache[i] = filename
				local parent = if string.sub(s :: string, 1, 1) == "*" then sv.worldname else nil
				if sv.state == server.ss_loading then
					-- running from SV_SpawnServer which is launched from the client console command interpreter
					sv.models[i] = model_shared.Mod_ForName(sv.model_precache[i], true, false, parent)
				else
					-- (svs.threaded: Mod_FindName only; never true here)
					-- running single threaded, so we can load the model here
					sv.models[i] = model_shared.Mod_ForName(sv.model_precache[i], true, false, parent)
					common.MSG_WriteByte(sv.reliable_datagram, 54) -- svc_precache
					common.MSG_WriteShort(sv.reliable_datagram, i)
					common.MSG_WriteString(sv.reliable_datagram, filename)
				end
				return i
			end
			console.Con_Printf('SV_ModelIndex("%s"): not precached\n', filename)
			return 0
		end
		if cur == filename then
			return i
		end
		i += 1
	end
	console.Con_Printf('SV_ModelIndex("%s"): i (%i) == MAX_MODELS (%i)\n', filename, i, server.MAX_MODELS)
	return 0
end

-- sv_main.c SV_SoundIndex L2956-2996 is in engine/svvm_cmds.luau (ported there with the sound builtins)
sv_main.SV_SoundIndex = svvm_cmds.SV_SoundIndex

-- port: sv_main.c SV_GetModelByIndex L3089-3092 @xonotic-v0.8.6 (nil = NULL)
function sv_main.SV_GetModelByIndex(modelindex: number): any
	return if modelindex > 0 and modelindex < server.MAX_MODELS then server.sv.models[modelindex] else nil
end

-- port: sv_main.c SV_GetModelFromEdict L3094-3102 @xonotic-v0.8.6 (ed: edict number, nil = NULL; 0 is the world)
function sv_main.SV_GetModelFromEdict(ed: number?): any
	local prog = cvar.prvm_prog_list[0] -- SVVM_prog
	if ed == nil or prog.ed_free[ed] then
		return nil
	end
	local modelindex = libc.toint(
		buffer.readf32(prog.edictsfields, (ed * prog.entityfields + prvm_edict.FieldOfs(prog, "modelindex")) * 4)
	)
	return if modelindex > 0 and modelindex < server.MAX_MODELS then server.sv.models[modelindex] else nil
end

local MAX_EDICTS = 32768 -- quakedef.h (non-DP_SMALLMEMORY)

-- port: sv_main.c SV_VM_Setup L3736-3924 @xonotic-v0.8.6 (PARTIAL, see header)
-- opts (port support): onStub is passed to svvm_cmds.install; maxclients overrides svs.maxclients; install(prog)
-- runs at the end (the host installs the compiled QuakeC there: game/generated/progs).
export type VMSetupOpts = {
	onStub: ((number, string, any) -> ())?,
	maxclients: number?,
	install: ((any) -> ())?,
}
function sv_main.SV_VM_Setup(progsdata: buffer, opts: VMSetupOpts?)
	local prog: any = prvm_edict.NewProg("server")
	svvm_cmds.install(prog, opts and opts.onStub)
	prog.max_edicts = 512
	prog.limit_edicts = MAX_EDICTS
	prog.reserved_edicts = (opts and opts.maxclients) or host_cmd.svs.maxclients
	prog.extensionstring = require("./_port/extensions").sv
	prog.init_edict = sv_main.SVVM_init_edict
	prog.free_edict = sv_main.SVVM_free_edict
	prog.load_edict = sv_main.SVVM_load_edict
	prog.begin_increase_edicts = sv_main.SVVM_begin_increase_edicts
	prog.end_increase_edicts = sv_main.SVVM_end_increase_edicts
	prog.loadintoworld = true
	prvm_edict.PRVM_Prog_Load(prog, "progs.dat", progsdata, prvm_offsets.server_fields, prvm_offsets.server_globals)
	-- OP_STATE is always supported on server because we add fields/globals for it
	-- (prog->flag |= PRVM_OP_STATE: the interpreter and the compiled code always run OP_STATE)
	svvm_cmds.VM_CustomStats_Clear() --[515]: csqc
	notPorted("SV_Prepare_CSQC (sv_main.c L3194-3233: csprogs.dat for clients, M6-NET)")
	if opts and opts.install then
		opts.install(prog)
	end
	return prog
end

-- port: protocol.c Protocol_EnumForName L84-91 @xonotic-v0.8.6 (protocol.c has no module yet)
local protocolversioninfo = { -- protocol.c L59-82 (number, version, name)
	{ 3504, P.DARKPLACES7, "DP7" },
	{ 3503, P.DARKPLACES6, "DP6" },
	{ 3502, P.DARKPLACES5, "DP5" },
	{ 3501, P.DARKPLACES4, "DP4" },
	{ 3500, P.DARKPLACES3, "DP3" },
	{ 97, P.DARKPLACES2, "DP2" },
	{ 96, P.DARKPLACES1, "DP1" },
	{ 15, P.QUAKEDP, "QUAKEDP" },
	{ 15, P.QUAKE, "QUAKE" },
	{ 28, P.QUAKEWORLD, "QW" },
	{ 250, P.NEHAHRAMOVIE, "NEHAHRAMOVIE" },
	{ 10000, P.NEHAHRABJP, "NEHAHRABJP" },
	{ 10001, P.NEHAHRABJP2, "NEHAHRABJP2" },
	{ 10002, P.NEHAHRABJP3, "NEHAHRABJP3" },
}
local function Protocol_EnumForName(s: string): number
	for _, info in protocolversioninfo do
		if libc.strcasecmp(s, info[3]) == 0 then
			return info[2]
		end
	end
	return P.UNKNOWN
end

-- port: protocol.c Protocol_Names L120-132 @xonotic-v0.8.6 (buffer of 1024)
-- engine quirk kept: the separator is only added for i > 1, so the first two names run together ("DP7DP6 DP5")
local function Protocol_Names(buffersize: number): string
	local out = ""
	for i, info in protocolversioninfo do
		if i - 1 > 1 then
			out = string.sub(out .. " ", 1, buffersize - 1) -- strlcat
		end
		out = string.sub(out .. info[3], 1, buffersize - 1)
	end
	return out
end

-- port: fs.c FS_StripExtension L3421-3443 @xonotic-v0.8.6 (fs.c's module has no copy yet)
local function FS_StripExtension(s: string, size_out: number): string
	if size_out == 0 then
		return ""
	end
	local out = {}
	local last: number? = nil
	local n = 0
	while n < #s and size_out > 1 do
		local currentchar = string.sub(s, n + 1, n + 1)
		if currentchar == "\0" then
			break
		end
		if currentchar == "." then
			last = n
		elseif currentchar == "/" or currentchar == "\\" or currentchar == ":" then
			last = nil
		end
		n += 1
		out[n] = currentchar
		size_out -= 1
	end
	local r = table.concat(out)
	if last then
		return string.sub(r, 1, last)
	end
	return r
end

local SOLID_BSP, MOVETYPE_PUSH = 4, 7 -- server.h L344, L364
local NUM_SPAWN_PARMS = 16 -- server.h L185

-- PRVM_serverfunction(name) (the function offsets of the prog, the cache engine/sv_phys.luau also uses:
-- prog.funcoffsets[name], 0 = none); `PRVM_serverfunction(x) = 0` stores 0 there
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

local function cv(name: string): any -- a cvar_t of the dedicated init path (registered by host.luau)
	local v = cvar.Cvar_FindVar(name)
	if not v then
		error("SV_SpawnServer: cvar " .. name .. " is not registered (run host.Host_Init_Dedicated first)", 0)
	end
	return v
end

local function SET_GF(prog: any, g: string, v: number)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writef32(prog.globals, o * 4, v)
	end
end
local function SET_GI(prog: any, g: string, v: number)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writei32(prog.globals, o * 4, v)
	end
end

-- how SV_VM_Setup is run by SV_SpawnServer (port support; see SV_VM_Setup): the host / tests set install
-- (compiled QuakeC) and onStub here
sv_main.vm_setup_opts = nil :: VMSetupOpts?

--[[
================
SV_SpawnServer

This is called at the start of each level
================
]]
-- port: sv_main.c SV_SpawnServer L3272-3582 @xonotic-v0.8.6
-- (dedicated server: cls.state == ca_dedicated; the client-side calls are listed where they are skipped)
function sv_main.SV_SpawnServer(servername: string)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local svs = host_cmd.svs :: any
	local ent
	local i
	local entities: string?
	local worldmodel
	local MAX_QPATH = server.MAX_QPATH
	local dedicated = cvar.cls_state_dedicated

	console.Con_DPrintf("SpawnServer: %s\n", servername)

	-- char modelname[sizeof(sv.worldname)]
	local modelname = string.sub(string.format("maps/%s.bsp", servername), 1, MAX_QPATH - 1)

	if not fs.FS_FileExists(modelname) then
		modelname = string.sub(string.format("maps/%s", servername), 1, MAX_QPATH - 1)
		if not fs.FS_FileExists(modelname) then
			console.Con_Printf("SpawnServer: no map file named maps/%s.bsp\n", servername)
			return
		end
	end

	--	SV_LockThreadMutex();

	-- if(cls.state == ca_dedicated) Sys_MakeProcessNice(): OS process priority, nothing to do here

	if not dedicated then
		notPorted("SCR_BeginLoadingPlaque / S_StopAllSounds in SV_SpawnServer (listen server client)")
	end

	if sv.active then
		notPorted("World_End (world.c L54-57: World_Physics_End, ODE) in SV_SpawnServer")
		if serverfunction(prog, "SV_Shutdown") ~= 0 then
			local s = serverfunction(prog, "SV_Shutdown")
			SET_GF(prog, "time", sv.time)
			prog.funcoffsets["SV_Shutdown"] = 0 -- prevent it from getting called again
			prvm_edict.ExecuteProgram(prog, s, "SV_Shutdown() required")
		end
	end

	-- free q3 shaders so that any newly downloaded shaders will be active
	model_shared.Mod_FreeQ3Shaders()

	worldmodel = model_shared.Mod_ForName(modelname, false, cv("developer").integer > 0, nil)
	if not worldmodel or not worldmodel.TraceBox then
		console.Con_Printf("Couldn't load map %s\n", modelname)

		-- if(cls.state == ca_dedicated) Sys_MakeProcessMean();

		--		SV_UnlockThreadMutex();

		return
	end

	notPorted("Collision_Cache_Reset (collision.c trace cache) in SV_SpawnServer")

	-- let's not have any servers with no name
	if cv("hostname").string.str == "" then
		cvar.Cvar_Set("hostname", "UNNAMED")
	end
	-- scr_centertime_off = 0 (client screen)

	svs.changelevel_issued = false -- now safe to issue another

	-- make the map a required file for clients
	notPorted("Curl_ClearRequirements / Curl_RequireFile (libcurl.c) in SV_SpawnServer")

	--
	-- tell all connected clients that we are going to a new level
	--
	if sv.active then
		for ci = 0, svs.maxclients - 1 do
			local c = svs.clients and svs.clients[ci]
			if c and c.netconnection then
				common.MSG_WriteByte(c.netconnection.message, 9) -- svc_stufftext
				common.MSG_WriteString(c.netconnection.message, "reconnect\n")
			end
		end
	else
		-- open server port
		notPorted("NetConn_OpenServerPorts (netconn.c, M6-NET) in SV_SpawnServer")
	end

	--
	-- make cvars consistant
	--
	if cv("coop").integer ~= 0 then
		cvar.Cvar_SetValue("deathmatch", 0)
	end
	-- LordHavoc: it can be useful to have skills outside the range 0-3...
	--current_skill = bound(0, (int)(skill.value + 0.5), 3);
	--Cvar_SetValue ("skill", (float)current_skill);
	sv_main.current_skill = libc.toint(cv("skill").value + 0.5)

	--
	-- set up the new server
	--
	server.Clear()
	-- if running a local client, make sure it doesn't try to access the last
	-- level's data which is no longer valiud
	-- cls.signon = 0 (client)

	cvar.Cvar_SetValue("halflifebsp", if worldmodel.brush.ishlbsp then 1 else 0)
	cvar.Cvar_SetValue("sv_mapformat_is_quake2", if worldmodel.brush.isq2bsp then 1 else 0)
	cvar.Cvar_SetValue("sv_mapformat_is_quake3", if worldmodel.brush.isq3bsp then 1 else 0)

	local seed = cv("sv_random_seed")
	if seed.string.str ~= "" then
		libc.srand(seed.integer)
		console.Con_Printf(
			"NOTE: random seed is %d; use for debugging/benchmarking only!\nUnset sv_random_seed to get real random numbers again.\n",
			seed.integer
		)
	end

	-- SV_VM_Setup(): PRVM_Prog_Load(prog, sv_progs.string, ...) reads the file through the VFS
	local progsname = cv("sv_progs").string.str
	local progsdata = fs.FS_LoadFile(progsname, false)
	if not progsdata then
		error(string.format("PRVM_LoadProgs: couldn't load %s for %s", progsname, "server"), 0)
	end
	prog = sv_main.SV_VM_Setup(buffer.fromstring(progsdata :: string), sv_main.vm_setup_opts)

	sv.active = true
	host_cmd.sv_active = true

	-- set level base name variables for later use
	sv.name = string.sub(servername, 1, 63) -- strlcpy (sv.name, server, sizeof (sv.name))
	sv.worldname = string.sub(modelname, 1, MAX_QPATH - 1)
	sv.worldnamenoextension = FS_StripExtension(sv.worldname, MAX_QPATH)
	sv.worldbasename = string.sub(
		if string.sub(sv.worldnamenoextension, 1, 5) == "maps/"
			then string.sub(sv.worldnamenoextension, 6)
			else sv.worldnamenoextension,
		1,
		MAX_QPATH - 1
	)
	--Cvar_SetQuick(&sv_worldmessage, sv.worldmessage); // set later after QC is spawned
	cvar.Cvar_SetQuick(cv("sv_worldname"), sv.worldname)
	cvar.Cvar_SetQuick(cv("sv_worldnamenoextension"), sv.worldnamenoextension)
	cvar.Cvar_SetQuick(cv("sv_worldbasename"), sv.worldbasename)

	sv.protocol = Protocol_EnumForName(cv("sv_protocolname").string.str)
	if sv.protocol == P.UNKNOWN then
		console.Con_Printf(
			'Unknown sv_protocolname "%s", valid values are:\n%s\n',
			cv("sv_protocolname").string.str,
			Protocol_Names(1024)
		)
		sv.protocol = P.QUAKE
	end

	-- load progs to get entity field count
	--PR_LoadProgs ( sv_progs.string );

	-- sv.datagram / sv.reliable_datagram / sv.signon: maxsize = sizeof(buf), cursize = 0 (server.Clear made them)

	-- leave slots at start for clients only
	--prog->num_edicts = svs.maxclients+1;

	sv.state = server.ss_loading
	prog.allowworldwrites = true
	sv.paused = false

	sv.time = 1.0

	model_shared.Mod_ClearUsed()
	worldmodel.used = true

	sv.worldmodel = worldmodel
	sv.models[1] = sv.worldmodel

	--
	-- clear world interaction links
	--
	world.World_SetSize(sv.world, sv.worldname, sv.worldmodel.normalmins, sv.worldmodel.normalmaxs, prog)
	notPorted("World_Start (world.c L48-51: World_Physics_Start, ODE) in SV_SpawnServer")

	sv.sound_precache[0] = ""

	sv.model_precache[0] = ""
	sv.model_precache[1] = sv.worldname
	i = 1
	while i < sv.worldmodel.brush.numsubmodels and i + 1 < server.MAX_MODELS do
		sv.model_precache[i + 1] = string.sub(string.format("*%i", i), 1, MAX_QPATH - 1)
		sv.models[i + 1] = model_shared.Mod_ForName(sv.model_precache[i + 1], false, false, sv.worldname)
		i += 1
	end
	if i < sv.worldmodel.brush.numsubmodels then
		console.Con_Printf("Too many submodels (MAX_MODELS is %i)\n", server.MAX_MODELS)
	end

	--
	-- load the rest of the entities
	--
	-- AK possible hack since num_edicts is still 0
	ent = 0 -- PRVM_EDICT_NUM(0)
	buffer.fill(prog.edictsfields, ent * prog.entityfields * 4, 0, prog.entityfields * 4)
	prog.ed_free[ent] = false
	seti(prog, ent, "model", prvm_edict.PRVM_SetEngineString(prog, server.CStrRef("worldname", sv.worldname)))
	setf(prog, ent, "modelindex", 1) -- world model
	setf(prog, ent, "solid", SOLID_BSP)
	setf(prog, ent, "movetype", MOVETYPE_PUSH)
	for _, f in { "mins", "absmin" } do
		local o = prvm_edict.FieldOfs(prog, f)
		for k = 0, 2 do
			buffer.writef32(prog.edictsfields, (ent * prog.entityfields + o + k) * 4, sv.world.mins[k + 1])
		end
	end
	for _, f in { "maxs", "absmax" } do
		local o = prvm_edict.FieldOfs(prog, f)
		for k = 0, 2 do
			buffer.writef32(prog.edictsfields, (ent * prog.entityfields + o + k) * 4, sv.world.maxs[k + 1])
		end
	end

	if cv("coop").value ~= 0 then
		SET_GF(prog, "coop", cv("coop").integer)
	else
		SET_GF(prog, "deathmatch", cv("deathmatch").integer)
	end

	SET_GI(prog, "mapname", prvm_edict.PRVM_SetEngineString(prog, server.CStrRef("name", sv.name)))

	-- serverflags are for cross level information (sigils)
	SET_GF(prog, "serverflags", svs.serverflags or 0)

	-- we need to reset the spawned flag on all connected clients here so that
	-- their thinks don't run during startup (before PutClientInServer)
	-- we also need to set up the client entities now
	-- and we need to set the ->edict pointers to point into the progs edicts
	for ci = 0, svs.maxclients - 1 do
		local host_client = client(ci)
		server.host_client = host_client
		host_client.begun = false
		host_client.edict = ci + 1 -- PRVM_EDICT_NUM(i + 1)
		prvm_edict.PRVM_ED_ClearEdict(prog, host_client.edict)
	end
	server.host_client = {} -- (C leaves host_client at svs.clients + svs.maxclients, one past the last client)

	-- load replacement entity file if found
	if cv("sv_entpatch").integer ~= 0 then
		-- va(vabuf, sizeof(vabuf), "%s.ent", sv.worldnamenoextension): vabuf is char[1024]
		entities = fs.FS_LoadFile(string.sub(string.format("%s.ent", sv.worldnamenoextension), 1, 1023), true)
	end
	if entities then
		console.Con_Printf("Loaded %s.ent\n", sv.worldnamenoextension)
		prvm_edict.PRVM_ED_LoadFromFile(prog, libc.cstr(entities :: string))
	else
		prvm_edict.PRVM_ED_LoadFromFile(prog, sv.worldmodel.brush.entities)
	end

	-- LordHavoc: clear world angles (to fix e3m3.bsp)
	do
		local o = prvm_edict.FieldOfs(prog, "angles")
		buffer.fill(prog.edictsfields, o * 4, 0, 12) -- VectorClear(PRVM_serveredictvector(prog->edicts, angles))
	end

	-- all setup is completed, any further precache statements are errors
	--	sv.state = ss_active; // LordHavoc: workaround for svc_precache bug
	prog.allowworldwrites = false

	-- run two frames to allow everything to settle
	local SV_Physics = require("./sv_phys").SV_Physics -- sv_phys requires this module
	sv.time = 1.0001
	i = 0
	while i < cv("sv_init_frame_count").integer do
		sv.frametime = 0.1
		SV_Physics()
		i += 1
	end

	-- Once all init frames have been run, we consider svqc code fully initialized.
	prog.inittime = prvm_edict.realtime

	if dedicated then
		model_shared.Mod_PurgeUnused()
	end

	-- create a baseline for more efficient communications
	if oldprotocol(sv.protocol) then
		notPorted("SV_CreateBaseline (sv_main.c L3110-3184, old protocols only) in SV_SpawnServer")
	end

	sv.state = server.ss_active -- LordHavoc: workaround for svc_precache bug

	-- send serverinfo to all connected clients, and set up botclients coming back from a level change
	for ci = 0, svs.maxclients - 1 do
		local host_client = client(ci)
		server.host_client = host_client
		host_client.clientconnectcalled = false -- do NOT call ClientDisconnect if he drops before ClientConnect!
		if not host_client.active then
			continue
		end
		if host_client.netconnection then
			notPorted("SV_SendServerinfo (sv_main.c L880-1067, M6-NET) in SV_SpawnServer")
		else
			-- if client is a botclient coming from a level change, we need to
			-- set up client info that normally requires networking

			-- copy spawn parms out of the client_t
			local parm1 = prvm_cmds.GlobalOfs(prog, "parm1")
			for j = 0, NUM_SPAWN_PARMS - 1 do
				local parms = host_client.spawn_parms
				buffer.writef32(prog.globals, (parm1 + j) * 4, if parms then parms[j] or 0 else 0)
			end

			-- call the spawn function
			host_client.clientconnectcalled = true
			SET_GF(prog, "time", sv.time)
			SET_GI(prog, "self", host_client.edict)
			prvm_edict.ExecuteProgram(
				prog,
				serverfunction(prog, "ClientConnect"),
				"QC function ClientConnect is missing"
			)
			prvm_edict.ExecuteProgram(
				prog,
				serverfunction(prog, "PutClientInServer"),
				"QC function PutClientInServer is missing"
			)
			host_client.begun = true
		end
	end
	server.host_client = {} -- one past the last client

	-- update the map title cvar
	local msg = buffer.readi32(prog.edictsfields, prvm_edict.FieldOfs(prog, "message") * 4)
	sv.worldmessage = string.sub(prvm_edict.PRVM_GetString(prog, msg), 1, 39) -- map title (not related to filename)
	cvar.Cvar_SetQuick(cv("sv_worldmessage"), sv.worldmessage)

	console.Con_DPrint("Server spawned.\n")
	notPorted("NetConn_Heartbeat (netconn.c, M6-NET) in SV_SpawnServer")

	-- if(cls.state == ca_dedicated) Sys_MakeProcessMean();

	--	SV_UnlockThreadMutex();
end

--[[
===============================================================================

	Sounds, effects, client spawning and the per-frame message updates (sv_main.c L640-1142, L1974-1983,
	L2266-2280, L2491-2640, L3243-3262). DarkPlaces 0.8.6 has these in sv_main.c (sv_send.c is a later split),
	so they are ported here. Every message goes into sv.datagram / sv.reliable_datagram; the parts that write to
	a client's netconnection run only for clients with one (none connect yet, M6-NET).

===============================================================================
]]

local R = require("./_port/f32").round
local MAX_PACKETFRAGMENT = 1024 -- quakedef.h L138

-- host.luau (host.c), required on first use and kept (host requires this module lazily; a require() call
-- resolves the path every time in Lune, about 0.5 ms)
local hostmod: any = nil
local function HOST(): any
	if not hostmod then
		hostmod = require("./host")
	end
	return hostmod
end
-- protocol.h L190-256
local svc_disconnect, svc_sound, svc_print, svc_stufftext = 2, 6, 8, 9
local svc_updatename, svc_updatefrags, svc_updatecolors, svc_particle = 13, 14, 17, 18
local svc_setview = 5
local svc_effect, svc_effect2 = 52, 53
-- protocol.h L163-168
local SND_VOLUME, SND_ATTENUATION, SND_LARGEENTITY, SND_LARGESOUND, SND_SPEEDUSHORT4000 = 1, 2, 8, 16, 32
-- sound.h L31-32
local DEFAULT_SOUND_PACKET_VOLUME, DEFAULT_SOUND_PACKET_ATTENUATION = 255, 1.0
local EF_MUZZLEFLASH = 2 -- protocol.h L45
local PRVM_KNOWNSTRINGBASE = 0x40000000 -- prvm_edict.c L2958

sv_main.svc_disconnect, sv_main.svc_print, sv_main.svc_stufftext = svc_disconnect, svc_print, svc_stufftext
sv_main.svc_updatename, sv_main.svc_updatefrags, sv_main.svc_updatecolors =
	svc_updatename, svc_updatefrags, svc_updatecolors

local function getf(prog: any, e: number, field: string): number -- PRVM_serveredictfloat (0 if the field is missing)
	local o = prvm_edict.FieldOfs(prog, field)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.edictsfields, (e * prog.entityfields + o) * 4)
end
local function geti(prog: any, e: number, field: string): number -- PRVM_serveredictstring / edict
	local o = prvm_edict.FieldOfs(prog, field)
	if o < 0 then
		return 0
	end
	return buffer.readi32(prog.edictsfields, (e * prog.entityfields + o) * 4)
end
local function getvi(prog: any, e: number, field: string, i: number): number -- PRVM_serveredictvector(e, f)[i]
	local o = prvm_edict.FieldOfs(prog, field)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.edictsfields, (e * prog.entityfields + o + i) * 4)
end
-- mathlib.h L51: bound(min,num,max) ((num) >= (min) ? ((num) < (max) ? (num) : (max)) : (min))
local function bound(mn: number, num: number, mx: number): number
	return if num >= mn then (if num < mx then num else mx) else mn
end

-- C `int` result of (int)x & ~bit, as a signed value
local function andnot(x: number, b: number): number
	local r = bit32.band(libc.toint(x), bit32.bnot(b))
	return if r >= 0x80000000 then r - 0x100000000 else r
end

-- the C pointer comparison `PRVM_GetString(prog, num) != ref` (ref: a char array of a client_t): true unless
-- the string number is the engine string that points at ref
local function notSameString(prog: any, num: number, ref: { str: string }): boolean
	if num >= PRVM_KNOWNSTRINGBASE then
		local k = prog.knownstrings[num - PRVM_KNOWNSTRINGBASE + 1]
		return k ~= ref
	end
	return true
end

--[[
==================
SV_StartParticle

Make sure the event gets sent to all clients
==================
]]
-- port: sv_main.c SV_StartParticle L647-662 @xonotic-v0.8.6
function sv_main.SV_StartParticle(org: { number }, dir: { number }, color: number, count: number)
	local sv = server.sv
	if sv.datagram.cursize > MAX_PACKETFRAGMENT - 18 then
		return
	end
	common.MSG_WriteByte(sv.datagram, svc_particle)
	common.MSG_WriteCoord(sv.datagram, org[1], sv.protocol)
	common.MSG_WriteCoord(sv.datagram, org[2], sv.protocol)
	common.MSG_WriteCoord(sv.datagram, org[3], sv.protocol)
	for i = 1, 3 do
		-- (int)bound(-128, dir[i]*16, 127): the float product (rounded), then the int conversion
		common.MSG_WriteChar(sv.datagram, libc.toint(bound(-128, R(dir[i] * 16), 127)))
	end
	common.MSG_WriteByte(sv.datagram, count)
	common.MSG_WriteByte(sv.datagram, color)
	sv_main.SV_FlushBroadcastMessages()
end

--[[
==================
SV_StartEffect

Make sure the event gets sent to all clients
==================
]]
-- port: sv_main.c SV_StartEffect L671-700 @xonotic-v0.8.6
function sv_main.SV_StartEffect(
	org: { number },
	modelindex: number,
	startframe: number,
	framecount: number,
	framerate: number
)
	local sv = server.sv
	if modelindex >= 256 or startframe >= 256 then
		if sv.datagram.cursize > MAX_PACKETFRAGMENT - 19 then
			return
		end
		common.MSG_WriteByte(sv.datagram, svc_effect2)
		common.MSG_WriteCoord(sv.datagram, org[1], sv.protocol)
		common.MSG_WriteCoord(sv.datagram, org[2], sv.protocol)
		common.MSG_WriteCoord(sv.datagram, org[3], sv.protocol)
		common.MSG_WriteShort(sv.datagram, modelindex)
		common.MSG_WriteShort(sv.datagram, startframe)
		common.MSG_WriteByte(sv.datagram, framecount)
		common.MSG_WriteByte(sv.datagram, framerate)
	else
		if sv.datagram.cursize > MAX_PACKETFRAGMENT - 17 then
			return
		end
		common.MSG_WriteByte(sv.datagram, svc_effect)
		common.MSG_WriteCoord(sv.datagram, org[1], sv.protocol)
		common.MSG_WriteCoord(sv.datagram, org[2], sv.protocol)
		common.MSG_WriteCoord(sv.datagram, org[3], sv.protocol)
		common.MSG_WriteByte(sv.datagram, modelindex)
		common.MSG_WriteByte(sv.datagram, startframe)
		common.MSG_WriteByte(sv.datagram, framecount)
		common.MSG_WriteByte(sv.datagram, framerate)
	end
	sv_main.SV_FlushBroadcastMessages()
end

--[[
==================
SV_StartSound

Each entity can have eight independant sound sources, like voice,
weapon, feet, etc.

Channel 0 is an auto-allocate channel, the others override anything
already running on that entity/channel pair.

An attenuation of 0 will play full volume everywhere in the level.
Larger attenuations will drop off.  (max 4 attenuation)

==================
]]
-- port: sv_main.c SV_StartSound L717-794 @xonotic-v0.8.6
-- (entity: edict number; attenuation and speed are floats)
function sv_main.SV_StartSound(
	entity: number,
	channel: number,
	sample: string,
	nvolume: number,
	attenuation: number,
	reliable: boolean,
	speed: number
)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local dest
	local sound_num, field_mask, ent, speed4000

	dest = if reliable then sv.reliable_datagram else sv.datagram

	if nvolume < 0 or nvolume > 255 then
		console.Con_Printf("SV_StartSound: volume = %i\n", nvolume)
		return
	end

	if attenuation < 0 or attenuation > 4 then
		console.Con_Printf("SV_StartSound: attenuation = %f\n", attenuation)
		return
	end

	if not (channel >= -128 and channel <= 127) then -- !IS_CHAN(channel)
		console.Con_Printf("SV_StartSound: channel = %i\n", channel)
		return
	end

	channel = channel -- CHAN_ENGINE2NET(channel)

	if sv.datagram.cursize > MAX_PACKETFRAGMENT - 21 then
		return
	end

	-- find precache number for sound
	sound_num = sv_main.SV_SoundIndex(sample, 1)
	if sound_num == 0 then
		return
	end

	ent = entity -- PRVM_NUM_FOR_EDICT(entity)

	speed4000 = libc.toint(math.floor(R(R(speed * 4000.0) + 0.5)))
	field_mask = 0
	if nvolume ~= DEFAULT_SOUND_PACKET_VOLUME then
		field_mask = bit32.bor(field_mask, SND_VOLUME)
	end
	if attenuation ~= DEFAULT_SOUND_PACKET_ATTENUATION then
		field_mask = bit32.bor(field_mask, SND_ATTENUATION)
	end
	if speed4000 ~= 0 and speed4000 ~= 4000 then
		field_mask = bit32.bor(field_mask, SND_SPEEDUSHORT4000)
	end
	if ent >= 8192 or channel < 0 or channel > 7 then
		field_mask = bit32.bor(field_mask, SND_LARGEENTITY)
	end
	if sound_num >= 256 then
		field_mask = bit32.bor(field_mask, SND_LARGESOUND)
	end

	-- directed messages go only to the entity they are targeted on
	common.MSG_WriteByte(dest, svc_sound)
	common.MSG_WriteByte(dest, field_mask)
	if bit32.band(field_mask, SND_VOLUME) ~= 0 then
		common.MSG_WriteByte(dest, nvolume)
	end
	if bit32.band(field_mask, SND_ATTENUATION) ~= 0 then
		common.MSG_WriteByte(dest, libc.toint(R(attenuation * 64)))
	end
	if bit32.band(field_mask, SND_SPEEDUSHORT4000) ~= 0 then
		common.MSG_WriteShort(dest, speed4000)
	end
	if bit32.band(field_mask, SND_LARGEENTITY) ~= 0 then
		common.MSG_WriteShort(dest, ent)
		common.MSG_WriteChar(dest, channel)
	else
		common.MSG_WriteShort(dest, bit32.bor(bit32.lshift(ent, 3), channel))
	end
	if bit32.band(field_mask, SND_LARGESOUND) ~= 0 or sv.protocol == P.NEHAHRABJP2 then
		common.MSG_WriteShort(dest, sound_num)
	else
		common.MSG_WriteByte(dest, sound_num)
	end
	for i = 0, 2 do
		-- origin[i] + 0.5 * (mins[i] + maxs[i]): float sum, double product and sum, passed as the float parameter
		common.MSG_WriteCoord(
			dest,
			R(
				getvi(prog, entity, "origin", i)
					+ 0.5 * R(getvi(prog, entity, "mins", i) + getvi(prog, entity, "maxs", i))
			),
			sv.protocol
		)
	end

	-- TODO do we have to do anything here when dest is &sv.reliable_datagram?
	if not reliable then
		sv_main.SV_FlushBroadcastMessages()
	end
end

--[[
==================
SV_StartPointSound

Nearly the same logic as SV_StartSound, except an origin
instead of an entity is provided and channel is omitted.

The entity sent to the client is 0 (world) and the channel
is 0 (CHAN_AUTO).  SND_LARGEENTITY will never occur in this
function, therefore the check for it is omitted.

==================
]]
-- port: sv_main.c SV_StartPointSound L809-862 @xonotic-v0.8.6
-- engine quirk kept: speed4000 is (int)(speed * 40.0f) here (SV_StartSound uses 4000), so a speed of 1 is sent
-- as 40
function sv_main.SV_StartPointSound(
	origin: { number },
	sample: string,
	nvolume: number,
	attenuation: number,
	speed: number
)
	local sv = server.sv
	local sound_num, field_mask, speed4000

	if nvolume < 0 or nvolume > 255 then
		console.Con_Printf("SV_StartPointSound: volume = %i\n", nvolume)
		return
	end

	if attenuation < 0 or attenuation > 4 then
		console.Con_Printf("SV_StartPointSound: attenuation = %f\n", attenuation)
		return
	end

	if sv.datagram.cursize > MAX_PACKETFRAGMENT - 21 then
		return
	end

	-- find precache number for sound
	sound_num = sv_main.SV_SoundIndex(sample, 1)
	if sound_num == 0 then
		return
	end

	speed4000 = libc.toint(R(speed * 40.0))
	field_mask = 0
	if nvolume ~= DEFAULT_SOUND_PACKET_VOLUME then
		field_mask = bit32.bor(field_mask, SND_VOLUME)
	end
	if attenuation ~= DEFAULT_SOUND_PACKET_ATTENUATION then
		field_mask = bit32.bor(field_mask, SND_ATTENUATION)
	end
	if sound_num >= 256 then
		field_mask = bit32.bor(field_mask, SND_LARGESOUND)
	end
	if speed4000 ~= 0 and speed4000 ~= 4000 then
		field_mask = bit32.bor(field_mask, SND_SPEEDUSHORT4000)
	end

	-- directed messages go only to the entity they are targeted on
	common.MSG_WriteByte(sv.datagram, svc_sound)
	common.MSG_WriteByte(sv.datagram, field_mask)
	if bit32.band(field_mask, SND_VOLUME) ~= 0 then
		common.MSG_WriteByte(sv.datagram, nvolume)
	end
	if bit32.band(field_mask, SND_ATTENUATION) ~= 0 then
		common.MSG_WriteByte(sv.datagram, libc.toint(R(attenuation * 64)))
	end
	if bit32.band(field_mask, SND_SPEEDUSHORT4000) ~= 0 then
		common.MSG_WriteShort(sv.datagram, speed4000)
	end
	-- Always write entnum 0 for the world entity
	common.MSG_WriteShort(sv.datagram, 0) -- (0<<3) | 0
	if bit32.band(field_mask, SND_LARGESOUND) ~= 0 then
		common.MSG_WriteShort(sv.datagram, sound_num)
	else
		common.MSG_WriteByte(sv.datagram, sound_num)
	end
	for i = 1, 3 do
		common.MSG_WriteCoord(sv.datagram, origin[i], sv.protocol)
	end
	sv_main.SV_FlushBroadcastMessages()
end

--[[
================
SV_ConnectClient

Initializes a client_t for a new net connection.  This will only be called
once for a player each game, not once for each level change.
================
]]
-- port: sv_main.c SV_ConnectClient L1069-1141 @xonotic-v0.8.6
-- (netconnection: nil for a bot, the only kind that connects until M6-NET)
function sv_main.SV_ConnectClient(clientnum: number, netconnection: any)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local c = client(clientnum)

	-- set up the client_t
	if sv.loadgame then
		local backupparms = table.clone(c.spawn_parms)
		ClearClient(c)
		c.spawn_parms = backupparms
	else
		ClearClient(c)
	end
	c.active = true
	c.netconnection = netconnection

	console.Con_DPrintf("Client %s connected\n", if c.netconnection then c.netconnection.address else "botclient")

	if c.netconnection and c.netconnection.crypto and c.netconnection.crypto.authenticated then
		notPorted("SV_ConnectClient crypto message of an authenticated connection (crypto.c, M6-NET)")
	end

	c.name.str = string.sub("unconnected", 1, MAX_SCOREBOARDNAME - 1)
	c.old_name.str = string.sub("unconnected", 1, MAX_SCOREBOARDNAME - 1)
	c.prespawned = false
	c.spawned = false
	c.begun = false
	c.edict = clientnum + 1 -- PRVM_EDICT_NUM(clientnum+1)
	if c.netconnection then
		c.netconnection.message.allowoverflow = true -- we can catch it
	end
	-- prepare the unreliable message buffer
	c.unreliablemsg.data = buffer.create(NET_MAXMESSAGE)
	c.unreliablemsg.maxsize = NET_MAXMESSAGE
	-- updated by receiving "rate" command from client, this is also the default if not using a DP client
	c.rate = 1000000000
	c.connecttime = prvm_edict.realtime

	if not sv.loadgame then
		-- call the progs to get default spawn parms for the new client
		-- set self to world to intentionally cause errors with broken SetNewParms code in some mods
		SET_GF(prog, "time", sv.time)
		SET_GI(prog, "self", 0)
		prvm_edict.ExecuteProgram(prog, serverfunction(prog, "SetNewParms"), "QC function SetNewParms is missing")
		local parm1 = prvm_cmds.GlobalOfs(prog, "parm1")
		for i = 0, NUM_SPAWN_PARMS - 1 do
			c.spawn_parms[i] = buffer.readf32(prog.globals, (parm1 + i) * 4)
		end

		-- set up the entity for this client (including .colormap, .team, etc)
		prvm_edict.PRVM_ED_ClearEdict(prog, c.edict)
	end

	-- don't call SendServerinfo for a fresh botclient because its fields have
	-- not been set up by the qc yet
	if c.netconnection then
		notPorted("SV_SendServerinfo (sv_main.c L880-1059, M6-NET) in SV_ConnectClient")
	else
		c.prespawned = true
		c.spawned = true
		c.begun = true
	end
end

--[[
=============
SV_CleanupEnts

=============
]]
-- port: sv_main.c SV_CleanupEnts L1974-1983 @xonotic-v0.8.6
local function SV_CleanupEnts()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local o = prvm_edict.FieldOfs(prog, "effects")
	if o < 0 then
		return
	end
	local f, n = prog.edictsfields, prog.entityfields
	for e = 1, prog.num_edicts - 1 do
		local a = (e * n + o) * 4
		local v = buffer.readf32(f, a)
		if v ~= 0 then -- ((int)0 & ~EF_MUZZLEFLASH) == 0: the store would not change a zero
			buffer.writef32(f, a, andnot(v, EF_MUZZLEFLASH))
		end
	end
end

-- port: sv_main.c SV_FlushBroadcastMessages L2266-2280 @xonotic-v0.8.6
function sv_main.SV_FlushBroadcastMessages()
	local sv = server.sv
	local svs = host_cmd.svs :: any
	if sv.datagram.cursize <= 0 then
		return
	end
	for i = 0, svs.maxclients - 1 do
		local c = client(i)
		if
			not c.begun
			or not c.netconnection
			or c.unreliablemsg.cursize + sv.datagram.cursize > c.unreliablemsg.maxsize
			or c.unreliablemsg_splitpoints >= NET_MAXMESSAGE / 16
		then
			continue
		end
		common.SZ_Write(c.unreliablemsg, buffer.readstring(sv.datagram.data, 0, sv.datagram.cursize))
		c.unreliablemsg_splitpoint[c.unreliablemsg_splitpoints] = c.unreliablemsg.cursize
		c.unreliablemsg_splitpoints += 1
	end
	common.SZ_Clear(sv.datagram)
end

--[[
=======================
SV_UpdateToReliableMessages
=======================
]]
-- port: sv_main.c SV_UpdateToReliableMessages L2491-2595 @xonotic-v0.8.6
local function SV_UpdateToReliableMessages()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local svs = host_cmd.svs :: any
	local name, model, skin
	local clientcamera
	local host = HOST() -- host.c (SV_BroadcastPrintf)

	-- check for changes to be sent over the reliable streams
	for i = 0, svs.maxclients - 1 do
		local host_client = client(i)
		server.host_client = host_client
		-- update the host_client fields we care about according to the entity fields
		host_client.edict = i + 1
		local ed = host_client.edict

		-- DP_SV_CLIENTNAME
		local nn = geti(prog, ed, "netname")
		name = prvm_edict.PRVM_GetString(prog, nn)
		-- always point the string back at host_client->name to keep it safe
		--strlcpy (host_client->name, name, sizeof (host_client->name));
		if notSameString(prog, nn, host_client.name) then -- prevent buffer overlap SIGABRT on Mac OSX
			host_client.name.str = string.sub(libc.cstr(name), 1, MAX_SCOREBOARDNAME - 1)
		end
		seti(prog, ed, "netname", prvm_edict.PRVM_SetEngineString(prog, host_client.name))
		if host_client.old_name.str ~= host_client.name.str then
			if host_client.begun then
				host.SV_BroadcastPrintf("%s ^7changed name to %s\n", host_client.old_name.str, host_client.name.str)
			end
			host_client.old_name.str = string.sub(host_client.name.str, 1, MAX_SCOREBOARDNAME - 1)
			-- send notification to all clients
			common.MSG_WriteByte(sv.reliable_datagram, svc_updatename)
			common.MSG_WriteByte(sv.reliable_datagram, i)
			common.MSG_WriteString(sv.reliable_datagram, host_client.name.str)
			if host_client.sv_demo_file ~= nil then
				notPorted("SV_WriteNetnameIntoDemo (sv_demo.c) in SV_UpdateToReliableMessages")
			end
		end

		-- DP_SV_CLIENTCOLORS
		host_client.colors = libc.toint(getf(prog, ed, "clientcolors"))
		if host_client.old_colors ~= host_client.colors then
			host_client.old_colors = host_client.colors
			-- send notification to all clients
			common.MSG_WriteByte(sv.reliable_datagram, svc_updatecolors)
			common.MSG_WriteByte(sv.reliable_datagram, i)
			common.MSG_WriteByte(sv.reliable_datagram, host_client.colors)
		end

		-- NEXUIZ_PLAYERMODEL
		local pm = geti(prog, ed, "playermodel")
		model = prvm_edict.PRVM_GetString(prog, pm)
		-- always point the string back at host_client->name to keep it safe
		--strlcpy (host_client->playermodel, model, sizeof (host_client->playermodel));
		if notSameString(prog, pm, host_client.playermodel) then -- prevent buffer overlap SIGABRT on Mac OSX
			host_client.playermodel.str = string.sub(libc.cstr(model), 1, server.MAX_QPATH - 1)
		end
		seti(prog, ed, "playermodel", prvm_edict.PRVM_SetEngineString(prog, host_client.playermodel))

		-- NEXUIZ_PLAYERSKIN
		local ps = geti(prog, ed, "playerskin")
		skin = prvm_edict.PRVM_GetString(prog, ps)
		-- always point the string back at host_client->name to keep it safe
		--strlcpy (host_client->playerskin, skin, sizeof (host_client->playerskin));
		if notSameString(prog, ps, host_client.playerskin) then -- prevent buffer overlap SIGABRT on Mac OSX
			host_client.playerskin.str = string.sub(libc.cstr(skin), 1, server.MAX_QPATH - 1)
		end
		seti(prog, ed, "playerskin", prvm_edict.PRVM_SetEngineString(prog, host_client.playerskin))

		-- TODO: add an extension name for this [1/17/2008 Black]
		clientcamera = geti(prog, ed, "clientcamera")
		if clientcamera > 0 then
			local oldclientcamera = host_client.clientcamera
			if clientcamera >= prog.max_edicts or prog.ed_free[clientcamera] then
				clientcamera = ed -- PRVM_NUM_FOR_EDICT(host_client->edict)
			end
			host_client.clientcamera = clientcamera

			if oldclientcamera ~= host_client.clientcamera and host_client.netconnection then
				common.MSG_WriteByte(host_client.netconnection.message, svc_setview)
				common.MSG_WriteShort(host_client.netconnection.message, host_client.clientcamera)
			end
		end

		-- frags
		host_client.frags = libc.toint(getf(prog, ed, "frags"))
		-- if(IS_OLDNEXUIZ_DERIVED(gamemode)) if(!host_client->begun && host_client->netconnection) frags = -666;
		-- (common.h L308: GAME_NEXUIZ or GAME_VORETOURNAMENT only, false for GAME_XONOTIC)
		if host_client.old_frags ~= host_client.frags then
			host_client.old_frags = host_client.frags
			-- send notification to all clients
			common.MSG_WriteByte(sv.reliable_datagram, svc_updatefrags)
			common.MSG_WriteByte(sv.reliable_datagram, i)
			common.MSG_WriteShort(sv.reliable_datagram, host_client.frags)
		end
	end
	server.host_client = {} -- (C leaves host_client at svs.clients + svs.maxclients, one past the last client)

	for j = 0, svs.maxclients - 1 do
		local c = client(j)
		if c.netconnection and (c.begun or c.clientconnectcalled) then -- also send MSG_ALL to people who are past ClientConnect, but not spawned yet
			common.SZ_Write(
				c.netconnection.message,
				buffer.readstring(sv.reliable_datagram.data, 0, sv.reliable_datagram.cursize)
			)
		end
	end

	common.SZ_Clear(sv.reliable_datagram)
end

--[[
=======================
SV_SendClientMessages
=======================
]]
-- port: sv_main.c SV_SendClientMessages L2603-2640 @xonotic-v0.8.6
function sv_main.SV_SendClientMessages()
	local sv = server.sv
	local svs = host_cmd.svs :: any
	local prepared = false

	if sv.protocol == P.QUAKEWORLD then
		error("SV_SendClientMessages: no quakeworld support\n", 0) -- Sys_Error
	end

	sv_main.SV_FlushBroadcastMessages()

	-- update frags, names, etc
	SV_UpdateToReliableMessages()

	-- build individual updates
	for i = 0, svs.maxclients - 1 do
		local host_client = client(i)
		server.host_client = host_client
		if not host_client.active then
			continue
		end
		if not host_client.netconnection then
			continue
		end

		if host_client.netconnection.message.overflowed then
			HOST().SV_DropClient(true) -- if the message couldn't send, kick off
			continue
		end

		if not prepared then
			prepared = true
			-- only prepare entities once per frame
			notPorted("SV_PrepareEntitiesForSending (sv_main.c L1471-1490, M6-NET) in SV_SendClientMessages")
		end
		notPorted("SV_SendClientDatagram (sv_main.c L2320-2484, M6-NET) in SV_SendClientMessages")
	end
	server.host_client = {} -- (one past the last client)

	-- clear muzzle flashes
	SV_CleanupEnts()
end

-- MUST match effectnameindex_t in client.h (sv_main.c L210-247)
local standardeffectnames = {
	"",
	"TE_GUNSHOT",
	"TE_GUNSHOTQUAD",
	"TE_SPIKE",
	"TE_SPIKEQUAD",
	"TE_SUPERSPIKE",
	"TE_SUPERSPIKEQUAD",
	"TE_WIZSPIKE",
	"TE_KNIGHTSPIKE",
	"TE_EXPLOSION",
	"TE_EXPLOSIONQUAD",
	"TE_TAREXPLOSION",
	"TE_TELEPORT",
	"TE_LAVASPLASH",
	"TE_SMALLFLASH",
	"TE_FLAMEJET",
	"EF_FLAME",
	"TE_BLOOD",
	"TE_SPARK",
	"TE_PLASMABURN",
	"TE_TEI_G3",
	"TE_TEI_SMOKE",
	"TE_TEI_BIGEXPLOSION",
	"TE_TEI_PLASMAHIT",
	"EF_STARDUST",
	"TR_ROCKET",
	"TR_GRENADE",
	"TR_BLOOD",
	"TR_WIZSPIKE",
	"TR_SLIGHTBLOOD",
	"TR_KNIGHTSPIKE",
	"TR_VORESPIKE",
	"TR_NEHAHRASMOKE",
	"TR_NEXUIZPLASMA",
	"TR_GLOWTRAIL",
	"SVC_PARTICLE",
}
local MAX_PARTICLEEFFECTNAME = 4096 -- quakedef.h L169

--[[
================
SV_ParticleEffectIndex

================
]]
-- port: sv_main.c SV_ParticleEffectIndex L3004-3087 @xonotic-v0.8.6
-- (sv.particleeffectname[i]: char[MAX_QPATH], C index i at [i]; a missing entry is the empty string)
function sv_main.SV_ParticleEffectIndex(name: string): number
	local sv = server.sv
	local argc, linenumber, effectnameindex
	local filedata
	local text
	local argv: { string } = {}
	local filename
	local names = sv.particleeffectname
	if not sv.particleeffectnamesloaded then
		sv.particleeffectnamesloaded = true
		table.clear(names)
		for i = 0, #standardeffectnames - 1 do -- EFFECT_TOTAL
			names[i] = string.sub(standardeffectnames[i + 1], 1, server.MAX_QPATH - 1)
		end
		local filepass = 0
		while true do
			if filepass == 0 then
				filename = "effectinfo.txt"
			elseif filepass == 1 then
				filename =
					string.sub(string.format("%s_effectinfo.txt", sv.worldnamenoextension), 1, server.MAX_QPATH - 1)
			else
				break
			end
			filepass += 1
			filedata = fs.FS_LoadFile(filename, true)
			if not filedata then
				continue
			end
			local s = libc.cstr(filedata :: string) -- (the loaded file is NUL terminated)
			text = 1 -- textstart
			linenumber = 1
			while true do
				argc = 0
				while true do
					local ok
					ok, text = common.COM_ParseToken_Simple(s, text, true, false, true)
					if not ok or common.com_token == "\n" then
						break
					end
					if argc < 16 then
						argv[argc] = string.sub(common.com_token, 1, 1023) -- strlcpy(argv[argc], com_token, 1024)
						argc += 1
					end
				end
				if common.com_token == "" then
					break -- if the loop exited and it's not a \n, it's EOF
				end
				if argc >= 1 and argv[0] == "effect" then
					if argc == 2 then
						effectnameindex = 1
						while effectnameindex < MAX_PARTICLEEFFECTNAME do
							local cur = names[effectnameindex]
							if cur and cur ~= "" then
								if cur == argv[1] then
									break
								end
							else
								names[effectnameindex] = string.sub(argv[1], 1, server.MAX_QPATH - 1)
								break
							end
							effectnameindex += 1
						end
						-- if we run out of names, abort
						if effectnameindex == MAX_PARTICLEEFFECTNAME then
							console.Con_Printf("%s:%i: too many effects!\n", filename, linenumber)
							break
						end
					end
				end
				linenumber += 1
			end
			-- Mem_Free(filedata)
		end
	end
	-- search for the name
	effectnameindex = 1
	while effectnameindex < MAX_PARTICLEEFFECTNAME and (names[effectnameindex] or "") ~= "" do
		if names[effectnameindex] == name then
			return effectnameindex
		end
		effectnameindex += 1
	end
	-- return 0 if we couldn't find it
	return 0
end

--[[
================
SV_SaveSpawnparms

Grabs the current state of each client for saving across the
transition to another level
================
]]
-- port: sv_main.c SV_SaveSpawnparms L3243-3262 @xonotic-v0.8.6
function sv_main.SV_SaveSpawnparms()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local svs = host_cmd.svs :: any

	svs.serverflags = libc.toint(buffer.readf32(prog.globals, prvm_cmds.GlobalOfs(prog, "serverflags") * 4))

	for i = 0, svs.maxclients - 1 do
		local host_client = client(i)
		server.host_client = host_client
		if not host_client.active then
			continue
		end

		-- call the progs to get default spawn parms for the new client
		SET_GF(prog, "time", server.sv.time)
		SET_GI(prog, "self", host_client.edict)
		prvm_edict.ExecuteProgram(prog, serverfunction(prog, "SetChangeParms"), "QC function SetChangeParms is missing")
		local parm1 = prvm_cmds.GlobalOfs(prog, "parm1")
		for j = 0, NUM_SPAWN_PARMS - 1 do
			host_client.spawn_parms[j] = buffer.readf32(prog.globals, (parm1 + j) * 4)
		end
	end
	server.host_client = {} -- (one past the last client)
end

return sv_main
