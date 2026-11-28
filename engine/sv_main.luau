--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces sv_main.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of sv_main.c @xonotic-v0.8.6. PARTIAL: SV_VM_Setup up to PRVM_Prog_Load, the SVVM_* edict hooks,
	SV_GetModelByIndex, SV_GetModelFromEdict, SV_SpawnServer, the sounds / effects, client spawning
	(SV_SendServerinfo, SV_ConnectClient), the frame updates (entity gathering SV_PrepareEntityForSending ..
	SV_WriteEntitiesToClient, SV_WriteClientdataToMessage, SV_SendClientDatagram, SV_SendClientMessages),
	SV_ModelIndex, SV_ParticleEffectIndex, SV_Prepare_CSQC, SV_SaveSpawnparms.
	NOT YET PORTED: the PROGHEADER_CRC branch that sets engine field offsets from entvars_t (applies to
	Xonotic: progs crc 5927), the remaining PRVM_Prog_Load steps (autocvar_* globals from cvars, .po
	translation, PRVM_Init_Exec, field/global offset lookup), the rest of SV_VM_Setup, SV_Init, the download
	commands, SV_CreateBaseline, the thread functions. The protocol.c encoders are called through
	engine/protocol.luau and netconn.c through the sv_main.netconn hooks (see before SV_SendServerinfo).
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
local matrixlib = require("./matrixlib")
local protocol = require("./protocol") -- (protocol resolves sv_main lazily: no load cycle)

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
	netconnection is nil for a bot, else a netconn_t table (message: sizebuf_t, cleartime, timeout,
	sendMessageLength, peeraddress, address; see sv_main.netconn). unreliablemsg is a sizebuf_t of
	NET_MAXMESSAGE bytes. stats / statsdeltabits (0-based tables) and csqcentityscope / csqcentitysendflags
	(buffers) / csqcentityframehistory have engine/protocol.luau's representation (see its header); the entity
	databases are what its *_AllocDatabase return; visibletime holds entity e at [e].
]]
local NULL_BOTCLIENT = { str = "null/botclient" } -- string literal in SVVM_init_edict
local MAX_SCOREBOARDNAME = 128 -- quakedef.h L145
local NET_MAXMESSAGE = 65536 -- quakedef.h L137
local MAX_CL_STATS = 256 -- quakedef.h L221

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
	-- the sending state (server.h L201-337; users: SV_SendServerinfo, SV_SendClientDatagram, protocol.c).
	-- stats / statsdeltabits and the csqc entity arrays have engine/protocol.luau's representation and are nil
	-- here (the zeroed memory): CSQC_ClientFields / Stats_ClientFields create them zeroed on first use.
	c.stats = nil -- int stats[MAX_CL_STATS]: 0-based table of ints
	c.statsdeltabits = nil -- unsigned char [(MAX_CL_STATS+7)/8]: 0-based table of bytes
	c.entitydatabase = nil -- entityframe_database_t * (protocol.c; nil = NULL)
	c.entitydatabase4 = nil -- entityframe4_database_t *
	c.entitydatabase5 = nil -- entityframe5_database_t *
	c.csqcentityscope = nil -- unsigned char [MAX_EDICTS]: buffer of u8
	c.csqcentitysendflags = nil -- unsigned int [MAX_EDICTS]: buffer of u32
	c.csqcentityframehistory = nil -- csqcentityframedb_t [NUM_CSQCENTITYDB_FRAMES], C element i at [i + 1]
	c.csqcentityframehistory_next = 0
	c.csqcentityframe_lastreset = 0
	c.csqcnumedicts = 0
	c.visibletime = {} -- float [MAX_EDICTS], entity e at [e] (nil = 0)
	c.movement_count = {} -- signed char [NETGRAPH_PACKETS], 0-based (nil = 0; engine/sv_user.luau reads it)
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
	notPorted("World_Physics_RemoveFromEntity / World_Physics_RemoveJointFromEntity (world.c, ODE) in SVVM_free_edict")

	-- make sure csqc networking is aware of the removed entity
	local svs = host_cmd.svs :: any
	sv_main.sv.csqcentityversion[e] = 0 -- (sv_main.sv is server.sv, set below)
	for i = 0, svs.maxclients - 1 do
		local c = client(i)
		sv_main.CSQC_ClientFields(c)
		buffer.writeu32(c.csqcentitysendflags, e * 4, 0xFFFFFF)
	end
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
	sv_main.SV_Prepare_CSQC()
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
			sv_main.SV_SendServerinfo(host_client)
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
	a client's netconnection run only for clients with one (bots have none).

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
	Client sending (SV_SendServerinfo, the entity gathering SV_PrepareEntityForSending .. SV_WriteEntitiesToClient,
	SV_WriteClientdataToMessage, SV_SendClientDatagram).

	entity_state_t (protocol.h L381-419) is a table with the C member names: time, netcenter, origin, angles
	({ x, y, z }: C element i at [i + 1]), effects (int, kept signed), customizeentityforclient, number,
	modelindex, frame, tagentity, specialvisibilityradius, viewmodelforclient, exteriormodelforclient,
	nodrawtoclient, drawonlytoclient, traileffectnum, light ({ 4 }), active, lightstyle, lightpflags, colormap,
	skin, alpha, scale, glowsize, glowcolor, flags, internaleffects, tagindex, colormod, glowmod ({ 3 }),
	framegroupblend (4 x { frame, lerp, start }), skeletonobject ({ model, relativetransforms }). Members hold the
	value the C member type keeps (unsigned short / unsigned char truncation). It is engine/protocol.luau's
	entity_state_t: protocol.EntityState_New / EntityState_Copy / defaultstate.
	State lists passed to protocol.c (const entity_state_t **states, unsigned short *numbers) hold C element i at
	[i + 1]; the count is passed separately, as in C.

	The protocol.c encoders (EntityFrame*_WriteFrame, EntityFrame*_AllocDatabase / _FreeDatabase,
	Protocol_UpdateClientStats, Protocol_WriteStatsReliable) are engine/protocol.luau's (PROTOCOL(name) logs
	`NOT YET PORTED: protocol.<name>` once if a function is missing there).
	netconn.c / lhnet.c are not ported: sv_main.netconn and sv_main.lhnet are hook tables with the C function
	names (nil = NOT YET PORTED), so a netconn module or a test can be plugged in.
]]

local svc_nop, svc_time, svc_setangle, svc_serverinfo = 1, 7, 10, 11 -- protocol.h
local svc_clientdata, svc_damage, svc_signonnum, svc_cdtrack, svc_downloaddata = 15, 19, 25, 32, 50
local GAME_COOP, GAME_DEATHMATCH = 0, 1 -- protocol.h L177-178
local DEFAULT_VIEWHEIGHT = 22 -- protocol.h L172
-- protocol.h L127-160
local SU_VIEWHEIGHT, SU_IDEALPITCH, SU_PUNCH1, SU_VELOCITY1 = 1, 2, 4, 32
local SU_ITEMS, SU_ONGROUND, SU_INWATER, SU_WEAPONFRAME, SU_ARMOR, SU_WEAPON = 512, 1024, 2048, 4096, 8192, 16384
local SU_EXTEND1, SU_PUNCHVEC1, SU_VIEWZOOM, SU_EXTEND2 = 32768, 65536, 524288, 8388608
-- quakedef.h
local STAT_HEALTH, STAT_WEAPON, STAT_AMMO, STAT_ARMOR, STAT_WEAPONFRAME = 0, 2, 3, 4, 5
local STAT_SHELLS, STAT_NAILS, STAT_ROCKETS, STAT_CELLS, STAT_ACTIVEWEAPON = 6, 7, 8, 9, 10
local STAT_TOTALSECRETS, STAT_TOTALMONSTERS = 11, 12
local STAT_ITEMS, STAT_VIEWHEIGHT, STAT_VIEWZOOM = 15, 16, 21
local STAT_MOVEVARS_AIRACCEL_QW_STRETCHFACTOR, STAT_MOVEVARS_AIRCONTROL_PENALTY = 220, 221
local STAT_MOVEVARS_AIRSPEEDLIMIT_NONQW, STAT_MOVEVARS_AIRSTRAFEACCEL_QW, STAT_MOVEVARS_AIRCONTROL_POWER = 222, 223, 224
local STAT_MOVEFLAGS = 225
local STAT_MOVEVARS_WARSOWBUNNY_AIRFORWARDACCEL, STAT_MOVEVARS_WARSOWBUNNY_ACCEL = 226, 227
local STAT_MOVEVARS_WARSOWBUNNY_TOPSPEED, STAT_MOVEVARS_WARSOWBUNNY_TURNACCEL = 228, 229
local STAT_MOVEVARS_WARSOWBUNNY_BACKTOSIDERATIO, STAT_MOVEVARS_AIRSTOPACCELERATE = 230, 231
local STAT_MOVEVARS_AIRSTRAFEACCELERATE, STAT_MOVEVARS_MAXAIRSTRAFESPEED, STAT_MOVEVARS_AIRCONTROL = 232, 233, 234
local STAT_FRAGLIMIT, STAT_TIMELIMIT = 235, 236
local STAT_MOVEVARS_FRICTION, STAT_MOVEVARS_WATERFRICTION, STAT_MOVEVARS_TICRATE = 238, 239, 240
local STAT_MOVEVARS_TIMESCALE, STAT_MOVEVARS_GRAVITY, STAT_MOVEVARS_STOPSPEED, STAT_MOVEVARS_MAXSPEED =
	241, 242, 243, 244
local STAT_MOVEVARS_SPECTATORMAXSPEED, STAT_MOVEVARS_ACCELERATE, STAT_MOVEVARS_AIRACCELERATE = 245, 246, 247
local STAT_MOVEVARS_WATERACCELERATE, STAT_MOVEVARS_ENTGRAVITY, STAT_MOVEVARS_JUMPVELOCITY = 248, 249, 250
local STAT_MOVEVARS_EDGEFRICTION, STAT_MOVEVARS_MAXAIRSPEED, STAT_MOVEVARS_STEPHEIGHT = 251, 252, 253
local STAT_MOVEVARS_AIRACCEL_QW, STAT_MOVEVARS_AIRACCEL_SIDEWAYS_FRICTION = 254, 255
-- quakedef.h
local MOVEFLAG_VALID, MOVEFLAG_Q2AIRACCELERATE, MOVEFLAG_NOGRAVITYONGROUND = 0x80000000, 0x00000001, 0x00000002
local MOVEFLAG_GRAVITYUNAFFECTEDBYTICRATE = 0x00000004
-- protocol.h L44-75
local EF_BRIGHTFIELD, EF_BRIGHTLIGHT, EF_DIMLIGHT, EF_NODRAW, EF_ADDITIVE, EF_BLUE, EF_RED = 1, 4, 8, 16, 32, 64, 128
local EF_FULLBRIGHT, EF_FLAME, EF_STARDUST, EF_NODEPTHTEST = 512, 1024, 2048, 8192
local EF_LOWPRECISION, EF_ROTATE = 4194304, 134217728
-- protocol.h L330-337
local RENDER_STEP, RENDER_GLOWTRAIL, RENDER_VIEWMODEL, RENDER_EXTERIORMODEL = 1, 2, 4, 8
local RENDER_LOWPRECISION, RENDER_COLORMAPPED, RENDER_COMPLEXANIMATION = 16, 32, 128
local PFLAGS_FULLDYNAMIC = 128 -- protocol.h L84
local ACTIVE_NETWORK, ACTIVE_SHARED = 1, 2 -- entity_state_active_t (protocol.h L372-378)
local MOVETYPE_STEP, FL_ONGROUND = 4, 512 -- server.h
local MAX_ENTITYCLUSTERS = 16 -- progs.h
local MAX_CLIENTNETWORKEYES, MAX_LEVELNETWORKEYES, MAX_MAP_LEAFS = 16, 512, 65536 -- quakedef.h (not DP_SMALLMEMORY)
local MAX_LINEOFSIGHTTRACES = 64 -- sv_main.c L1490
local MAX_EYE_RECURSION = 1 -- sv_main.c L1761
local NET_MINRATE = 1000 -- quakedef.h
local NUM_CSQCENTITYDB_FRAMES = 256 -- server.h
local LHNETADDRESSTYPE_NONE, LHNETADDRESSTYPE_LOOP = 0, 1 -- lhnet.h
local OFS_RETURN, OFS_PARM0, OFS_PARM1 = 1, 4, 7 -- pr_comp.h

-- gamename (common.c gamemode_info, GAME_XONOTIC) and buildstring (builddate.c: the release binary's __TIME__
-- __DATE__ and revision are not known; this is the NO_BUILD_TIMESTAMPS / no SVNREVISION form)
local gamename = "Xonotic"
local buildstring = "-"

-- C conversions: (unsigned int) of a float on x86-64 (cvttss2si to 64 bits, low 32 bits kept), an unsigned
-- 32-bit value stored in an int
local function touint(x: number): number
	return libc.toint64(x) % 4294967296
end
local function toint32(u: number): number
	u = u % 4294967296
	return if u >= 0x80000000 then u - 0x100000000 else u
end
-- mathlib.h min / max: ((A) < (B) ? (A) : (B)), ((A) > (B) ? (A) : (B))
local function cmin(a: number, b: number): number
	return if a < b then a else b
end
local function cmax(a: number, b: number): number
	return if a > b then a else b
end

local function GF(prog: any, g: string): number -- PRVM_serverglobalfloat (0 if the global is missing)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.globals, o * 4)
end
local function GI(prog: any, g: string): number -- PRVM_serverglobaledict / string
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o < 0 then
		return 0
	end
	return buffer.readi32(prog.globals, o * 4)
end
local function SET_GV(prog: any, g: string, v: { number })
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writef32(prog.globals, o * 4, v[1])
		buffer.writef32(prog.globals, o * 4 + 4, v[2])
		buffer.writef32(prog.globals, o * 4 + 8, v[3])
	end
end

-- a cvar_t of the C file by its C variable name (host.cv, registered by host.Host_Init_Dedicated)
local function CV(var: string): any
	local c = HOST().cv[var]
	if not c then
		error("sv_main: cvar " .. var .. " is not registered (run host.Host_Init_Dedicated first)", 0)
	end
	return c
end
-- r_trippy (gl_rmain.c) is a client cvar a dedicated server never registers: its static cvar_t has integer 0
local function r_trippy_integer(): number
	local c = HOST().cv.r_trippy
	return if c then c.integer else 0
end

-- engine/sv_phys.luau (sv_phys requires this module), required on first use and kept
local svphysmod: any = nil
local function SVPHYS(): any
	if not svphysmod then
		svphysmod = require("./sv_phys")
	end
	return svphysmod
end

-- protocol.<name> (nil after logging NOT YET PORTED once if engine/protocol.luau lacks the function)
local function PROTOCOL(name: string): any
	local f = (protocol :: any)[name]
	if f == nil then
		notPorted("protocol." .. name)
	end
	return f
end
local Protocol_NumberForEnum = protocol.Protocol_NumberForEnum

-- the client_t csqc entity arrays and stats / statsdeltabits, created zeroed on first use (protocol.luau's
-- representation: csqcentityscope buffer of MAX_EDICTS u8, csqcentitysendflags buffer of MAX_EDICTS u32,
-- csqcentityframehistory[i + 1] = { framenum, num, entno, sendflags }, stats / statsdeltabits 0-based tables)
local CSQC_ClientFields = protocol.CSQC_ClientFields
local Stats_ClientFields = protocol.Stats_ClientFields
sv_main.CSQC_ClientFields = CSQC_ClientFields

-- the int with the bits of float v (statsf[i] = v writes the float into the int array stats)
local floatbitsbuf = buffer.create(4)
local function floatbits(v: number): number
	buffer.writef32(floatbitsbuf, 0, v)
	return buffer.readi32(floatbitsbuf, 0)
end

-- entity_state_t: a zeroed one, `*dst = *src`, defaultstate (engine/protocol.luau)
local newstate = protocol.EntityState_New
local copystate = protocol.EntityState_Copy
local function defaultstate(): any
	return protocol.defaultstate
end

--[[
	netconn.c / lhnet.c hooks (not ported, M6-NET). A netconn module or a test sets
	  sv_main.netconn = { NetConn_CanSend = function(conn): boolean,
	                      NetConn_SendUnreliableMessage = function(conn, msg, protocol, rate, burstsize,
	                                                               suppress_reliables): number }
	  sv_main.lhnet = { LHNETADDRESS_GetAddressType = function(address): number }
	msg is the sizebuf_t of SV_SendClientDatagram (its data buffer is reused next frame: copy what is kept).
	Without them: NetConn_CanSend logs NOT YET PORTED and returns true (the datagram is still built),
	NetConn_SendUnreliableMessage logs and sends nothing, LHNETADDRESS_GetAddressType logs and returns
	LHNETADDRESSTYPE_NONE.
]]
sv_main.netconn = nil :: any
sv_main.lhnet = nil :: any

local function NetConn_CanSend(conn: any): boolean
	local h = sv_main.netconn
	local f = h and h.NetConn_CanSend
	if not f then
		notPorted("NetConn_CanSend (netconn.c, M6-NET; sv_main.netconn hook not set)")
		return true
	end
	return f(conn)
end
local function NetConn_SendUnreliableMessage(
	conn: any,
	data: any,
	protocol: number,
	rate: number,
	burstsize: number,
	quakesignon_suppressreliables: boolean
): number
	local h = sv_main.netconn
	local f = h and h.NetConn_SendUnreliableMessage
	if not f then
		notPorted("NetConn_SendUnreliableMessage (netconn.c, M6-NET; sv_main.netconn hook not set)")
		return -1
	end
	return f(conn, data, protocol, rate, burstsize, quakesignon_suppressreliables)
end
local function LHNETADDRESS_GetAddressType(address: any): number
	local h = sv_main.lhnet
	local f = h and h.LHNETADDRESS_GetAddressType
	if not f then
		notPorted("LHNETADDRESS_GetAddressType (lhnet.c, M6-NET; sv_main.lhnet hook not set)")
		return LHNETADDRESSTYPE_NONE
	end
	return f(address)
end

-- client - svs.clients (the 0-based slot of a client_t table)
local function clientnumber(c: any): number
	local svs = host_cmd.svs :: any
	for i = 0, svs.maxclients - 1 do
		if svs.clients and svs.clients[i] == c then
			return i
		end
	end
	error("sv_main: client is not a client slot", 0)
end

-- sv_demo.c: every function returns at once without a demo file (client->sv_demo_file == NULL)
local function SV_StopDemoRecording(c: any)
	if c.sv_demo_file == nil then
		return
	end
	notPorted("SV_StopDemoRecording (sv_demo.c)")
end
local function SV_WriteDemoMessage(c: any, _sendbuffer: any, _clienttoserver: boolean)
	if c.sv_demo_file == nil then
		return
	end
	notPorted("SV_WriteDemoMessage (sv_demo.c)")
end

-- port: libcurl.c Curl_SendRequirements L1811-1833 @xonotic-v0.8.6 (PARTIAL: Curl_RequireFile is not ported,
-- so the requirement list is empty; Curl_SendRequirement (FS_WhichPack, Curl_FindPackURL) is not ported and
-- counts as returning false)
local function Curl_SendRequirements()
	-- for each requirement, find the pack name
	local sendbuffer = ""
	local foundone = false
	local p

	-- for(req = requirements; req; req = req->next): the list is empty (Curl_RequireFile is not ported)

	local packages = CV("sv_curl_serverpackages").string.str
	p = 1
	while true do
		local ok
		ok, p = common.COM_ParseToken_Simple(packages, p, false, false, true)
		if not ok then
			break
		end
		notPorted("Curl_SendRequirement (libcurl.c: FS_WhichPack, Curl_FindPackURL) in Curl_SendRequirements")
		foundone = false or foundone
	end

	if foundone then
		sendbuffer = string.sub(sendbuffer .. "curl --finish_autodownload\n", 1, 4095)
	end

	if #sendbuffer + 1 < 4096 then
		HOST().Host_ClientCommands("%s", sendbuffer)
	else
		console.Con_Printf("Could not initiate autodownload due to URL buffer overflow\n")
	end
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
==============================================================================

CLIENT SPAWNING

==============================================================================
]]

--[[
================
SV_SendServerinfo

Sends the first message from the server to a connected client.
This will be sent on the initial connection and upon each server load.
================
]]
-- port: sv_main.c SV_SendServerinfo L880-1059 @xonotic-v0.8.6
function sv_main.SV_SendServerinfo(c: any)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local i
	local message
	local f

	-- we know that this client has a netconnection and thus is not a bot

	-- edicts get reallocated on level changes, so we need to update it here
	c.edict = clientnumber(c) + 1 -- PRVM_EDICT_NUM((client - svs.clients) + 1)

	-- clear cached stuff that depends on the level
	c.weaponmodel = ""
	c.weaponmodelindex = 0

	-- LordHavoc: clear entityframe tracking
	c.latestframenum = 0

	-- initialize the movetime, so a speedhack can't make use of the time before this client joined
	c.cmd.time = sv.time

	-- (the pointers are not cleared after the frees: the allocations below replace the one of the protocol)
	if c.entitydatabase then
		f = PROTOCOL("EntityFrame_FreeDatabase")
		if f then
			f(c.entitydatabase)
		end
	end
	if c.entitydatabase4 then
		f = PROTOCOL("EntityFrame4_FreeDatabase")
		if f then
			f(c.entitydatabase4)
		end
	end
	if c.entitydatabase5 then
		f = PROTOCOL("EntityFrame5_FreeDatabase")
		if f then
			f(c.entitydatabase5)
		end
	end

	-- memset(client->stats, 0, sizeof(client->stats)); memset(client->statsdeltabits, 0, ...)
	Stats_ClientFields(c)
	for k = 0, MAX_CL_STATS - 1 do
		c.stats[k] = 0
	end
	for k = 0, (MAX_CL_STATS + 7) // 8 - 1 do
		c.statsdeltabits[k] = 0
	end

	if not oldprotocol(sv.protocol) then
		if sv.protocol == P.DARKPLACES1 or sv.protocol == P.DARKPLACES2 or sv.protocol == P.DARKPLACES3 then
			f = PROTOCOL("EntityFrame_AllocDatabase") -- (sv_mempool)
			c.entitydatabase = if f then f() else nil
		elseif sv.protocol == P.DARKPLACES4 then
			f = PROTOCOL("EntityFrame4_AllocDatabase")
			c.entitydatabase4 = if f then f() else nil
		else
			f = PROTOCOL("EntityFrame5_AllocDatabase")
			c.entitydatabase5 = if f then f() else nil
		end
	end

	-- reset csqc entity versions
	CSQC_ClientFields(c)
	for e = 0, prog.max_edicts - 1 do
		buffer.writeu8(c.csqcentityscope, e, 0)
		buffer.writeu32(c.csqcentitysendflags, e * 4, 0xFFFFFF)
	end
	for k = 0, NUM_CSQCENTITYDB_FRAMES - 1 do
		local h = c.csqcentityframehistory[k + 1]
		h.num = 0
		h.framenum = -1
	end
	c.csqcnumedicts = 0
	c.csqcentityframehistory_next = 0

	local msg = c.netconnection.message
	common.SZ_Clear(msg)
	common.MSG_WriteByte(msg, svc_print)
	if prog.filecrc == nil then
		notPorted("prog->filecrc (prvm_edict.c PRVM_Prog_Load L1969: CRC_Block of progs.dat) in SV_SendServerinfo")
	end
	message = libc.snprintf(128, "\nServer: %s build %s (progs %i crc)\n", gamename, buildstring, prog.filecrc or 0)
	common.MSG_WriteString(msg, message)

	SV_StopDemoRecording(c) -- to split up demos into different files
	if CV("sv_autodemo_perclient").integer ~= 0 then
		-- start a new demo file
		notPorted(
			"SV_StartDemoRecording for sv_autodemo_perclient (sv_demo.c, LHNETADDRESS_ToString, Sys_TimeString) in SV_SendServerinfo"
		)
	end

	--[515]: init csprogs according to version of svprogs, check the crc, etc.
	if sv.csqc_progname ~= "" then
		console.Con_DPrintf(
			'sending csqc info to client ("%s" with size %i and crc %i)\n',
			sv.csqc_progname,
			sv.csqc_progsize,
			sv.csqc_progcrc
		)
		common.MSG_WriteByte(msg, svc_stufftext)
		common.MSG_WriteString(msg, libc.snprintf(1024, "csqc_progname %s\n", sv.csqc_progname))
		common.MSG_WriteByte(msg, svc_stufftext)
		common.MSG_WriteString(msg, libc.snprintf(1024, "csqc_progsize %i\n", sv.csqc_progsize))
		common.MSG_WriteByte(msg, svc_stufftext)
		common.MSG_WriteString(msg, libc.snprintf(1024, "csqc_progcrc %i\n", sv.csqc_progcrc))

		if c.sv_demo_file ~= nil then
			notPorted("MakeDownloadPacket / SV_WriteDemoMessage of csprogs.dat (sv_demo.c) in SV_SendServerinfo")
		end

		--[515]: init stufftext string (it is sent before svc_serverinfo)
		-- (PRVM_GetString never returns NULL, so this is always sent)
		local initcmd = prvm_edict.PRVM_GetString(prog, GI(prog, "SV_InitCmd"))
		if initcmd then
			common.MSG_WriteByte(msg, svc_stufftext)
			common.MSG_WriteString(msg, libc.snprintf(1024, "%s\n", libc.cstr(initcmd)))
		end
	end

	--if (sv_allowdownloads.integer)
	-- always send the info that the server supports the protocol, even if downloads are forbidden
	-- only because of that, the CSQC exception can work
	do
		common.MSG_WriteByte(msg, svc_stufftext)
		common.MSG_WriteString(msg, "cl_serverextension_download 2\n")
	end

	-- send at this time so it's guaranteed to get executed at the right time
	do
		local save = server.host_client
		server.host_client = c
		Curl_SendRequirements()
		server.host_client = save
	end

	common.MSG_WriteByte(msg, svc_serverinfo)
	common.MSG_WriteLong(msg, Protocol_NumberForEnum(sv.protocol))
	common.MSG_WriteByte(msg, svs.maxclients)

	if CV("coop").integer == 0 and CV("deathmatch").integer ~= 0 then
		common.MSG_WriteByte(msg, GAME_DEATHMATCH)
	else
		common.MSG_WriteByte(msg, GAME_COOP)
	end

	common.MSG_WriteString(msg, prvm_edict.PRVM_GetString(prog, geti(prog, 0, "message")))

	i = 1
	while i < server.MAX_MODELS and (sv.model_precache[i] or "") ~= "" do
		common.MSG_WriteString(msg, sv.model_precache[i])
		i += 1
	end
	common.MSG_WriteByte(msg, 0)

	i = 1
	while i < server.MAX_SOUNDS and (sv.sound_precache[i] or "") ~= "" do
		common.MSG_WriteString(msg, sv.sound_precache[i])
		i += 1
	end
	common.MSG_WriteByte(msg, 0)

	-- send music
	common.MSG_WriteByte(msg, svc_cdtrack)
	common.MSG_WriteByte(msg, libc.toint(getf(prog, 0, "sounds")))
	common.MSG_WriteByte(msg, libc.toint(getf(prog, 0, "sounds")))

	-- set view
	-- store this in clientcamera, too
	c.clientcamera = c.edict
	common.MSG_WriteByte(msg, svc_setview)
	common.MSG_WriteShort(msg, c.clientcamera)

	common.MSG_WriteByte(msg, svc_signonnum)
	common.MSG_WriteByte(msg, 1)

	c.prespawned = false -- need prespawn, spawn, etc
	c.spawned = false -- need prespawn, spawn, etc
	c.begun = false -- need prespawn, spawn, etc
	c.sendsignon = 1 -- send this message, and increment to 2, 2 will be set to 0 by the prespawn command

	-- clear movement info until client enters the new level properly
	table.clear(c.cmd) -- memset(&client->cmd, 0, sizeof(client->cmd))
	c.movesequence = 0
	c.movement_highestsequence_seen = 0
	table.clear(c.movement_count)
	-- (NUM_PING_TIMES is not defined)
	c.ping = 0

	-- allow the client some time to send his keepalives, even if map loading took ages
	c.netconnection.timeout = prvm_edict.realtime + CV("net_connecttimeout").value
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
		sv_main.SV_SendServerinfo(c)
	else
		c.prespawned = true
		c.spawned = true
		c.begun = true
	end
end

--[[
===============================================================================

FRAME UPDATES

===============================================================================
]]

--[[
=============================================================================

The PVS must include a small area around the client to allow head bobbing
or other small motion on the client side.  Otherwise, a bob might cause an
entity that should be visible to not show up, especially when the bob
crosses a waterline.

=============================================================================
]]

-- ent->priv.server->cullmins / cullmaxs / pvs_numclusters / pvs_clusterlist of edict e (prog.ed_cullmins[e],
-- ...; created as the zeroed priv memory on first use; pvs_clusterlist holds C element i at [i + 1])
local function edcull(prog: any, e: number): ({ number }, { number })
	local mins = prog.ed_cullmins
	if not mins then
		mins = {}
		prog.ed_cullmins = mins
		prog.ed_cullmaxs = {}
		prog.ed_pvs_numclusters = {}
		prog.ed_pvs_clusterlist = {}
	end
	local m = mins[e]
	if not m then
		m = { 0, 0, 0 }
		mins[e] = m
		prog.ed_cullmaxs[e] = { 0, 0, 0 }
		prog.ed_pvs_numclusters[e] = 0
		prog.ed_pvs_clusterlist[e] = {}
	end
	return m, prog.ed_cullmaxs[e]
end
sv_main.edcull = edcull

-- port: sv_main.c SV_PrepareEntityForSending L1163-1469 @xonotic-v0.8.6
-- (ent: edict number; cs: the entity_state_t table filled in place; gamemode is GAME_XONOTIC, not Tenebrae)
local function SV_PrepareEntityForSending(ent: number, cs: any, enumber: number): boolean
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local i
	local sendflags
	local version
	local modelindex, effects, flags, glowsize, lightstyle, lightpflags, specialvisibilityradius
	local light = { 0, 0, 0, 0 } -- unsigned int light[4]
	local customizeentityforclient
	local sendentity
	local f
	local vx, vy, vz
	local cullmins, cullmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local model

	-- fast path for games that do not use legacy entity networking
	-- note: still networks clients even if they are legacy
	sendentity = geti(prog, ent, "SendEntity")
	if CV("sv_onlycsqcnetworking").integer ~= 0 and sendentity == 0 and enumber > svs.maxclients then
		return false
	end

	-- this 2 billion unit check is actually to detect NAN origins
	-- (we really don't want to send those)
	local ox, oy, oz = getvi(prog, ent, "origin", 0), getvi(prog, ent, "origin", 1), getvi(prog, ent, "origin", 2)
	if not (R(R(R(ox * ox) + R(oy * oy)) + R(oz * oz)) < 2000000000.0 * 2000000000.0) then
		return false
	end

	-- EF_NODRAW prevents sending for any reason except for your own
	-- client, so we must keep all clients in this superset
	effects = touint(getf(prog, ent, "effects"))

	-- we can omit invisible entities with no effects that are not clients
	-- LordHavoc: this could kill tags attached to an invisible entity, I
	-- just hope we never have to support that case
	i = libc.toint(getf(prog, ent, "modelindex"))
	local modelstr = geti(prog, ent, "model")
	modelindex = if i >= 1
			and i < server.MAX_MODELS
			and modelstr ~= 0
			and libc.cstr(prvm_edict.PRVM_GetString(prog, modelstr)) ~= ""
			and sv.models[i]
		then i
		else 0

	flags = 0
	i = libc.toint(R(getf(prog, ent, "glow_size") * 0.25))
	glowsize = bit32.band(bound(0, i, 255), 255) -- (unsigned char)
	if getf(prog, ent, "glow_trail") ~= 0 then
		flags = bit32.bor(flags, RENDER_GLOWTRAIL)
	end
	if geti(prog, ent, "viewmodelforclient") ~= 0 then
		flags = bit32.bor(flags, RENDER_VIEWMODEL)
	end

	-- (unsigned short)bound(0, f, 65535): f in range, or 0 for a NaN
	f = R(getvi(prog, ent, "color", 0) * 256)
	light[1] = libc.toint(bound(0, f, 65535))
	f = R(getvi(prog, ent, "color", 1) * 256)
	light[2] = libc.toint(bound(0, f, 65535))
	f = R(getvi(prog, ent, "color", 2) * 256)
	light[3] = libc.toint(bound(0, f, 65535))
	f = getf(prog, ent, "light_lev")
	light[4] = libc.toint(bound(0, f, 65535))
	lightstyle = bit32.band(libc.toint(getf(prog, ent, "style")), 255) -- (unsigned char) of the float
	lightpflags = bit32.band(libc.toint(getf(prog, ent, "pflags")), 255)

	-- (gamemode == GAME_TENEBRAE: EF_FULLDYNAMIC / EF_GREEN remapping, not for Xonotic)

	specialvisibilityradius = 0
	if bit32.band(lightpflags, PFLAGS_FULLDYNAMIC) ~= 0 then
		specialvisibilityradius = cmax(specialvisibilityradius, light[4])
	end
	if glowsize ~= 0 then
		specialvisibilityradius = cmax(specialvisibilityradius, glowsize * 4)
	end
	if bit32.band(flags, RENDER_GLOWTRAIL) ~= 0 then
		specialvisibilityradius = cmax(specialvisibilityradius, 100)
	end
	if
		bit32.band(
			effects,
			bit32.bor(
				EF_BRIGHTFIELD,
				EF_MUZZLEFLASH,
				EF_BRIGHTLIGHT,
				EF_DIMLIGHT,
				EF_RED,
				EF_BLUE,
				EF_FLAME,
				EF_STARDUST
			)
		) ~= 0
	then
		if bit32.band(effects, EF_BRIGHTFIELD) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 80)
		end
		if bit32.band(effects, EF_MUZZLEFLASH) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 100)
		end
		if bit32.band(effects, EF_BRIGHTLIGHT) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 400)
		end
		if bit32.band(effects, EF_DIMLIGHT) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 200)
		end
		if bit32.band(effects, EF_RED) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 200)
		end
		if bit32.band(effects, EF_BLUE) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 200)
		end
		if bit32.band(effects, EF_FLAME) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 250)
		end
		if bit32.band(effects, EF_STARDUST) ~= 0 then
			specialvisibilityradius = cmax(specialvisibilityradius, 100)
		end
	end

	-- early culling checks
	-- (final culling is done by SV_MarkWriteEntityStateToClient)
	customizeentityforclient = geti(prog, ent, "customizeentityforclient")
	if
		customizeentityforclient == 0
		and enumber > svs.maxclients
		and (modelindex == 0 and specialvisibilityradius == 0)
	then
		return false
	end

	copystate(cs, defaultstate()) -- *cs = defaultstate
	cs.active = ACTIVE_NETWORK
	cs.number = bit32.band(enumber, 0xFFFF)
	cs.origin[1], cs.origin[2], cs.origin[3] = ox, oy, oz
	cs.angles[1], cs.angles[2], cs.angles[3] =
		getvi(prog, ent, "angles", 0), getvi(prog, ent, "angles", 1), getvi(prog, ent, "angles", 2)
	cs.flags = flags
	cs.effects = toint32(effects)
	cs.colormap = bit32.band(touint(getf(prog, ent, "colormap")), 255)
	cs.modelindex = bit32.band(modelindex, 0xFFFF)
	cs.skin = bit32.band(touint(getf(prog, ent, "skin")), 255)
	cs.frame = bit32.band(touint(getf(prog, ent, "frame")), 0xFFFF)
	cs.viewmodelforclient = bit32.band(geti(prog, ent, "viewmodelforclient"), 0xFFFF)
	cs.exteriormodelforclient = bit32.band(geti(prog, ent, "exteriormodeltoclient"), 0xFFFF)
	cs.nodrawtoclient = bit32.band(geti(prog, ent, "nodrawtoclient"), 0xFFFF)
	cs.drawonlytoclient = bit32.band(geti(prog, ent, "drawonlytoclient"), 0xFFFF)
	cs.customizeentityforclient = customizeentityforclient % 4294967296
	cs.tagentity = bit32.band(geti(prog, ent, "tag_entity"), 0xFFFF)
	cs.tagindex = bit32.band(libc.toint(getf(prog, ent, "tag_index")), 255)
	cs.glowsize = glowsize
	cs.traileffectnum = bit32.band(libc.toint(getf(prog, ent, "traileffectnum")), 0xFFFF)

	-- don't need to init cs->colormod because the defaultstate did that for us
	--cs->colormod[0] = cs->colormod[1] = cs->colormod[2] = 32;
	vx, vy, vz = getvi(prog, ent, "colormod", 0), getvi(prog, ent, "colormod", 1), getvi(prog, ent, "colormod", 2)
	if R(R(R(vx * vx) + R(vy * vy)) + R(vz * vz)) ~= 0 then
		i = libc.toint(R(vx * 32.0))
		cs.colormod[1] = bound(0, i, 255)
		i = libc.toint(R(vy * 32.0))
		cs.colormod[2] = bound(0, i, 255)
		i = libc.toint(R(vz * 32.0))
		cs.colormod[3] = bound(0, i, 255)
	end

	-- don't need to init cs->glowmod because the defaultstate did that for us
	--cs->glowmod[0] = cs->glowmod[1] = cs->glowmod[2] = 32;
	vx, vy, vz = getvi(prog, ent, "glowmod", 0), getvi(prog, ent, "glowmod", 1), getvi(prog, ent, "glowmod", 2)
	if R(R(R(vx * vx) + R(vy * vy)) + R(vz * vz)) ~= 0 then
		i = libc.toint(R(vx * 32.0))
		cs.glowmod[1] = bound(0, i, 255)
		i = libc.toint(R(vy * 32.0))
		cs.glowmod[2] = bound(0, i, 255)
		i = libc.toint(R(vz * 32.0))
		cs.glowmod[3] = bound(0, i, 255)
	end

	cs.modelindex = bit32.band(modelindex, 0xFFFF)

	cs.alpha = 255
	f = R(getf(prog, ent, "alpha") * 255.0)
	if f ~= 0 then
		i = libc.toint(f)
		cs.alpha = bound(0, i, 255)
	end
	-- halflife
	f = getf(prog, ent, "renderamt")
	if f ~= 0 then
		i = libc.toint(f)
		cs.alpha = bound(0, i, 255)
	end

	cs.scale = 16
	f = R(getf(prog, ent, "scale") * 16.0)
	if f ~= 0 then
		i = libc.toint(f)
		cs.scale = bound(0, i, 255)
	end

	cs.glowcolor = 254
	f = getf(prog, ent, "glow_color")
	if f ~= 0 then
		cs.glowcolor = bit32.band(libc.toint(f), 255)
	end

	if getf(prog, ent, "fullbright") ~= 0 then
		cs.effects = toint32(bit32.bor(cs.effects, EF_FULLBRIGHT))
	end

	f = getf(prog, ent, "modelflags")
	if f ~= 0 then
		cs.effects = toint32(bit32.bor(cs.effects, bit32.lshift(bit32.band(touint(f), 0xff), 24)))
	end

	if getf(prog, ent, "movetype") == MOVETYPE_STEP then
		cs.flags = bit32.bor(cs.flags, RENDER_STEP)
	end
	-- (engine quirk kept: sv.writeentitiestoclient_cliententitynumber is still the one of the last client the
	-- previous frame wrote to, SV_WriteEntitiesToClient sets it after this runs)
	if
		cs.number ~= sv.writeentitiestoclient_cliententitynumber
		and bit32.band(cs.effects, EF_LOWPRECISION) ~= 0
		and cs.origin[1] >= -32768
		and cs.origin[2] >= -32768
		and cs.origin[3] >= -32768
		and cs.origin[1] <= 32767
		and cs.origin[2] <= 32767
		and cs.origin[3] <= 32767
	then
		cs.flags = bit32.bor(cs.flags, RENDER_LOWPRECISION)
	end
	if getf(prog, ent, "colormap") >= 1024 then
		cs.flags = bit32.bor(cs.flags, RENDER_COLORMAPPED)
	end
	if cs.viewmodelforclient ~= 0 then
		cs.flags = bit32.bor(cs.flags, RENDER_VIEWMODEL) -- show relative to the view
	end

	if getf(prog, ent, "sendcomplexanimation") ~= 0 then
		cs.flags = bit32.bor(cs.flags, RENDER_COMPLEXANIMATION)
		if getf(prog, ent, "skeletonindex") >= 1 then
			local _, _, skeleton = prvm_cmds.EdictFrameBlend(prog, ent) -- ent->priv.server->skeleton
			cs.skeletonobject.model = skeleton.model
			cs.skeletonobject.relativetransforms = skeleton.relativetransforms
		end
		local fgb = cs.framegroupblend
		fgb[1].frame = libc.toint(getf(prog, ent, "frame")) -- (int member)
		fgb[2].frame = libc.toint(getf(prog, ent, "frame2"))
		fgb[3].frame = libc.toint(getf(prog, ent, "frame3"))
		fgb[4].frame = libc.toint(getf(prog, ent, "frame4"))
		fgb[1].start = getf(prog, ent, "frame1time")
		fgb[2].start = getf(prog, ent, "frame2time")
		fgb[3].start = getf(prog, ent, "frame3time")
		fgb[4].start = getf(prog, ent, "frame4time")
		fgb[2].lerp = getf(prog, ent, "lerpfrac")
		fgb[3].lerp = getf(prog, ent, "lerpfrac3")
		fgb[4].lerp = getf(prog, ent, "lerpfrac4")
		fgb[1].lerp = R(R(R(1.0 - fgb[2].lerp) - fgb[3].lerp) - fgb[4].lerp)
		cs.frame = 0 -- don't need the legacy frame
	end

	cs.light[1] = light[1]
	cs.light[2] = light[2]
	cs.light[3] = light[3]
	cs.light[4] = light[4]
	cs.lightstyle = lightstyle
	cs.lightpflags = lightpflags

	cs.specialvisibilityradius = bit32.band(specialvisibilityradius, 0xFFFF)

	-- calculate the visible box of this entity (don't use the physics box
	-- as that is often smaller than a model, and would not count
	-- specialvisibilityradius)
	model = sv_main.SV_GetModelByIndex(modelindex)
	if model and model.type ~= "mod_null" then
		local scale = R(cs.scale * (1.0 / 16.0))
		local mn, mx
		if cs.angles[1] ~= 0 or cs.angles[3] ~= 0 then -- pitch and roll
			mn, mx = model.rotatedmins, model.rotatedmaxs
		elseif cs.angles[2] ~= 0 or bit32.band(bit32.bor(effects, model.effects or 0), EF_ROTATE) ~= 0 then
			mn, mx = model.yawmins, model.yawmaxs
		else
			mn, mx = model.normalmins, model.normalmaxs
		end
		for k = 1, 3 do -- VectorMA(cs->origin, scale, ..., cullmins / cullmaxs)
			cullmins[k] = R(cs.origin[k] + R(scale * mn[k]))
			cullmaxs[k] = R(cs.origin[k] + R(scale * mx[k]))
		end
	else
		-- if there is no model (or it could not be loaded), use the physics box
		for k = 1, 3 do
			cullmins[k] = R(cs.origin[k] + getvi(prog, ent, "mins", k - 1))
			cullmaxs[k] = R(cs.origin[k] + getvi(prog, ent, "maxs", k - 1))
		end
	end
	if specialvisibilityradius ~= 0 then
		for k = 1, 3 do
			cullmins[k] = cmin(cullmins[k], R(cs.origin[k] - specialvisibilityradius))
		end
		for k = 1, 3 do
			cullmaxs[k] = cmax(cullmaxs[k], R(cs.origin[k] + specialvisibilityradius))
		end
	end

	-- calculate center of bbox for network prioritization purposes
	for k = 1, 3 do -- VectorMAM(0.5f, cullmins, 0.5f, cullmaxs, cs->netcenter)
		cs.netcenter[k] = R(R(0.5 * cullmins[k]) + R(0.5 * cullmaxs[k]))
	end

	-- if culling box has moved, update pvs cluster links
	local edmins, edmaxs = edcull(prog, ent)
	if
		not (edmins[1] == cullmins[1] and edmins[2] == cullmins[2] and edmins[3] == cullmins[3])
		or not (edmaxs[1] == cullmaxs[1] and edmaxs[2] == cullmaxs[2] and edmaxs[3] == cullmaxs[3])
	then
		edmins[1], edmins[2], edmins[3] = cullmins[1], cullmins[2], cullmins[3]
		edmaxs[1], edmaxs[2], edmaxs[3] = cullmaxs[1], cullmaxs[2], cullmaxs[3]
		-- a value of -1 for pvs_numclusters indicates that the links are not
		-- cached, and should be re-tested each time, this is the case if the
		-- culling box touches too many pvs clusters to store, or if the world
		-- model does not support FindBoxClusters
		prog.ed_pvs_numclusters[ent] = -1
		if sv.worldmodel and sv.worldmodel.brush.FindBoxClusters then
			i = sv.worldmodel.brush.FindBoxClusters(
				sv.worldmodel,
				cullmins,
				cullmaxs,
				MAX_ENTITYCLUSTERS,
				prog.ed_pvs_clusterlist[ent]
			)
			if i <= MAX_ENTITYCLUSTERS then
				prog.ed_pvs_numclusters[ent] = i
			end
		elseif sv.worldmodel and sv.worldmodel.brush.GetPVS then
			-- (the C BSP loaders set FindBoxClusters together with GetPVS)
			notPorted("Mod_Q1BSP_FindBoxClusters (model_brush.c, brush.FindBoxClusters) in SV_PrepareEntityForSending")
		end
	end

	-- we need to do some csqc entity upkeep here
	-- get self.SendFlags and clear them
	-- (to let the QC know that they've been read)
	if sendentity ~= 0 then
		sendflags = touint(getf(prog, ent, "SendFlags"))
		setf(prog, ent, "SendFlags", 0)
		-- legacy self.Version system
		version = touint(getf(prog, ent, "Version"))
		if version ~= 0 then
			-- (unsigned char csqcentityversion[]: a version over 255 never compares equal, engine quirk kept)
			if (sv.csqcentityversion[enumber] or 0) ~= version then
				sendflags = 0xFFFFFF
			end
			sv.csqcentityversion[enumber] = bit32.band(version, 255)
		end
		-- move sendflags into the per-client sendflags
		if sendflags ~= 0 then
			for ci = 0, svs.maxclients - 1 do
				local cl = client(ci)
				CSQC_ClientFields(cl)
				local sf = cl.csqcentitysendflags
				buffer.writeu32(sf, enumber * 4, bit32.bor(buffer.readu32(sf, enumber * 4), sendflags))
			end
		end
		-- mark it as inactive for non-csqc networking
		cs.active = ACTIVE_SHARED
	end

	return true
end
sv_main.SV_PrepareEntityForSending = SV_PrepareEntityForSending

-- port: sv_main.c SV_PrepareEntitiesForSending L1471-1488 @xonotic-v0.8.6
local function SV_PrepareEntitiesForSending()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local sendentities, sendentitiesindex = sv.sendentities, sv.sendentitiesindex
	-- send all entities that touch the pvs
	sv.numsendentities = 0
	sendentitiesindex[0] = nil
	for e = 0, prog.num_edicts - 1 do -- memset(sv.sendentitiesindex, 0, prog->num_edicts * sizeof(...))
		sendentitiesindex[e] = nil
	end
	for e = 1, prog.num_edicts - 1 do
		local cs = sendentities[sv.numsendentities + 1] -- sv.sendentities + sv.numsendentities
		if not cs then
			cs = newstate()
			sendentities[sv.numsendentities + 1] = cs
		end
		if not prog.ed_free[e] and SV_PrepareEntityForSending(e, cs, e) then
			sendentitiesindex[e] = cs
			sv.numsendentities += 1
		end
	end
end
sv_main.SV_PrepareEntitiesForSending = SV_PrepareEntitiesForSending

-- mathlib.h lhrandom(MIN,MAX) with float arguments: (MAX)-(MIN) is a float subtraction, the rest double
local function lhrandomf(mn: number, mx: number): number
	return ((libc.rand() + 0.5) / (libc.RAND_MAX + 1)) * R(mx - mn) + mn
end

local touchedicts_CanSeeBox: { number } = {} -- static prvm_edict_t *touchedicts[MAX_EDICTS]

-- port: sv_main.c SV_CanSeeBox L1492-1630 @xonotic-v0.8.6
function sv_main.SV_CanSeeBox(
	numtraces: number,
	eyejitter: number,
	enlarge: number,
	eye: { number },
	entboxmins: { number },
	entboxmaxs: { number }
): boolean
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local pitchsign
	local alpha
	local starttransformed, endtransformed = { 0, 0, 0 }, { 0, 0, 0 }
	local boxminstransformed, boxmaxstransformed = { 0, 0, 0 }, { 0, 0, 0 }
	local localboxcenter, localboxextents = { 0, 0, 0 }, { 0, 0, 0 }
	local localboxmins, localboxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local blocked = 0
	local originalnumtouchedicts
	local numtouchedicts = 0
	local touchindex
	local matrix, imatrix = matrixlib.new(), matrixlib.new()
	local model
	local touch
	local touchedicts = touchedicts_CanSeeBox
	local eyemins, eyemaxs, start = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local boxmins, boxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local clipboxmins, clipboxmaxs = { 0, 0, 0 }, { 0, 0, 0 }
	local endpoints: { { number } } = {} -- vec3_t endpoints[MAX_LINEOFSIGHTTRACES], C element i at [i + 1]

	numtraces = cmin(numtraces, MAX_LINEOFSIGHTTRACES)

	-- jitter the eye location within this box
	eyemins[1] = R(eye[1] - eyejitter)
	eyemaxs[1] = R(eye[1] + eyejitter)
	eyemins[2] = R(eye[2] - eyejitter)
	eyemaxs[2] = R(eye[2] + eyejitter)
	eyemins[3] = R(eye[3] - eyejitter)
	eyemaxs[3] = R(eye[3] + eyejitter)
	-- expand the box a little
	for k = 1, 3 do
		boxmins[k] = R(R(R(enlarge + 1) * entboxmins[k]) - R(enlarge * entboxmaxs[k]))
		boxmaxs[k] = R(R(R(enlarge + 1) * entboxmaxs[k]) - R(enlarge * entboxmins[k]))
	end

	endpoints[1] = { -- VectorMAM(0.5f, boxmins, 0.5f, boxmaxs, endpoints[0])
		R(R(0.5 * boxmins[1]) + R(0.5 * boxmaxs[1])),
		R(R(0.5 * boxmins[2]) + R(0.5 * boxmaxs[2])),
		R(R(0.5 * boxmins[3]) + R(0.5 * boxmaxs[3])),
	}
	for traceindex = 1, numtraces - 1 do
		-- VectorSet: x, y, z in this order
		local x = R(lhrandomf(boxmins[1], boxmaxs[1]))
		local y = R(lhrandomf(boxmins[2], boxmaxs[2]))
		local z = R(lhrandomf(boxmins[3], boxmaxs[3]))
		endpoints[traceindex + 1] = { x, y, z }
	end

	-- calculate sweep box for the entire swarm of traces
	clipboxmins[1], clipboxmins[2], clipboxmins[3] = eyemins[1], eyemins[2], eyemins[3]
	clipboxmaxs[1], clipboxmaxs[2], clipboxmaxs[3] = eyemaxs[1], eyemaxs[2], eyemaxs[3]
	for traceindex = 0, numtraces - 1 do
		local ep = endpoints[traceindex + 1]
		clipboxmins[1] = cmin(clipboxmins[1], ep[1])
		clipboxmins[2] = cmin(clipboxmins[2], ep[2])
		clipboxmins[3] = cmin(clipboxmins[3], ep[3])
		clipboxmaxs[1] = cmax(clipboxmaxs[1], ep[1])
		clipboxmaxs[2] = cmax(clipboxmaxs[2], ep[2])
		clipboxmaxs[3] = cmax(clipboxmaxs[3], ep[3])
	end

	-- get the list of entities in the sweep box
	if CV("sv_cullentities_trace_entityocclusion").integer ~= 0 then
		numtouchedicts = SVPHYS().SV_EntitiesInBox(clipboxmins, clipboxmaxs, MAX_EDICTS, touchedicts)
	end
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		console.Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	-- iterate the entities found in the sweep box and filter them
	originalnumtouchedicts = numtouchedicts
	numtouchedicts = 0
	for ti = 0, originalnumtouchedicts - 1 do
		touch = touchedicts[ti + 1]
		if getf(prog, touch, "solid") ~= SOLID_BSP then
			continue
		end
		model = sv_main.SV_GetModelFromEdict(touch)
		if not model or not model.brush or not model.brush.TraceLineOfSight then
			continue
		end
		-- skip obviously transparent entities
		alpha = getf(prog, touch, "alpha")
		if alpha ~= 0 and alpha < 1 then
			continue
		end
		if bit32.band(libc.toint(getf(prog, touch, "effects")), EF_ADDITIVE) ~= 0 then
			continue
		end
		touchedicts[numtouchedicts + 1] = touch
		numtouchedicts += 1
	end

	-- now that we have a filtered list of "interesting" entities, fire each
	-- ray against all of them, this gives us an early-out case when something
	-- is visible (which it often is)

	for traceindex = 0, numtraces - 1 do
		-- VectorSet: x, y, z in this order
		start[1] = R(lhrandomf(eyemins[1], eyemaxs[1]))
		start[2] = R(lhrandomf(eyemins[2], eyemaxs[2]))
		start[3] = R(lhrandomf(eyemins[3], eyemaxs[3]))
		local endpoint = endpoints[traceindex + 1]
		-- check world occlusion
		if sv.worldmodel and sv.worldmodel.brush.TraceLineOfSight then
			if not sv.worldmodel.brush.TraceLineOfSight(sv.worldmodel, start, endpoint, boxmins, boxmaxs) then
				continue
			end
		end
		touchindex = 0
		while touchindex < numtouchedicts do
			touch = touchedicts[touchindex + 1]
			model = sv_main.SV_GetModelFromEdict(touch)
			if model and model.brush and model.brush.TraceLineOfSight then
				-- get the entity matrix
				pitchsign = SVPHYS().SV_GetPitchSign(prog, touch)
				matrixlib.Matrix4x4_CreateFromQuakeEntity(
					matrix,
					getvi(prog, touch, "origin", 0),
					getvi(prog, touch, "origin", 1),
					getvi(prog, touch, "origin", 2),
					R(pitchsign * getvi(prog, touch, "angles", 0)),
					getvi(prog, touch, "angles", 1),
					getvi(prog, touch, "angles", 2),
					1
				)
				matrixlib.Matrix4x4_Invert_Simple(imatrix, matrix)
				-- see if the ray hits this entity
				matrixlib.Matrix4x4_Transform(imatrix, start, starttransformed)
				matrixlib.Matrix4x4_Transform(imatrix, endpoint, endtransformed)
				matrixlib.Matrix4x4_Transform(imatrix, boxmins, boxminstransformed)
				matrixlib.Matrix4x4_Transform(imatrix, boxmaxs, boxmaxstransformed)
				-- transform the AABB to local space
				for k = 1, 3 do
					localboxcenter[k] = R(R(0.5 * boxminstransformed[k]) + R(0.5 * boxmaxstransformed[k]))
				end
				for k = 1, 3 do
					localboxextents[k] = math.abs(R(boxmaxstransformed[k] - localboxcenter[k]))
				end
				for k = 1, 3 do
					localboxmins[k] = R(localboxcenter[k] - localboxextents[k])
				end
				for k = 1, 3 do
					localboxmaxs[k] = R(localboxcenter[k] + localboxextents[k])
				end
				if
					not model.brush.TraceLineOfSight(
						model,
						starttransformed,
						endtransformed,
						localboxmins,
						localboxmaxs
					)
				then
					blocked += 1
					break
				end
			end
			touchindex += 1
		end
		-- check if the ray was blocked
		if touchindex < numtouchedicts then
			continue
		end
		-- return if the ray was not blocked
		return true
	end

	-- no rays survived
	return false
end

-- CHECKPVSBIT(pvs,b) (model_shared.h): pvs is a buffer
local function CHECKPVSBIT(pvs: buffer, b: number): boolean
	return b >= 0 and bit32.band(buffer.readu8(pvs, bit32.rshift(b, 3)), bit32.lshift(1, bit32.band(b, 7))) ~= 0
end

-- port: sv_main.c SV_MarkWriteEntityStateToClient L1632-1758 @xonotic-v0.8.6
local function SV_MarkWriteEntityStateToClient(s: any)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local isbmodel
	local model
	local ed
	if (sv.sententitiesconsideration[s.number] or 0) == sv.sententitiesmark then
		return
	end
	sv.sententitiesconsideration[s.number] = sv.sententitiesmark
	sv.writeentitiestoclient_stats_totalentities += 1

	if s.customizeentityforclient ~= 0 then
		SET_GF(prog, "time", sv.time)
		SET_GI(prog, "self", s.number)
		SET_GI(prog, "other", sv.writeentitiestoclient_cliententitynumber)
		prvm_edict.ExecuteProgram(prog, s.customizeentityforclient, "customizeentityforclient: NULL function")
		if
			buffer.readf32(prog.globals, OFS_RETURN * 4) == 0
			or not SV_PrepareEntityForSending(s.number, s, s.number)
		then
			return
		end
	end

	-- never reject player
	if s.number ~= sv.writeentitiestoclient_cliententitynumber then
		-- check various rejection conditions
		if s.nodrawtoclient == sv.writeentitiestoclient_cliententitynumber then
			return
		end
		if s.drawonlytoclient ~= 0 and s.drawonlytoclient ~= sv.writeentitiestoclient_cliententitynumber then
			return
		end
		if bit32.band(s.effects, EF_NODRAW) ~= 0 then
			return
		end
		-- LordHavoc: only send entities with a model or important effects
		if s.modelindex == 0 and s.specialvisibilityradius == 0 then
			return
		end

		model = sv_main.SV_GetModelByIndex(s.modelindex)
		isbmodel = model ~= nil and string.sub(model.name, 1, 1) == "*"
		-- viewmodels don't have visibility checking
		if s.viewmodelforclient ~= 0 then
			if s.viewmodelforclient ~= sv.writeentitiestoclient_cliententitynumber then
				return
			end
		elseif s.tagentity ~= 0 then
			-- tag attached entities simply check their parent
			if not sv.sendentitiesindex[s.tagentity] then
				return
			end
			SV_MarkWriteEntityStateToClient(sv.sendentitiesindex[s.tagentity])
			if (sv.sententities[s.tagentity] or 0) ~= sv.sententitiesmark then
				return
			end
		-- always send world submodels in newer protocols because they don't
		-- generate much traffic (in old protocols they hog bandwidth)
		-- but only if sv_cullentities_nevercullbmodels is off
		elseif
			bit32.band(s.effects, EF_NODEPTHTEST) == 0
			and (
				not isbmodel
				or CV("sv_cullentities_nevercullbmodels").integer == 0
				or sv.protocol == P.QUAKE
				or sv.protocol == P.QUAKEDP
				or sv.protocol == P.NEHAHRAMOVIE
			)
		then
			-- entity has survived every check so far, check if visible
			ed = s.number
			local cullmins, cullmaxs = edcull(prog, ed)

			-- if not touching a visible leaf
			if
				CV("sv_cullentities_pvs").integer ~= 0
				and CV("r_novis").integer == 0
				and r_trippy_integer() == 0
				and sv.writeentitiestoclient_pvsbytes ~= 0
			then
				local numclusters = prog.ed_pvs_numclusters[ed]
				if numclusters < 0 then
					-- entity too big for clusters list
					if
						sv.worldmodel
						and sv.worldmodel.brush.BoxTouchingPVS
						and sv.worldmodel.brush.BoxTouchingPVS(
								sv.worldmodel,
								sv.writeentitiestoclient_pvs,
								0,
								cullmins,
								cullmaxs
							)
							== 0
					then
						sv.writeentitiestoclient_stats_culled_pvs += 1
						return
					end
				else
					local i = 0
					local clusterlist = prog.ed_pvs_clusterlist[ed]
					-- check cached clusters list
					while i < numclusters do
						if CHECKPVSBIT(sv.writeentitiestoclient_pvs, clusterlist[i + 1]) then
							break
						end
						i += 1
					end
					if i == numclusters then
						sv.writeentitiestoclient_stats_culled_pvs += 1
						return
					end
				end
			end

			-- or not seen by random tracelines
			if
				CV("sv_cullentities_trace").integer ~= 0
				and not isbmodel
				and sv.worldmodel
				and sv.worldmodel.brush.TraceLineOfSight
				and r_trippy_integer() == 0
			then
				local samples = if s.number <= svs.maxclients
					then CV("sv_cullentities_trace_samples_players").integer
					elseif s.specialvisibilityradius ~= 0 then CV("sv_cullentities_trace_samples_extra").integer
					else CV("sv_cullentities_trace_samples").integer
				local enlarge = CV("sv_cullentities_trace_enlarge").value

				if samples > 0 then
					local eyeindex = 0
					while eyeindex < sv.writeentitiestoclient_numeyes do
						if
							sv_main.SV_CanSeeBox(
								samples,
								CV("sv_cullentities_trace_eyejitter").value,
								enlarge,
								sv.writeentitiestoclient_eyes[eyeindex + 1],
								cullmins,
								cullmaxs
							)
						then
							break
						end
						eyeindex += 1
					end
					local visibletime = svs.clients[sv.writeentitiestoclient_clientnumber].visibletime
					if eyeindex < sv.writeentitiestoclient_numeyes then
						-- (float visibletime[]: the double sum is stored as float)
						visibletime[s.number] = R(
							prvm_edict.realtime
								+ (
									if s.number <= svs.maxclients
										then CV("sv_cullentities_trace_delay_players").value
										else CV("sv_cullentities_trace_delay").value
								)
						)
					elseif prvm_edict.realtime > (visibletime[s.number] or 0) then
						sv.writeentitiestoclient_stats_culled_trace += 1
						return
					end
				end
			end
		end
	end

	-- this just marks it for sending
	-- FIXME: it would be more efficient to send here, but the entity
	-- compressor isn't that flexible
	sv.writeentitiestoclient_stats_visibleentities += 1
	sv.sententities[s.number] = sv.sententitiesmark
end
sv_main.SV_MarkWriteEntityStateToClient = SV_MarkWriteEntityStateToClient

-- static arrays of SV_AddCameraEyes (C element i at [i + 1])
local addcameraeyes_cameras: { number } = {}
local addcameraeyes_camera_origins: { { number } } = {}
local addcameraeyes_eye_levels: { number } = {}

-- port: sv_main.c SV_AddCameraEyes L1762-1829 @xonotic-v0.8.6 (MAX_LEVELNETWORKEYES is 512: the #if branch)
local function SV_AddCameraEyes()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local i, j, k
	local ed
	local cameras = addcameraeyes_cameras
	local camera_origins = addcameraeyes_camera_origins
	local eye_levels = addcameraeyes_eye_levels
	local n_cameras = 0
	local mi, ma = { 0, 0, 0 }, { 0, 0, 0 }

	for n = 0, sv.writeentitiestoclient_numeyes - 1 do
		eye_levels[n + 1] = 0
	end

	-- check line of sight to portal entities and add them to PVS
	for e = 1, prog.num_edicts - 1 do
		if not prog.ed_free[e] then
			if geti(prog, e, "camera_transform") ~= 0 then
				local eye0 = sv.writeentitiestoclient_eyes[1]
				SET_GF(prog, "time", sv.time)
				SET_GI(prog, "self", e)
				SET_GI(prog, "other", sv.writeentitiestoclient_cliententitynumber)
				SET_GV(prog, "trace_endpos", eye0)
				buffer.writef32(prog.globals, OFS_PARM0 * 4, eye0[1])
				buffer.writef32(prog.globals, OFS_PARM0 * 4 + 4, eye0[2])
				buffer.writef32(prog.globals, OFS_PARM0 * 4 + 8, eye0[3])
				buffer.fill(prog.globals, OFS_PARM1 * 4, 0, 12) -- VectorClear(PRVM_G_VECTOR(OFS_PARM1))
				prvm_edict.ExecuteProgram(
					prog,
					geti(prog, e, "camera_transform"),
					"QC function e.camera_transform is missing"
				)
				local te = prvm_cmds.GlobalOfs(prog, "trace_endpos") * 4
				local tx, ty, tz =
					buffer.readf32(prog.globals, te),
					buffer.readf32(prog.globals, te + 4),
					buffer.readf32(prog.globals, te + 8)
				if not (tx == eye0[1] and ty == eye0[2] and tz == eye0[3]) then
					camera_origins[n_cameras + 1] = { tx, ty, tz }
					cameras[n_cameras + 1] = e
					n_cameras += 1
					if n_cameras >= MAX_LEVELNETWORKEYES then
						break
					end
				end
			end
		end
	end

	if n_cameras == 0 then
		return
	end

	-- i is loop counter, is reset to 0 when an eye got added
	-- j is camera index to check
	i, j = 0, 0
	while sv.writeentitiestoclient_numeyes < MAX_CLIENTNETWORKEYES and i < n_cameras do
		if cameras[j + 1] ~= 0 then
			ed = cameras[j + 1]
			for n = 1, 3 do
				mi[n] = R(getvi(prog, ed, "origin", n - 1) + getvi(prog, ed, "mins", n - 1))
				ma[n] = R(getvi(prog, ed, "origin", n - 1) + getvi(prog, ed, "maxs", n - 1))
			end
			k = 0
			while k < sv.writeentitiestoclient_numeyes do
				if eye_levels[k + 1] <= MAX_EYE_RECURSION then
					if
						sv_main.SV_CanSeeBox(
							CV("sv_cullentities_trace_samples").integer,
							CV("sv_cullentities_trace_eyejitter").value,
							CV("sv_cullentities_trace_enlarge").value,
							sv.writeentitiestoclient_eyes[k + 1],
							mi,
							ma
						)
					then
						local n = sv.writeentitiestoclient_numeyes
						eye_levels[n + 1] = eye_levels[k + 1] + 1
						local dst, src = sv.writeentitiestoclient_eyes[n + 1], camera_origins[j + 1]
						dst[1], dst[2], dst[3] = src[1], src[2], src[3]
						-- Con_Printf("added eye %d: %f %f %f because we can see %f %f %f .. %f %f %f from eye %d\n", ...);
						sv.writeentitiestoclient_numeyes += 1
						cameras[j + 1] = 0
						i = 0
						break
					end
				end
				k += 1
			end
		end
		-- ++i, ++j, j %= n_cameras
		i += 1
		j += 1
		j %= n_cameras
	end
end

-- port support: the state counts of the last SV_WriteEntitiesToClient call (tests print them)
sv_main.writeentities_counts = { numsendstates = 0, numcsqcsendstates = 0 }

-- port: sv_main.c SV_WriteEntitiesToClient L1836-1966 @xonotic-v0.8.6
-- (clent: edict number)
local function SV_WriteEntitiesToClient(c: any, clent: number, msg: any, maxsize: number)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local need_empty = false
	local numsendstates, numcsqcsendstates
	local s
	local camera
	local success
	local eye = { 0, 0, 0 }
	local fn

	-- if there isn't enough space to accomplish anything, skip it
	if msg.cursize + 25 > maxsize then
		return
	end

	sv.writeentitiestoclient_msg = msg
	sv.writeentitiestoclient_clientnumber = clientnumber(c)

	sv.writeentitiestoclient_stats_culled_pvs = 0
	sv.writeentitiestoclient_stats_culled_trace = 0
	sv.writeentitiestoclient_stats_visibleentities = 0
	sv.writeentitiestoclient_stats_totalentities = 0
	sv.writeentitiestoclient_numeyes = 0

	-- get eye location
	sv.writeentitiestoclient_cliententitynumber = clent -- LordHavoc: for comparison purposes
	camera = c.clientcamera -- PRVM_EDICT_NUM(client->clientcamera)
	for k = 1, 3 do
		eye[k] = R(getvi(prog, camera, "origin", k - 1) + getvi(prog, clent, "view_ofs", k - 1))
	end
	sv.writeentitiestoclient_pvsbytes = 0
	-- get the PVS values for the eye location, later FatPVS calls will merge
	local worldmodel = sv.worldmodel
	if worldmodel and worldmodel.brush.FatPVS then
		sv.writeentitiestoclient_pvsbytes = worldmodel.brush.FatPVS(
			worldmodel,
			eye,
			8,
			sv.writeentitiestoclient_pvs,
			MAX_MAP_LEAFS // 8,
			sv.writeentitiestoclient_pvsbytes ~= 0
		)
	elseif worldmodel and worldmodel.brush.GetPVS then
		-- (the C BSP loaders set FatPVS together with GetPVS)
		notPorted("Mod_Q1BSP_FatPVS (model_brush.c, brush.FatPVS) in SV_WriteEntitiesToClient: no PVS culling")
	end

	-- add the eye to a list for SV_CanSeeBox tests
	local eyes = sv.writeentitiestoclient_eyes
	do
		local dst = eyes[sv.writeentitiestoclient_numeyes + 1]
		dst[1], dst[2], dst[3] = eye[1], eye[2], eye[3]
	end
	sv.writeentitiestoclient_numeyes += 1

	-- calculate predicted eye origin for SV_CanSeeBox tests
	if CV("sv_cullentities_trace_prediction").integer ~= 0 then
		-- (engine quirk kept: host_client's ping, not client's; they are the same client here)
		local predtime = bound(0, server.host_client.ping, CV("sv_cullentities_trace_prediction_time").value)
		local predeye = { 0, 0, 0 }
		for k = 1, 3 do -- VectorMA(eye, predtime, PRVM_serveredictvector(camera, velocity), predeye)
			predeye[k] = R(eye[k] + R(predtime * getvi(prog, camera, "velocity", k - 1)))
		end
		if sv_main.SV_CanSeeBox(1, 0, 0, eye, predeye, predeye) then
			local dst = eyes[sv.writeentitiestoclient_numeyes + 1]
			dst[1], dst[2], dst[3] = predeye[1], predeye[2], predeye[3]
			sv.writeentitiestoclient_numeyes += 1
		end
		--if (!sv.writeentitiestoclient_useprediction)
		--	Con_DPrintf("Trying to walk into solid in a pingtime... not predicting for culling\n");
	end

	SV_AddCameraEyes()

	-- build PVS from the new eyes
	if worldmodel and worldmodel.brush.FatPVS then
		for i = 1, sv.writeentitiestoclient_numeyes - 1 do
			sv.writeentitiestoclient_pvsbytes = worldmodel.brush.FatPVS(
				worldmodel,
				eyes[i + 1],
				8,
				sv.writeentitiestoclient_pvs,
				MAX_MAP_LEAFS // 8,
				sv.writeentitiestoclient_pvsbytes ~= 0
			)
		end
	end

	sv.sententitiesmark += 1

	for i = 0, sv.numsendentities - 1 do
		SV_MarkWriteEntityStateToClient(sv.sendentities[i + 1])
	end

	numsendstates = 0
	numcsqcsendstates = 0
	local sendstates, csqcsendstates = sv.writeentitiestoclient_sendstates, sv.writeentitiestoclient_csqcsendstates
	for i = 0, sv.numsendentities - 1 do
		s = sv.sendentities[i + 1]
		if (sv.sententities[s.number] or 0) == sv.sententitiesmark then
			if s.active == ACTIVE_NETWORK then
				if s.exteriormodelforclient ~= 0 then
					if s.exteriormodelforclient == sv.writeentitiestoclient_cliententitynumber then
						s.flags = bit32.bor(s.flags, RENDER_EXTERIORMODEL)
					else
						s.flags = bit32.band(s.flags, bit32.band(bit32.bnot(RENDER_EXTERIORMODEL), 255))
					end
				end
				sendstates[numsendstates + 1] = s
				numsendstates += 1
			elseif s.active == ACTIVE_SHARED then
				csqcsendstates[numcsqcsendstates + 1] = s.number
				numcsqcsendstates += 1
			else
				console.Con_Printf(
					"entity %d is in sv.sendentities and marked, but not active, please breakpoint me\n",
					s.number
				)
			end
		end
	end
	sv_main.writeentities_counts.numsendstates = numsendstates
	sv_main.writeentities_counts.numcsqcsendstates = numcsqcsendstates

	if CV("sv_cullentities_stats").integer ~= 0 then
		console.Con_Printf(
			'client "%s" entities: %d total, %d visible, %d culled by: %d pvs %d trace\n',
			c.name.str,
			sv.writeentitiestoclient_stats_totalentities,
			sv.writeentitiestoclient_stats_visibleentities,
			sv.writeentitiestoclient_stats_culled_pvs + sv.writeentitiestoclient_stats_culled_trace,
			sv.writeentitiestoclient_stats_culled_pvs,
			sv.writeentitiestoclient_stats_culled_trace
		)
	end

	if c.entitydatabase5 then
		fn = PROTOCOL("EntityFrameCSQC_WriteFrame")
		if fn then
			need_empty = fn(msg, maxsize, numcsqcsendstates, csqcsendstates, c.entitydatabase5.latestframenum + 1)
		end
	else
		fn = PROTOCOL("EntityFrameCSQC_WriteFrame")
		if fn then
			fn(msg, maxsize, numcsqcsendstates, csqcsendstates, 0)
		end
	end

	-- force every 16th frame to be not empty (or cl_movement replay takes
	-- too long)
	-- BTW, this should normally not kick in any more due to the check
	-- below, except if the client stopped sending movement frames
	if c.num_skippedentityframes >= 16 then
		need_empty = true
	end

	-- help cl_movement a bit more
	if c.movesequence ~= c.lastmovesequence then
		need_empty = true
	end
	c.lastmovesequence = c.movesequence

	local cnum = clientnumber(c)
	if c.entitydatabase5 then
		fn = PROTOCOL("EntityFrame5_WriteFrame")
		success = if fn
			then fn(msg, maxsize, c.entitydatabase5, numsendstates, sendstates, cnum + 1, c.movesequence, need_empty)
			else false
	elseif c.entitydatabase4 then
		fn = PROTOCOL("EntityFrame4_WriteFrame")
		success = if fn then fn(msg, maxsize, c.entitydatabase4, numsendstates, sendstates) else false
		fn = PROTOCOL("Protocol_WriteStatsReliable")
		if fn then
			fn()
		end
	elseif c.entitydatabase then
		fn = PROTOCOL("EntityFrame_WriteFrame")
		success = if fn then fn(msg, maxsize, c.entitydatabase, numsendstates, sendstates, cnum + 1) else false
		fn = PROTOCOL("Protocol_WriteStatsReliable")
		if fn then
			fn()
		end
	else
		fn = PROTOCOL("EntityFrameQuake_WriteFrame")
		success = if fn then fn(msg, maxsize, numsendstates, sendstates) else false
		fn = PROTOCOL("Protocol_WriteStatsReliable")
		if fn then
			fn()
		end
	end

	if success then
		c.num_skippedentityframes = 0
	else
		c.num_skippedentityframes += 1
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

-- sv_user.c SV_SetIdealPitch is not ported (engine/sv_user.luau)
local function SV_SetIdealPitch()
	notPorted("SV_SetIdealPitch (sv_user.c L35-99) in SV_WriteClientdataToMessage")
end

--[[
==================
SV_WriteClientdataToMessage

==================
]]
-- port: sv_main.c SV_WriteClientdataToMessage L1991-2264 @xonotic-v0.8.6
-- (ent: edict number; stats: int stats[MAX_CL_STATS] as a 0-based table of ints, the representation of
-- engine/protocol.luau; statsf[i] = v stores the int with the bits of the float; gamemode is GAME_XONOTIC: not
-- hipnotic / rogue / quoth / old Nexuiz)
function sv_main.SV_WriteClientdataToMessage(c: any, ent: number, msg: any, stats: { [number]: number })
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local host_client = server.host_client
	local bits
	local other
	local items
	local punchvector = { 0, 0, 0 }
	local viewzoom
	local s
	local gravity
	local function SETSTAT(i: number, v: number) -- stats[i] = (int)v
		stats[i] = v
	end
	local function SETSTATF(i: number, v: number) -- statsf[i] = v
		stats[i] = floatbits(v)
	end
	local function STAT(i: number): number
		return stats[i]
	end

	--
	-- send a damage message
	--
	if getf(prog, ent, "dmg_take") ~= 0 or getf(prog, ent, "dmg_save") ~= 0 then
		other = geti(prog, ent, "dmg_inflictor") -- PRVM_PROG_TO_EDICT
		common.MSG_WriteByte(msg, svc_damage)
		common.MSG_WriteByte(msg, libc.toint(getf(prog, ent, "dmg_save")))
		common.MSG_WriteByte(msg, libc.toint(getf(prog, ent, "dmg_take")))
		for i = 0, 2 do
			-- float + 0.5 * (float sum) in double, passed as the float parameter
			common.MSG_WriteCoord(
				msg,
				R(
					getvi(prog, other, "origin", i)
						+ 0.5 * R(getvi(prog, other, "mins", i) + getvi(prog, other, "maxs", i))
				),
				sv.protocol
			)
		end

		setf(prog, ent, "dmg_take", 0)
		setf(prog, ent, "dmg_save", 0)
	end

	--
	-- send the current viewpos offset from the view entity
	--
	SV_SetIdealPitch() -- how much to look up / down ideally

	-- a fixangle might get lost in a dropped packet.  Oh well.
	if getf(prog, ent, "fixangle") ~= 0 then
		-- angle fixing was requested by global thinking code...
		-- so store the current angles for later use
		for i = 1, 3 do
			host_client.fixangle_angles[i] = getvi(prog, ent, "angles", i - 1)
		end
		host_client.fixangle_angles_set = true

		-- and clear fixangle for the next frame
		setf(prog, ent, "fixangle", 0)
	end

	if host_client.fixangle_angles_set then
		common.MSG_WriteByte(msg, svc_setangle)
		for i = 1, 3 do
			common.MSG_WriteAngle(msg, host_client.fixangle_angles[i], sv.protocol)
		end
		host_client.fixangle_angles_set = false
	end

	-- the runes are in serverflags, pack them into the items value, also pack
	-- in the items2 value for mission pack huds
	-- (used only in the mission packs, which do not use serverflags)
	items = toint32(
		bit32.bor(
			libc.toint(getf(prog, ent, "items")),
			bit32.lshift(libc.toint(getf(prog, ent, "items2")), 23),
			bit32.lshift(libc.toint(GF(prog, "serverflags")), 28)
		)
	)

	for i = 1, 3 do
		punchvector[i] = getvi(prog, ent, "punchvector", i - 1)
	end

	-- cache weapon model name and index in client struct to save time
	-- (this search can be almost 1% of cpu time!)
	s = libc.cstr(prvm_edict.PRVM_GetString(prog, geti(prog, ent, "weaponmodel")))
	if s ~= c.weaponmodel then
		c.weaponmodel = string.sub(s, 1, server.MAX_QPATH - 1)
		c.weaponmodelindex = sv_main.SV_ModelIndex(s, 1)
	end

	viewzoom = libc.toint(R(getf(prog, ent, "viewzoom") * 255.0))
	if viewzoom == 0 then
		viewzoom = 255
	end

	bits = 0

	if bit32.band(libc.toint(getf(prog, ent, "flags")), FL_ONGROUND) ~= 0 then
		bits = bit32.bor(bits, SU_ONGROUND)
	end
	if getf(prog, ent, "waterlevel") >= 2 then
		bits = bit32.bor(bits, SU_INWATER)
	end
	if getf(prog, ent, "idealpitch") ~= 0 then
		bits = bit32.bor(bits, SU_IDEALPITCH)
	end

	for i = 0, 2 do
		if getvi(prog, ent, "punchangle", i) ~= 0 then
			bits = bit32.bor(bits, bit32.lshift(SU_PUNCH1, i))
		end
		if not oldprotocol(sv.protocol) then
			if punchvector[i + 1] ~= 0 then
				bits = bit32.bor(bits, bit32.lshift(SU_PUNCHVEC1, i))
			end
		end
		if getvi(prog, ent, "velocity", i) ~= 0 then
			bits = bit32.bor(bits, bit32.lshift(SU_VELOCITY1, i))
		end
	end

	gravity = getf(prog, ent, "gravity")
	if gravity == 0 then
		gravity = 1.0
	end

	for i = 0, MAX_CL_STATS - 1 do -- memset(stats, 0, sizeof(int[MAX_CL_STATS]))
		stats[i] = 0
	end
	SETSTAT(STAT_VIEWHEIGHT, libc.toint(getvi(prog, ent, "view_ofs", 2)))
	SETSTAT(STAT_ITEMS, items)
	SETSTAT(STAT_WEAPONFRAME, libc.toint(getf(prog, ent, "weaponframe")))
	SETSTAT(STAT_ARMOR, libc.toint(getf(prog, ent, "armorvalue")))
	SETSTAT(STAT_WEAPON, c.weaponmodelindex)
	SETSTAT(STAT_HEALTH, libc.toint(getf(prog, ent, "health")))
	SETSTAT(STAT_AMMO, libc.toint(getf(prog, ent, "currentammo")))
	SETSTAT(STAT_SHELLS, libc.toint(getf(prog, ent, "ammo_shells")))
	SETSTAT(STAT_NAILS, libc.toint(getf(prog, ent, "ammo_nails")))
	SETSTAT(STAT_ROCKETS, libc.toint(getf(prog, ent, "ammo_rockets")))
	SETSTAT(STAT_CELLS, libc.toint(getf(prog, ent, "ammo_cells")))
	SETSTAT(STAT_ACTIVEWEAPON, libc.toint(getf(prog, ent, "weapon")))
	SETSTAT(STAT_VIEWZOOM, viewzoom)
	SETSTAT(STAT_TOTALSECRETS, libc.toint(GF(prog, "total_secrets")))
	SETSTAT(STAT_TOTALMONSTERS, libc.toint(GF(prog, "total_monsters")))
	-- the QC bumps these itself by sending svc_'s, so we have to keep them
	-- zero or they'll be corrected by the engine
	--stats[STAT_SECRETS] = PRVM_serverglobalfloat(found_secrets);
	--stats[STAT_MONSTERS] = PRVM_serverglobalfloat(killed_monsters);

	-- movement settings for prediction
	-- note: these are not sent in protocols with lower MAX_CL_STATS limits
	SETSTAT(
		STAT_MOVEFLAGS,
		toint32(
			bit32.bor(
				MOVEFLAG_VALID,
				if CV("sv_gameplayfix_q2airaccelerate").integer ~= 0 then MOVEFLAG_Q2AIRACCELERATE else 0,
				if CV("sv_gameplayfix_nogravityonground").integer ~= 0 then MOVEFLAG_NOGRAVITYONGROUND else 0,
				if CV("sv_gameplayfix_gravityunaffectedbyticrate").integer ~= 0
					then MOVEFLAG_GRAVITYUNAFFECTEDBYTICRATE
					else 0
			)
		)
	)
	SETSTATF(STAT_MOVEVARS_TICRATE, CV("sys_ticrate").value)
	SETSTATF(STAT_MOVEVARS_TIMESCALE, CV("slowmo").value)
	SETSTATF(STAT_MOVEVARS_GRAVITY, CV("sv_gravity").value)
	SETSTATF(STAT_MOVEVARS_STOPSPEED, CV("sv_stopspeed").value)
	SETSTATF(STAT_MOVEVARS_MAXSPEED, CV("sv_maxspeed").value)
	SETSTATF(STAT_MOVEVARS_SPECTATORMAXSPEED, CV("sv_maxspeed").value) -- FIXME: QW has a separate cvar for this
	SETSTATF(STAT_MOVEVARS_ACCELERATE, CV("sv_accelerate").value)
	SETSTATF(
		STAT_MOVEVARS_AIRACCELERATE,
		if CV("sv_airaccelerate").value >= 0 then CV("sv_airaccelerate").value else CV("sv_accelerate").value
	)
	SETSTATF(
		STAT_MOVEVARS_WATERACCELERATE,
		if CV("sv_wateraccelerate").value >= 0 then CV("sv_wateraccelerate").value else CV("sv_accelerate").value
	)
	SETSTATF(STAT_MOVEVARS_ENTGRAVITY, gravity)
	SETSTATF(STAT_MOVEVARS_JUMPVELOCITY, CV("sv_jumpvelocity").value)
	SETSTATF(STAT_MOVEVARS_EDGEFRICTION, CV("sv_edgefriction").value)
	SETSTATF(STAT_MOVEVARS_MAXAIRSPEED, CV("sv_maxairspeed").value)
	SETSTATF(STAT_MOVEVARS_STEPHEIGHT, CV("sv_stepheight").value)
	SETSTATF(STAT_MOVEVARS_AIRACCEL_QW, CV("sv_airaccel_qw").value)
	SETSTATF(STAT_MOVEVARS_AIRACCEL_QW_STRETCHFACTOR, CV("sv_airaccel_qw_stretchfactor").value)
	SETSTATF(STAT_MOVEVARS_AIRACCEL_SIDEWAYS_FRICTION, CV("sv_airaccel_sideways_friction").value)
	SETSTATF(STAT_MOVEVARS_FRICTION, CV("sv_friction").value)
	SETSTATF(
		STAT_MOVEVARS_WATERFRICTION,
		if CV("sv_waterfriction").value >= 0 then CV("sv_waterfriction").value else CV("sv_friction").value
	)
	SETSTATF(STAT_MOVEVARS_AIRSTOPACCELERATE, CV("sv_airstopaccelerate").value)
	SETSTATF(STAT_MOVEVARS_AIRSTRAFEACCELERATE, CV("sv_airstrafeaccelerate").value)
	SETSTATF(STAT_MOVEVARS_MAXAIRSTRAFESPEED, CV("sv_maxairstrafespeed").value)
	SETSTATF(STAT_MOVEVARS_AIRSTRAFEACCEL_QW, CV("sv_airstrafeaccel_qw").value)
	SETSTATF(STAT_MOVEVARS_AIRCONTROL, CV("sv_aircontrol").value)
	SETSTATF(STAT_MOVEVARS_AIRCONTROL_POWER, CV("sv_aircontrol_power").value)
	SETSTATF(STAT_MOVEVARS_AIRCONTROL_PENALTY, CV("sv_aircontrol_penalty").value)
	SETSTATF(STAT_MOVEVARS_WARSOWBUNNY_AIRFORWARDACCEL, CV("sv_warsowbunny_airforwardaccel").value)
	SETSTATF(STAT_MOVEVARS_WARSOWBUNNY_ACCEL, CV("sv_warsowbunny_accel").value)
	SETSTATF(STAT_MOVEVARS_WARSOWBUNNY_TOPSPEED, CV("sv_warsowbunny_topspeed").value)
	SETSTATF(STAT_MOVEVARS_WARSOWBUNNY_TURNACCEL, CV("sv_warsowbunny_turnaccel").value)
	SETSTATF(STAT_MOVEVARS_WARSOWBUNNY_BACKTOSIDERATIO, CV("sv_warsowbunny_backtosideratio").value)
	SETSTATF(STAT_MOVEVARS_AIRSPEEDLIMIT_NONQW, CV("sv_airspeedlimit_nonqw").value)
	SETSTATF(STAT_FRAGLIMIT, CV("fraglimit").value)
	SETSTATF(STAT_TIMELIMIT, CV("timelimit").value)

	if
		oldprotocol(sv.protocol)
		or sv.protocol == P.DARKPLACES1
		or sv.protocol == P.DARKPLACES2
		or sv.protocol == P.DARKPLACES3
		or sv.protocol == P.DARKPLACES4
		or sv.protocol == P.DARKPLACES5
	then
		if STAT(STAT_VIEWHEIGHT) ~= DEFAULT_VIEWHEIGHT then
			bits = bit32.bor(bits, SU_VIEWHEIGHT)
		end
		bits = bit32.bor(bits, SU_ITEMS)
		if STAT(STAT_WEAPONFRAME) ~= 0 then
			bits = bit32.bor(bits, SU_WEAPONFRAME)
		end
		if STAT(STAT_ARMOR) ~= 0 then
			bits = bit32.bor(bits, SU_ARMOR)
		end
		bits = bit32.bor(bits, SU_WEAPON)
		-- FIXME: which protocols support this?  does PROTOCOL_DARKPLACES3 support viewzoom?
		if
			sv.protocol == P.DARKPLACES2
			or sv.protocol == P.DARKPLACES3
			or sv.protocol == P.DARKPLACES4
			or sv.protocol == P.DARKPLACES5
		then
			if viewzoom ~= 255 then
				bits = bit32.bor(bits, SU_VIEWZOOM)
			end
		end
	end

	if bits >= 65536 then
		bits = bit32.bor(bits, SU_EXTEND1)
	end
	if bits >= 16777216 then
		bits = bit32.bor(bits, SU_EXTEND2)
	end

	-- send the data
	common.MSG_WriteByte(msg, svc_clientdata)
	common.MSG_WriteShort(msg, bits)
	if bit32.band(bits, SU_EXTEND1) ~= 0 then
		common.MSG_WriteByte(msg, bit32.rshift(bits, 16))
	end
	if bit32.band(bits, SU_EXTEND2) ~= 0 then
		common.MSG_WriteByte(msg, bit32.rshift(bits, 24))
	end

	if bit32.band(bits, SU_VIEWHEIGHT) ~= 0 then
		common.MSG_WriteChar(msg, STAT(STAT_VIEWHEIGHT))
	end

	if bit32.band(bits, SU_IDEALPITCH) ~= 0 then
		common.MSG_WriteChar(msg, libc.toint(getf(prog, ent, "idealpitch")))
	end

	for i = 0, 2 do
		if bit32.band(bits, bit32.lshift(SU_PUNCH1, i)) ~= 0 then
			if oldprotocol(sv.protocol) then
				common.MSG_WriteChar(msg, libc.toint(getvi(prog, ent, "punchangle", i)))
			else
				common.MSG_WriteAngle16i(msg, getvi(prog, ent, "punchangle", i))
			end
		end
		if bit32.band(bits, bit32.lshift(SU_PUNCHVEC1, i)) ~= 0 then
			if
				sv.protocol == P.DARKPLACES1
				or sv.protocol == P.DARKPLACES2
				or sv.protocol == P.DARKPLACES3
				or sv.protocol == P.DARKPLACES4
			then
				common.MSG_WriteCoord16i(msg, punchvector[i + 1])
			else
				common.MSG_WriteCoord32f(msg, punchvector[i + 1])
			end
		end
		if bit32.band(bits, bit32.lshift(SU_VELOCITY1, i)) ~= 0 then
			if
				oldprotocol(sv.protocol)
				or sv.protocol == P.DARKPLACES1
				or sv.protocol == P.DARKPLACES2
				or sv.protocol == P.DARKPLACES3
				or sv.protocol == P.DARKPLACES4
			then
				common.MSG_WriteChar(msg, libc.toint(R(getvi(prog, ent, "velocity", i) * (1.0 / 16.0))))
			else
				common.MSG_WriteCoord32f(msg, getvi(prog, ent, "velocity", i))
			end
		end
	end

	if bit32.band(bits, SU_ITEMS) ~= 0 then
		common.MSG_WriteLong(msg, STAT(STAT_ITEMS))
	end

	if sv.protocol == P.DARKPLACES5 then
		if bit32.band(bits, SU_WEAPONFRAME) ~= 0 then
			common.MSG_WriteShort(msg, STAT(STAT_WEAPONFRAME))
		end
		if bit32.band(bits, SU_ARMOR) ~= 0 then
			common.MSG_WriteShort(msg, STAT(STAT_ARMOR))
		end
		if bit32.band(bits, SU_WEAPON) ~= 0 then
			common.MSG_WriteShort(msg, STAT(STAT_WEAPON))
		end
		common.MSG_WriteShort(msg, STAT(STAT_HEALTH))
		common.MSG_WriteShort(msg, STAT(STAT_AMMO))
		common.MSG_WriteShort(msg, STAT(STAT_SHELLS))
		common.MSG_WriteShort(msg, STAT(STAT_NAILS))
		common.MSG_WriteShort(msg, STAT(STAT_ROCKETS))
		common.MSG_WriteShort(msg, STAT(STAT_CELLS))
		common.MSG_WriteShort(msg, STAT(STAT_ACTIVEWEAPON))
		if bit32.band(bits, SU_VIEWZOOM) ~= 0 then
			common.MSG_WriteShort(msg, bound(0, STAT(STAT_VIEWZOOM), 65535))
		end
	elseif
		oldprotocol(sv.protocol)
		or sv.protocol == P.DARKPLACES1
		or sv.protocol == P.DARKPLACES2
		or sv.protocol == P.DARKPLACES3
		or sv.protocol == P.DARKPLACES4
	then
		if bit32.band(bits, SU_WEAPONFRAME) ~= 0 then
			common.MSG_WriteByte(msg, STAT(STAT_WEAPONFRAME))
		end
		if bit32.band(bits, SU_ARMOR) ~= 0 then
			common.MSG_WriteByte(msg, STAT(STAT_ARMOR))
		end
		if bit32.band(bits, SU_WEAPON) ~= 0 then
			if sv.protocol == P.NEHAHRABJP or sv.protocol == P.NEHAHRABJP2 or sv.protocol == P.NEHAHRABJP3 then
				common.MSG_WriteShort(msg, STAT(STAT_WEAPON))
			else
				common.MSG_WriteByte(msg, STAT(STAT_WEAPON))
			end
		end
		common.MSG_WriteShort(msg, STAT(STAT_HEALTH))
		common.MSG_WriteByte(msg, STAT(STAT_AMMO))
		common.MSG_WriteByte(msg, STAT(STAT_SHELLS))
		common.MSG_WriteByte(msg, STAT(STAT_NAILS))
		common.MSG_WriteByte(msg, STAT(STAT_ROCKETS))
		common.MSG_WriteByte(msg, STAT(STAT_CELLS))
		-- (gamemode == GAME_HIPNOTIC || GAME_ROGUE || GAME_QUOTH || IS_OLDNEXUIZ_DERIVED: the bit index of the
		-- active weapon; not for GAME_XONOTIC)
		common.MSG_WriteByte(msg, STAT(STAT_ACTIVEWEAPON))
		if bit32.band(bits, SU_VIEWZOOM) ~= 0 then
			if sv.protocol == P.DARKPLACES2 or sv.protocol == P.DARKPLACES3 or sv.protocol == P.DARKPLACES4 then
				common.MSG_WriteByte(msg, bound(0, STAT(STAT_VIEWZOOM), 255))
			else
				common.MSG_WriteShort(msg, bound(0, STAT(STAT_VIEWZOOM), 65535))
			end
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

-- port: sv_main.c SV_WriteUnreliableMessages L2282-2313 @xonotic-v0.8.6
local function SV_WriteUnreliableMessages(c: any, msg: any, maxsize: number, maxsize2: number)
	-- scan the splitpoints to find out how many we can fit in
	local numsegments, split
	local splitpoint = c.unreliablemsg_splitpoint
	if c.unreliablemsg_splitpoints == 0 then
		return
	end
	-- always accept the first one if it's within 1024 bytes, this ensures
	-- that very big datagrams which are over the rate limit still get
	-- through, just to keep it working
	numsegments = 1
	while numsegments < c.unreliablemsg_splitpoints do
		if msg.cursize + splitpoint[numsegments] > maxsize then
			break
		end
		numsegments += 1
	end
	-- the first segment gets an exemption from the rate limiting, otherwise
	-- it could get dropped consistently due to a low rate limit
	if numsegments == 1 then
		maxsize = maxsize2
	end
	-- some will fit, so add the ones that will fit
	split = splitpoint[numsegments - 1]
	-- note this discards ones that were accepted by the segments scan but
	-- can not fit, such as a really huge first one that will never ever
	-- fit in a packet...
	if msg.cursize + split <= maxsize then
		common.SZ_Write(msg, buffer.readstring(c.unreliablemsg.data, 0, split))
	end
	-- remove the part we sent, keeping any remaining data
	c.unreliablemsg.cursize -= split
	if c.unreliablemsg.cursize > 0 then
		buffer.copy(c.unreliablemsg.data, 0, c.unreliablemsg.data, split, c.unreliablemsg.cursize)
	end
	-- adjust remaining splitpoints
	c.unreliablemsg_splitpoints -= numsegments
	for j = 0, c.unreliablemsg_splitpoints - 1 do
		splitpoint[j] = splitpoint[numsegments + j] - split
	end
end

-- static unsigned char sv_sendclientdatagram_buf[NET_MAXMESSAGE] and the int stats[MAX_CL_STATS] of
-- SV_SendClientDatagram
local sv_sendclientdatagram_buf = buffer.create(NET_MAXMESSAGE)
local sv_sendclientdatagram_stats: { [number]: number } = {} -- (0-based; filled by SV_WriteClientdataToMessage)

--[[
=======================
SV_SendClientDatagram
=======================
]]
-- port: sv_main.c SV_SendClientDatagram L2320-2484 @xonotic-v0.8.6
local function SV_SendClientDatagram(c: any)
	local sv = server.sv :: any
	local host_client = server.host_client
	local realtime = prvm_edict.realtime
	local clientrate, maxrate, maxsize, maxsize2, downloadsize
	local msg
	local stats = sv_sendclientdatagram_stats
	local timedelta

	-- obey rate limit by limiting packet frequency if the packet size
	-- limiting fails
	-- (usually this is caused by reliable messages)
	if not NetConn_CanSend(c.netconnection) then
		return
	end

	-- PROTOCOL_DARKPLACES5 and later support packet size limiting of updates
	local sv_maxrate = CV("sv_maxrate")
	maxrate = cmax(NET_MINRATE, sv_maxrate.integer)
	if sv_maxrate.integer ~= maxrate then
		cvar.Cvar_SetValueQuick(sv_maxrate, maxrate)
	end

	-- clientrate determines the 'cleartime' of a packet
	-- (how long to wait before sending another, based on this packet's size)
	clientrate = bound(NET_MINRATE, c.rate, maxrate)

	local protocol = sv.protocol
	if oldprotocol(protocol) or protocol == P.QUAKEWORLD then
		-- no packet size limit support on Quake protocols because it just
		-- causes missing entities/effects
		-- packets are simply sent less often to obey the rate limit
		maxsize = 1024
		maxsize2 = 1024
	elseif
		protocol == P.DARKPLACES1
		or protocol == P.DARKPLACES2
		or protocol == P.DARKPLACES3
		or protocol == P.DARKPLACES4
	then
		-- no packet size limit support on DP1-4 protocols because they kick
		-- the client off if they overflow, and miss effects
		-- packets are simply sent less often to obey the rate limit
		maxsize = NET_MAXMESSAGE
		maxsize2 = NET_MAXMESSAGE
	else
		-- DP5 and later protocols support packet size limiting which is a
		-- better method than limiting packet frequency as QW does
		--
		-- at very low rates (or very small sys_ticrate) the packet size is
		-- not reduced below 128, but packets may be sent less often

		-- how long are bursts?
		timedelta = host_client.rate_burstsize / c.rate

		-- how much of the burst do we keep reserved?
		timedelta *= R(1 - CV("net_burstreserve").value)

		-- only try to use excess time
		timedelta = bound(0, realtime - host_client.netconnection.cleartime, timedelta)

		-- but we know next packet will be in sys_ticrate, so we can use up THAT bandwidth
		timedelta += CV("sys_ticrate").value

		-- note: packet overhead (not counted in maxsize) is 28 bytes
		maxsize = libc.toint(clientrate * timedelta) - 28

		-- put it in sound bounds
		maxsize = bound(128, maxsize, 1400)
		maxsize2 = 1400

		-- csqc entities can easily exceed 128 bytes, so disable throttling in
		-- mods that use csqc (they are likely to use less bandwidth anyway)
		local usesizelimit = CV("net_usesizelimit").integer
		if if usesizelimit == 1 then sv.csqc_progsize > 0 else usesizelimit < 1 then
			maxsize = maxsize2
		end
	end

	if
		LHNETADDRESS_GetAddressType(host_client.netconnection.peeraddress) == LHNETADDRESSTYPE_LOOP
		and CV("sv_ratelimitlocalplayer").integer == 0
	then
		-- for good singleplayer, send huge packets
		maxsize = NET_MAXMESSAGE
		maxsize2 = NET_MAXMESSAGE
		-- never limit frequency in singleplayer
		clientrate = 1000000000
	end

	-- while downloading, limit entity updates to half the packet
	-- (any leftover space will be used for downloading)
	if host_client.download_file then
		maxsize = libc.toint(maxsize / 2)
	end

	msg = {
		data = sv_sendclientdatagram_buf,
		maxsize = NET_MAXMESSAGE,
		cursize = 0,
		allowoverflow = false,
		overflowed = false,
	}

	if host_client.begun then
		-- the player is in the game
		common.MSG_WriteByte(msg, svc_time)
		common.MSG_WriteFloat(msg, sv.time)

		-- add the client specific data to the datagram
		sv_main.SV_WriteClientdataToMessage(c, c.edict, msg, stats)
		-- now update the stats[] array using any registered custom fields
		notPorted("VM_SV_UpdateCustomStats (svvm_cmds.c L1646-1688) in SV_SendClientDatagram")
		-- set host_client->statsdeltabits
		local f = PROTOCOL("Protocol_UpdateClientStats")
		if f then
			f(stats)
		end

		-- add as many queued unreliable messages (effects) as we can fit
		-- limit effects to half of the remaining space
		if c.unreliablemsg.cursize ~= 0 then
			SV_WriteUnreliableMessages(c, msg, libc.toint(maxsize / 2), maxsize2)
		end

		-- now write as many entities as we can fit, and also sends stats
		SV_WriteEntitiesToClient(c, c.edict, msg, maxsize)
	elseif realtime > c.keepalivetime then
		-- the player isn't totally in the game yet
		-- send small keepalive messages if too much time has passed
		-- (may also be sending downloads)
		c.keepalivetime = realtime + 5
		common.MSG_WriteChar(msg, svc_nop)
	end

	-- if a download is active, see if there is room to fit some download data
	-- in this packet
	downloadsize = cmin(maxsize * 2, maxsize2) - msg.cursize - 7
	if host_client.download_file and host_client.download_started and downloadsize > 0 then
		-- (FS_Tell / FS_Read of the download file, then svc_downloaddata [long] start [short] size [data])
		notPorted(
			"download data (svc_downloaddata " .. svc_downloaddata .. ", FS_Tell / FS_Read) in SV_SendClientDatagram"
		)
	end

	-- reliable only if none is in progress
	if c.sendsignon ~= 2 and (c.netconnection.sendMessageLength or 0) == 0 then
		SV_WriteDemoMessage(c, c.netconnection.message, false)
	end
	-- unreliable
	SV_WriteDemoMessage(c, msg, false)

	-- send the datagram
	NetConn_SendUnreliableMessage(c.netconnection, msg, sv.protocol, clientrate, c.rate_burstsize, c.sendsignon == 2)
	if c.sendsignon == 1 and c.netconnection.message.cursize == 0 then
		c.sendsignon = 2 -- prevent reliable until client sends prespawn (this is the keepalive phase)
	end
end
sv_main.SV_SendClientDatagram = SV_SendClientDatagram

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
			SV_PrepareEntitiesForSending()
		end
		SV_SendClientDatagram(host_client)
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
SV_Prepare_CSQC

Load csprogs.dat and comperss it so it doesn't need to be
reloaded on request.
================
]]
-- port: sv_main.c SV_Prepare_CSQC L3194-3233 @xonotic-v0.8.6
-- (svs.csqc_progdata: the file as a string, nil = NULL)
function sv_main.SV_Prepare_CSQC()
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local progsize

	if svs.csqc_progdata then
		console.Con_DPrintf("Unloading old CSQC data.\n")
		-- Mem_Free(svs.csqc_progdata); Mem_Free(svs.csqc_progdata_deflated)
	end

	svs.csqc_progdata = nil
	svs.csqc_progdata_deflated = nil

	sv.csqc_progname = ""
	local csqc_progname = CV("csqc_progname").string.str
	svs.csqc_progdata = fs.FS_LoadFile(csqc_progname, false)
	progsize = if svs.csqc_progdata then #svs.csqc_progdata else 0

	if progsize > 0 then
		sv.csqc_progsize = progsize
		sv.csqc_progcrc = common.CRC_Block(svs.csqc_progdata)
		sv.csqc_progname = string.sub(csqc_progname, 1, server.MAX_QPATH - 1)
		console.Con_DPrintf(
			'server detected csqc progs file "%s" with size %i and crc %i\n',
			sv.csqc_progname,
			sv.csqc_progsize,
			sv.csqc_progcrc
		)

		console.Con_DPrint("Compressing csprogs.dat\n")
		--unsigned char *FS_Deflate(const unsigned char *data, size_t size, size_t *deflated_size, int level, mempool_t *mempool);
		notPorted(
			"FS_Deflate (fs.c, zlib) in SV_Prepare_CSQC: svs.csqc_progdata_deflated stays NULL (only downloads use it)"
		)
		svs.csqc_progdata_deflated = nil
		svs.csqc_progsize_deflated = 0
	end
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
