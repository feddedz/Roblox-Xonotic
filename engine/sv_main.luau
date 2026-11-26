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

-- client_t data the edict hooks read (svs.clients[num]); no clients connect yet (M6-NET). Each char array
-- of a client_t is one C pointer, so each is one string reference for PRVM_SetEngineString.
local NULL_BOTCLIENT = { str = "null/botclient" } -- string literal in SVVM_init_edict
local function client(num: number): any
	local svs = host_cmd.svs :: any
	svs.clients = svs.clients or {}
	local c = svs.clients[num]
	if not c then
		c = {
			colors = 0,
			name = { str = "" },
			playermodel = { str = "" },
			playerskin = { str = "" },
			netconnection = nil,
		}
		svs.clients[num] = c
	end
	return c
end

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
	require("./world").World_UnlinkEdict(prog, e) -- unlink from world bsp
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
	notPorted("VM_RemoveEdictSkeleton, World_Physics_Remove*, csqc entity versions in SVVM_free_edict")
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

return sv_main
