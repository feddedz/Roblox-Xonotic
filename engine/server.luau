--!strict
--[[
	DarkPlaces server.h (server_t sv), GPLv2 or later (see engine/cvar.luau).
]]
--[[
	The server state the ported builtins read and write. PARTIAL: precache lists, light styles, datagram,
	signon and reliable datagram buffers, custom stats, time/state/paused/protocol, the level names, world (the
	area grid), worldmodel and models. Filled by SV_SpawnServer (sv_main.c) — before the first one sv.protocol
	keeps the value sv_protocolname "DP7" (the Xonotic default) selects.
	Strings of char arrays are Luau strings (truncated to the array size - 1 by the writer, as strlcpy does).
	sv.models is `dp_model_t *models[MAX_MODELS]`: C element i at [i] (nil = NULL), like the precache lists.
	The client sending state (csqc_prog*, writeentitiestoclient_*, sendentities, sententities, ...) is used by
	engine/sv_main.luau (SV_SendClientMessages).
	NOT YET PORTED: the rest of server_t (flood address lists, ...), added with their users.
]]
local common = require("./common")
local world = require("./world")

local server = {}

server.MAX_MODELS = 8192 -- quakedef.h L140
server.MAX_SOUNDS = 4096 -- quakedef.h L141
server.MAX_LIGHTSTYLES = 256 -- quakedef.h L142
server.MAX_QPATH = 128 -- quakedef.h L205
server.MAX_CL_STATS = 256 -- quakedef.h L221
server.NET_MAXMESSAGE = 65536 -- quakedef.h L137
server.ss_dead, server.ss_loading, server.ss_active = 0, 1, 2 -- server_state_t (server.h)

export type Server = {
	active: boolean,
	state: number,
	paused: boolean, -- server.h L82
	pausedstart: number, -- double pausedstart (server.h L83)
	time: number,
	frametime: number, -- double frametime (server.h L92)
	protocol: number,
	name: string, -- char name[64] (server.h L107)
	worldmessage: string, -- char worldmessage[40] (server.h L109)
	worldbasename: string, -- char [MAX_QPATH] (server.h L110)
	worldname: string, -- char [MAX_QPATH] (server.h L111)
	worldnamenoextension: string, -- char [MAX_QPATH] (server.h L112)
	model_precache: { [number]: string },
	sound_precache: { [number]: string },
	lightstyles: { [number]: string },
	datagram: common.SizeBuf, -- server.h L127-128
	signon: common.SizeBuf,
	reliable_datagram: common.SizeBuf,
	world: world.world_t, -- collision culling data
	worldmodel: any, -- dp_model_t * (nil = NULL)
	models: { [number]: any }, -- dp_model_t *models[MAX_MODELS], C index i at [i]
	writeentitiestoclient_msg: common.SizeBuf?, -- sizebuf_t * of the entity message being built (server.h L153; nil = NULL)
	particleeffectnamesloaded: boolean, -- qboolean (server.h L144)
	particleeffectname: { [number]: string }, -- char [MAX_PARTICLEEFFECTNAME][MAX_QPATH] (server.h L145), C index i at [i]
	loadgame: boolean, -- qboolean loadgame (server.h L85): client spawn parms come from a saved game
	-- port support: the address of a char array of this struct as an engine string reference (see CStrRef)
	stringrefs: { [string]: { str: string } },
	-- the client sending state of sv_main.c (server.h L97-100, L146-173). Arrays indexed by an entity number
	-- (sendentitiesindex, sententities, sententitiesconsideration, csqcentityversion) hold entity e at [e]
	-- (nil = 0 / NULL, like the prog.ed_* tables); the other arrays hold C element i at [i + 1].
	csqc_progcrc: number, -- int csqc_progcrc (server.h L98)
	csqc_progsize: number, -- int csqc_progsize (server.h L99)
	csqc_progname: string, -- char csqc_progname[MAX_QPATH] (server.h L100)
	writeentitiestoclient_stats_culled_pvs: number,
	writeentitiestoclient_stats_culled_trace: number,
	writeentitiestoclient_stats_visibleentities: number,
	writeentitiestoclient_stats_totalentities: number,
	writeentitiestoclient_cliententitynumber: number,
	writeentitiestoclient_clientnumber: number,
	writeentitiestoclient_eyes: { { number } }, -- vec3_t [MAX_CLIENTNETWORKEYES]
	writeentitiestoclient_numeyes: number,
	writeentitiestoclient_pvsbytes: number,
	writeentitiestoclient_pvs: buffer, -- unsigned char [MAX_MAP_LEAFS/8]
	writeentitiestoclient_sendstates: { any }, -- const entity_state_t *[MAX_EDICTS]
	writeentitiestoclient_csqcsendstates: { number }, -- unsigned short [MAX_EDICTS]
	numsendentities: number,
	sendentities: { any }, -- entity_state_t [MAX_EDICTS] (tables created on first use, reused)
	sendentitiesindex: { [number]: any }, -- entity_state_t *[MAX_EDICTS], entity e at [e]
	sententitiesmark: number,
	sententities: { [number]: number }, -- int [MAX_EDICTS], entity e at [e]
	sententitiesconsideration: { [number]: number }, -- int [MAX_EDICTS], entity e at [e]
	csqcentityversion: { [number]: number }, -- unsigned char [MAX_EDICTS], entity e at [e]
}

local MAX_CLIENTNETWORKEYES = 16 -- quakedef.h (not DP_SMALLMEMORY)
local MAX_MAP_LEAFS = 65536 -- quakedef.h (not DP_SMALLMEMORY)

-- a cleared server_t (memset 0 in SV_SpawnServer, then the buffers are set up, sv_main.c L3423-3433)
function server.New(): Server
	local eyes = table.create(MAX_CLIENTNETWORKEYES)
	for i = 1, MAX_CLIENTNETWORKEYES do
		eyes[i] = { 0, 0, 0 }
	end
	return {
		active = false,
		state = server.ss_dead,
		paused = false,
		pausedstart = 0,
		time = 0,
		frametime = 0,
		protocol = common.PROTOCOL.DARKPLACES7,
		name = "",
		worldmessage = "",
		worldbasename = "",
		worldname = "",
		worldnamenoextension = "",
		model_precache = {},
		sound_precache = {},
		lightstyles = {},
		datagram = common.SZ_New(server.NET_MAXMESSAGE),
		signon = common.SZ_New(server.NET_MAXMESSAGE),
		reliable_datagram = common.SZ_New(server.NET_MAXMESSAGE),
		world = world.new(),
		worldmodel = nil,
		models = {},
		writeentitiestoclient_msg = nil,
		particleeffectnamesloaded = false,
		particleeffectname = {},
		loadgame = false,
		stringrefs = {},
		csqc_progcrc = 0,
		csqc_progsize = 0,
		csqc_progname = "",
		writeentitiestoclient_stats_culled_pvs = 0,
		writeentitiestoclient_stats_culled_trace = 0,
		writeentitiestoclient_stats_visibleentities = 0,
		writeentitiestoclient_stats_totalentities = 0,
		writeentitiestoclient_cliententitynumber = 0,
		writeentitiestoclient_clientnumber = 0,
		writeentitiestoclient_eyes = eyes,
		writeentitiestoclient_numeyes = 0,
		writeentitiestoclient_pvsbytes = 0,
		writeentitiestoclient_pvs = buffer.create(MAX_MAP_LEAFS // 8),
		writeentitiestoclient_sendstates = {},
		writeentitiestoclient_csqcsendstates = {},
		numsendentities = 0,
		sendentities = {},
		sendentitiesindex = {},
		sententitiesmark = 0,
		sententities = {},
		sententitiesconsideration = {},
		csqcentityversion = {},
	}
end

server.sv = server.New()

-- memset(&sv, 0, sizeof(sv)) and the buffer setup after it (sv_main.c L3382, L3423-3433), in place: modules
-- that hold the server.sv table keep seeing the same `sv`, as C code sees the same global.
function server.Clear()
	local sv = server.sv :: any
	local refs = sv.stringrefs
	table.clear(sv)
	for k, v in server.New() :: any do
		sv[k] = v
	end
	-- the arrays keep their addresses; their text is zeroed
	for _, r in refs or {} do
		r.str = ""
	end
	sv.stringrefs = refs or {}
end

-- PRVM_SetEngineString(prog, sv.<array>) passes the address of a char array of server_t. The reference for
-- `key` ("worldname", "name", "model_precache 5", ...) is one table per array (identity = the address, kept by
-- server.Clear) whose str is set to the array's current text whenever the address is taken.
function server.CStrRef(key: string, text: string): { str: string }
	local refs = server.sv.stringrefs
	local r = refs[key]
	if not r then
		r = { str = text }
		refs[key] = r
	else
		r.str = text
	end
	return r
end

-- host.c `client_t *host_client` (the client being processed; nil = NULL). Its client_t is a table of
-- host_cmd.svs.clients; the fields sv_phys.c reads are begun, edict (edict number), clmovement_inputtimeout
-- (float), cmd (usercmd_t), fixangle_angles, fixangle_angles_set (nil = the zeroed C memory).
server.host_client = nil :: any

-- vm_customstats (svvm_cmds.c L1690-1695): [i] = { type, fieldoffset }, i = stat - 32
server.vm_customstats = {} :: { [number]: { type: number, fieldoffset: number } }
server.vm_customstats_last = -1

return server
